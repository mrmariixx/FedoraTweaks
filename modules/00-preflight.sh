
# shellcheck shell=bash
# Preflight: traditional Fedora DNF/RPM only.
# No package changes or system modifications before preflight completes.

os_field() {
  (
    [[ -r /etc/os-release ]] || exit 1
    . /etc/os-release
    printf '%s' "${!1:-}"
  )
}

preflight() {
  local c free_kb required_kb=102400
  local lock_file

  # 1. Privilege and terminal checks.
  if (( EUID == 0 )); then
    die "Do not run FedoraTweaks as root or with sudo. Run it as your normal user."
  fi

  [[ -t 0 && -t 1 ]] ||
    die "FedoraTweaks requires an interactive terminal on stdin and stdout."

  # 2. Identify the operating system.
  [[ -r /etc/os-release ]] ||
    die "Cannot read /etc/os-release. Nothing was changed."

  FT_OS_ID=$(os_field ID) ||
    die "Cannot identify the operating system."

  FT_OS_VER=$(os_field VERSION_ID)
  FT_OS_VARIANT=$(os_field VARIANT_ID)
  FT_OS_PRETTY=$(os_field PRETTY_NAME)

  [[ $FT_OS_ID == fedora ]] ||
    die "FedoraTweaks supports Fedora Linux only. Detected: ${FT_OS_PRETTY:-unknown}."

  [[ ! -e /run/ostree-booted ]] ||
    die "Atomic Fedora detected. Traditional DNF/RPM installations only."

  [[ $(uname -m) == x86_64 ]] ||
    die "Unsupported architecture: $(uname -m). Only x86_64 is supported."

  # 3. Check essential commands.
  for c in dnf rpm systemctl sudo awk sed fold df flock; do
    command -v "$c" >/dev/null 2>&1 ||
      die "Required command missing: $c"
  done

  # 4. Validate configuration before creating directories.
  [[ -n ${FT_STATE_DIR:-} &&
     -n ${FT_BACKUP_DIR:-} &&
     -n ${FT_BASELINE_DIR:-} &&
     -n ${FT_REPORT_DIR:-} ]] ||
    die "Internal configuration error: state, backup, baseline and report directories must be defined."

  # 5. Create the state directories.
  mkdir -p -- \
    "$FT_STATE_DIR" \
    "$FT_BACKUP_DIR" \
    "$FT_BASELINE_DIR" \
    "$FT_REPORT_DIR" ||
    die "Cannot create FedoraTweaks state directories."

  # Refuse symlinked state directories to reduce accidental writes
  # into unexpected locations.
  for c in "$FT_STATE_DIR" "$FT_BACKUP_DIR" \
           "$FT_BASELINE_DIR" "$FT_REPORT_DIR"; do
    [[ ! -L $c && -d $c ]] ||
      die "Invalid state directory (symlink or not a directory): $c"
    [[ -w $c && -x $c ]] ||
      die "State directory is not writable: $c"
  done

  # 6. Prevent two instances from modifying state simultaneously.
  lock_file="$FT_STATE_DIR/.fedora-tweaks.lock"

  exec {FT_LOCK_FD}>"$lock_file" ||
    die "Cannot open the FedoraTweaks lock file."

  if ! flock -n "$FT_LOCK_FD"; then
    die "Another FedoraTweaks instance is already running."
  fi

  # 7. Check free disk space (100 MiB minimum).
  free_kb=$(df -Pk -- "$FT_STATE_DIR" |
    awk 'NR == 2 { print $4 }')

  [[ $free_kb =~ ^[0-9]+$ ]] ||
    die "Unable to determine free disk space."

  (( free_kb >= required_kb )) ||
    die "Insufficient disk space in $FT_STATE_DIR (minimum: 100 MiB)."

  # 8. Check RPM database accessibility.
  rpm -q fedora-release-common >/dev/null 2>&1 ||
    warn "Could not verify fedora-release-common. Check the RPM database."

  # 9. Version compatibility.
  if [[ $FT_OS_VER =~ ^[0-9]+$ ]]; then
    if (( FT_OS_VER < 43 || FT_OS_VER > 45 )); then
      warn "Fedora $FT_OS_VER is outside the currently supported range (43–45)."
      confirm "Continue anyway?" n || exit 1
    fi
  else
    warn "Unrecognized Fedora version '${FT_OS_VER:-unknown}' (possibly Rawhide)."
    confirm "Continue anyway?" n || exit 1
  fi

  # 10. Detect KDE Plasma without making it a global requirement.
  if [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]] &&
     command -v kwriteconfig6 >/dev/null 2>&1; then
    FT_IS_KDE=1
  else
    FT_IS_KDE=0
    warn "KDE Plasma 6 session not detected. KDE-specific stages will be skipped."
  fi

  if [[ $FT_OS_VARIANT != kde ]]; then
    warn "Detected Fedora variant '${FT_OS_VARIANT:-unknown}'; designed primarily for Fedora KDE."
  fi

  # 11. Runtime diagnostics.
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    warn "SSH session detected. Avoid applying changes that require local interaction."
  fi

  if [[ ${FT_DRY_RUN:-0} == 1 ]]; then
    warn "DRY RUN enabled: state-changing operations must not execute."
  fi

  # 12. Record the validated environment.
  ft_log "START v$FT_VERSION on $FT_OS_PRETTY ($(uname -r)) dry_run=${FT_DRY_RUN:-0} kde=$FT_IS_KDE"

  return 0
}

have_baseline() {
  compgen -G "$FT_BASELINE_DIR/*/metrics.env" >/dev/null
}
