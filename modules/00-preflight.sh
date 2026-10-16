# shellcheck shell=bash
# Preflight: refuse to run anywhere except a traditional (DNF/RPM) Fedora install.

os_field() { ( . /etc/os-release 2>/dev/null && eval "printf '%s' \"\${$1:-}\"" ); }

preflight() {
  if [[ $EUID -eq 0 ]]; then
    die "Do not run FedoraTweaks as root or with sudo. Run it as your normal user — it asks for sudo only for the steps that need it."
  fi
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release. Unsupported system — nothing was changed."

  FT_OS_ID=$(os_field ID)
  FT_OS_VER=$(os_field VERSION_ID)
  FT_OS_VARIANT=$(os_field VARIANT_ID)
  FT_OS_PRETTY=$(os_field PRETTY_NAME)

  if [[ $FT_OS_ID != fedora ]]; then
    die "FedoraTweaks only runs on Fedora Linux. Detected: ${FT_OS_PRETTY:-unknown}. Nothing was changed."
  fi
  if [[ -e /run/ostree-booted ]]; then
    die "Fedora Atomic (Kinoite/Silverblue) detected. This tool targets traditional DNF/RPM Fedora. Nothing was changed."
  fi
  [[ $(uname -m) == x86_64 ]] || die "Only x86_64 is supported."
  [[ -t 0 ]] || die "FedoraTweaks is interactive; run it from a terminal."

  local c
  for c in dnf rpm systemctl sudo awk sed fold; do
    command -v "$c" >/dev/null 2>&1 || die "Required command missing: $c"
  done

  mkdir -p "$FT_STATE_DIR" "$FT_BACKUP_DIR" "$FT_BASELINE_DIR" "$FT_REPORT_DIR" \
    || die "Cannot create $FT_STATE_DIR"

  if [[ $FT_OS_VER =~ ^[0-9]+$ ]]; then
    if (( FT_OS_VER < 43 )); then
      warn "Fedora $FT_OS_VER is older than the releases this tool was written for (43–45)."
      confirm "Continue anyway?" n || exit 1
    fi
  else
    warn "Fedora version '$FT_OS_VER' (Rawhide?) — expect rough edges."
  fi

  if [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]] && command -v kwriteconfig6 >/dev/null 2>&1; then
    FT_IS_KDE=1
  else
    warn "Not running inside a KDE Plasma 6 session — KDE stages will be skipped."
  fi
  [[ $FT_OS_VARIANT == kde ]] || warn "Fedora variant is '${FT_OS_VARIANT:-unknown}'. FedoraTweaks is designed for the Fedora KDE Plasma Desktop edition."
  [[ $FT_DRY_RUN == 1 ]] && warn "DRY RUN — state-changing commands are printed, not executed."
  ft_log "START v$FT_VERSION on $FT_OS_PRETTY ($(uname -r)) dry_run=$FT_DRY_RUN"
}

have_baseline() { compgen -G "$FT_BASELINE_DIR/*/metrics.env" >/dev/null; }
