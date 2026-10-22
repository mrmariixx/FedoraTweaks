# shellcheck shell=bash
# Shared helpers for FedoraTweaks. Sourced by ./FedoraTweaks — never executed directly.

FT_VERSION="0.3.0"
FT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedoratweaks"
FT_JOURNAL="$FT_STATE_DIR/journal.tsv"
FT_BACKUP_DIR="$FT_STATE_DIR/backups"
FT_BASELINE_DIR="$FT_STATE_DIR/baselines"
FT_REPORT_DIR="$FT_STATE_DIR/reports"
FT_LOG="$FT_STATE_DIR/fedoratweaks.log"
FT_DRY_RUN="${FT_DRY_RUN:-0}"
FT_IS_KDE=0
FT_SUDO_PID=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

ft_log() { { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$FT_LOG"; } 2>/dev/null || true; }
info()   { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; ft_log "INFO $*"; }
ok()     { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; ft_log "OK $*"; }
warn()   { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; ft_log "WARN $*"; }
err()    { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; ft_log "ERROR $*"; }
die()    { err "$*"; exit 1; }
header() { printf '\n%s━━━ %s ━━━%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; ft_log "STAGE $*"; }

# wrap INDENT TEXT... — word-wrap text to the terminal width with an indent
wrap() {
  local indent=$1; shift
  local cols width
  cols=$(tput cols 2>/dev/null || echo 80)
  width=$(( cols - ${#indent} - 1 ))
  (( width > 100 )) && width=100
  (( width < 40 )) && width=40
  printf '%s\n' "$*" | fold -s -w "$width" | sed "s/^/$indent/"
}

explain() { printf '%s' "$C_DIM"; wrap '  ' "$*"; printf '%s' "$C_RESET"; }

tier_label() {
  case $1 in
    safe)         printf '%s[SAFE]%s' "$C_GREEN$C_BOLD" "$C_RESET" ;;
    optional)     printf '%s[OPTIONAL]%s' "$C_YELLOW$C_BOLD" "$C_RESET" ;;
    experimental) printf '%s[EXPERIMENTAL]%s' "$C_RED$C_BOLD" "$C_RESET" ;;
    *)            printf '%s[INFO]%s' "$C_DIM" "$C_RESET" ;;
  esac
}

# ---------------------------------------------------------------------------
# Prompts (always read from the terminal, never from a pipe)
# ---------------------------------------------------------------------------

# confirm QUESTION [y|n] — default answer is the second argument (n if omitted)
confirm() {
  local q=$1 def=${2:-n} ans prompt
  [[ $def == y ]] && prompt='[Y/n]' || prompt='[y/N]'
  while true; do
    read -r -p "$q $prompt " ans </dev/tty || return 1
    ans=${ans,,}
    [[ -z $ans ]] && ans=$def
    case $ans in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# confirm_hard QUESTION — the user must type "yes" in full
confirm_hard() {
  local ans
  read -r -p "$1 Type 'yes' to proceed: " ans </dev/tty || return 1
  [[ $ans == yes ]]
}

# propose TIER TITLE WHAT LOSS UNDO — describe a change and ask for approval
propose() {
  local tier=$1 title=$2 what=$3 loss=$4 undo=$5
  printf '\n%s %s%s%s\n' "$(tier_label "$tier")" "$C_BOLD" "$title" "$C_RESET"
  printf '  %sWhat it does:%s\n' "$C_BOLD" "$C_RESET";  wrap '    ' "$what"
  printf '  %sWhat you lose:%s\n' "$C_BOLD" "$C_RESET"; wrap '    ' "$loss"
  printf '  %sHow to undo:%s\n' "$C_BOLD" "$C_RESET";   wrap '    ' "$undo"
  case $tier in
    experimental) confirm_hard "  Apply this EXPERIMENTAL change?" ;;
    safe)         confirm "  Apply?" y ;;
    *)            confirm "  Apply?" n ;;
  esac
}

# note TITLE TEXT — information only, nothing is applied
note() {
  printf '\n%s %s%s%s\n' "$(tier_label info)" "$C_BOLD" "$1" "$C_RESET"
  wrap '    ' "$2"
}

# ---------------------------------------------------------------------------
# Running commands
# ---------------------------------------------------------------------------
quote_cmd() { local out='' a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }

# run CMD... — echo, log and execute a state-changing command (printed only in dry-run)
run() {
  printf '%s    $ %s%s\n' "$C_DIM" "$(quote_cmd "$@")" "$C_RESET"
  ft_log "RUN $(quote_cmd "$@")"
  [[ $FT_DRY_RUN == 1 ]] && return 0
  "$@"
}

# Authenticate sudo once and keep the timestamp fresh while the tool runs.
sudo_init() {
  [[ -n $FT_SUDO_PID ]] && return 0
  info "Administrator rights (sudo) are needed for this step."
  sudo -v || die "sudo authentication failed."
  ( while sleep 50; do
      kill -0 "$$" 2>/dev/null || exit 0
      sudo -n true 2>/dev/null || exit 0
    done ) &
  FT_SUDO_PID=$!
  trap 'kill "$FT_SUDO_PID" 2>/dev/null' EXIT
}

sudo_run() { [[ $FT_DRY_RUN == 1 ]] || sudo_init; run sudo "$@"; }

# ro 'COMMAND STRING' — show and execute a read-only inspection command
ro() {
  printf '%s$ %s%s\n' "$C_DIM" "$1" "$C_RESET"
  bash -c "$1" 2>&1 | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Change journal (every applied change records its undo command)
# Format: ID<TAB>DATE<TAB>DESCRIPTION<TAB>UNDO   — or —   UNDONE<TAB>ID
# ---------------------------------------------------------------------------
journal_add() {
  local desc=$1 undo=$2
  if [[ $FT_DRY_RUN == 1 ]]; then
    printf '%s    (dry-run) undo would be: %s%s\n' "$C_DIM" "$undo" "$C_RESET"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$(date '+%F %T')" "${desc//$'\t'/ }" "${undo//$'\t'/ }" >>"$FT_JOURNAL"
  ok "Recorded in journal (undo with: ./FedoraTweaks rollback)"
}

# journal_pending — entries not yet undone, newest first
journal_pending() {
  [[ -f $FT_JOURNAL ]] || return 0
  awk -F'\t' '
    $1 == "UNDONE" { undone[$2] = 1; next }
    { line[NR] = $0; id[NR] = $1 }
    END { for (i = NR; i >= 1; i--) if ((i in line) && !(id[i] in undone)) print line[i] }
  ' "$FT_JOURNAL"
}

journal_mark_undone() { printf 'UNDONE\t%s\n' "$1" >>"$FT_JOURNAL"; }

# ---------------------------------------------------------------------------
# Backups and file writes
# ---------------------------------------------------------------------------

# backup_file PATH [sudo] — copy PATH into the backup tree; prints the backup path ('' if PATH absent)
backup_file() {
  local src=$1 use_sudo=${2:-} dest
  [[ -e $src ]] || return 0
  # Nanoseconds avoid overwriting a backup if the same file changes twice quickly.
  dest="$FT_BACKUP_DIR/$(date +%Y%m%d-%H%M%S%N)$src"
  mkdir -p "$(dirname "$dest")" || return 1
  [[ -e $dest ]] && dest="${dest}.$$.$RANDOM"
  if [[ -n $use_sudo ]]; then
    sudo cp --preserve=mode,timestamps "$src" "$dest" && sudo chown "$(id -u):$(id -g)" "$dest"
  else
    cp -a "$src" "$dest"
  fi || return 1
  printf '%s' "$dest"
}

# root_write PATH CONTENT DESCRIPTION [EXTRA_UNDO] — write a root-owned config file, journaled
root_write() {
  local path=$1 content=$2 desc=$3 extra=${4:-} bak undo
  if [[ $FT_DRY_RUN == 1 ]]; then
    printf '%s    (dry-run) would write %s:%s\n' "$C_DIM" "$path" "$C_RESET"
    printf '%s\n' "$content" | sed 's/^/      /'
    return 0
  fi
  sudo_init
  bak=$(backup_file "$path" sudo) || return 1
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null || return 1
  sudo restorecon "$path" 2>/dev/null || true
  ok "Wrote $path"
  if [[ -n $bak ]]; then
    undo="sudo cp --preserve=mode,timestamps $(printf %q "$bak") $(printf %q "$path")"
  else
    undo="sudo rm -f $(printf %q "$path")"
  fi
  [[ -n $extra ]] && undo+=" && $extra"
  journal_add "$desc" "$undo"
}

# user_write PATH CONTENT DESCRIPTION — write a file in the user's home, journaled
user_write() {
  local path=$1 content=$2 desc=$3 bak undo
  if [[ $FT_DRY_RUN == 1 ]]; then
    printf '%s    (dry-run) would write %s:%s\n' "$C_DIM" "$path" "$C_RESET"
    printf '%s\n' "$content" | sed 's/^/      /'
    return 0
  fi
  bak=$(backup_file "$path") || return 1
  mkdir -p "$(dirname "$path")" && printf '%s\n' "$content" >"$path" || return 1
  ok "Wrote $path"
  if [[ -n $bak ]]; then undo="cp -a $(printf %q "$bak") $(printf %q "$path")"
  else undo="rm -f $(printf %q "$path")"; fi
  journal_add "$desc" "$undo"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
pkg_installed() { rpm -q --quiet "$1" 2>/dev/null; }

# Packages that must never disappear as a side effect of a removal.
FT_PROTECTED_EXACT=(
  plasma-workspace plasma-workspace-wayland plasma-desktop plasma-nm plasma-pa
  plasma-login-manager kwin kwin-wayland kwin-common kscreen kscreenlocker
  sddm sddm-wayland-plasma sddm-kcm dolphin konsole systemsettings
  xdg-desktop-portal xdg-desktop-portal-kde powerdevil polkit polkit-kde
  NetworkManager NetworkManager-wifi wireplumber dbus-broker dbus
  dnf dnf5 dnf5-plugins rpm sudo bash coreutils util-linux firewalld
  linux-firmware amd-gpu-firmware amd-ucode-firmware fwupd shim-x64 grubby
  mokutil tuned tuned-ppd
)
FT_PROTECTED_GLOB=(
  'kernel' 'kernel-*' 'fedora-release*' 'selinux-policy*' 'systemd' 'systemd-*'
  'pipewire*' 'mesa-*' 'glibc*' 'grub2*' 'plasma-integration*' 'plasma-breeze*'
)
# Libraries (kf6-*, qt6-*) are deliberately not listed: if an essential app needed one,
# that app itself would appear in the removal list and be caught above.

is_protected() {
  local p=$1 x
  for x in "${FT_PROTECTED_EXACT[@]}"; do [[ $p == "$x" ]] && return 0; done
  # shellcheck disable=SC2053  # glob match is intended
  for x in "${FT_PROTECTED_GLOB[@]}"; do [[ $p == $x ]] && return 0; done
  return 1
}

# dnf_preview SUBCOMMAND PKGS... — resolve a remove/autoremove transaction without applying it.
# Prints every package name it would remove. Returns 1 (and prints dnf's output to stderr)
# when the output cannot be parsed with certainty, so callers skip instead of guessing.
dnf_preview() {
  local sub=$1; shift
  local out tok count
  local -a names=()
  # Callers must run sudo_init first (this function usually runs inside $(...)).
  out=$(sudo env COLUMNS=400 LC_ALL=C dnf "$sub" --assumeno "$@" 2>&1)
  if grep -qiE 'nothing to do|no packages marked for removal' <<<"$out"; then
    return 0
  fi
  while read -r tok; do
    [[ -n $tok ]] && rpm -q --quiet "$tok" 2>/dev/null && names+=("$tok")
  done < <(awk '/^ [^ ]/ && NF >= 4 { print $1 }' <<<"$out" | sort -u)
  count=$(sed -nE 's/^ *Remov(e|ing):? +([0-9]+) +[Pp]ackages?.*/\2/p' <<<"$out" | tail -n 1)
  if [[ -z $count ]] || (( count != ${#names[@]} )); then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "${names[@]}"
}

# install_pkgs DESCRIPTION PKG... — install what is missing; journals removal of what was added
install_pkgs() {
  local desc=$1; shift
  local -a missing=() added=()
  local p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then
    ok "$desc: already installed"
    return 0
  fi
  sudo_run dnf install -y --skip-unavailable "${missing[@]}" || { err "dnf install failed"; return 1; }
  [[ $FT_DRY_RUN == 1 ]] && return 0
  for p in "${missing[@]}"; do pkg_installed "$p" && added+=("$p"); done
  if (( ${#added[@]} )); then
    journal_add "Installed ($desc): ${added[*]}" "sudo dnf remove $(quote_cmd "${added[@]}")"
  fi
  for p in "${missing[@]}"; do pkg_installed "$p" || warn "$p is not available in the enabled repositories (skipped)"; done
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
unit_exists() { [[ -n $(systemctl list-unit-files --no-legend "$1" 2>/dev/null) ]]; }
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled_state() { systemctl is-enabled "$1" 2>/dev/null || true; }

# units_relevant UNIT... — true if any unit exists and is enabled or running
units_relevant() {
  local u st
  for u in "$@"; do
    unit_exists "$u" || continue
    st=$(unit_enabled_state "$u")
    [[ $st == enabled || $st == enabled-runtime ]] && return 0
    unit_active "$u" && return 0
  done
  return 1
}

# svc_off disable|mask DESCRIPTION UNIT... — stop units and keep them from starting, journaled.
# "mask" is needed for units that D-Bus or sockets would otherwise start on demand.
svc_off() {
  local mode=$1 desc=$2
  shift 2
  local u st active=0 undo quoted_u
  [[ $mode == disable || $mode == mask ]] || {
    err "svc_off: unsupported mode '$mode' (expected disable or mask)."
    return 2
  }

  for u in "$@"; do
    unit_exists "$u" || continue
    st=$(unit_enabled_state "$u")
    [[ -n $st ]] || st=unknown
    [[ $st == masked || $st == masked-runtime ]] && continue

    active=0
    unit_active "$u" && active=1
    quoted_u=$(printf '%q' "$u")
    undo=''

    if [[ $mode == mask ]]; then
      # Restore the original enablement and active state, not just "unmask".
      if [[ $st == enabled || $st == enabled-runtime ]]; then
        sudo_run systemctl disable --now "$u" || {
          warn "Could not disable $u; leaving it unchanged."
          continue
        }
      elif (( active )); then
        sudo_run systemctl stop "$u" || {
          warn "Could not stop $u; leaving it unchanged."
          continue
        }
      fi

      sudo_run systemctl mask "$u" || {
        warn "Could not mask $u; attempting to restore its previous state."
        if [[ $st == enabled ]]; then sudo_run systemctl enable "$u" || true; fi
        if [[ $st == enabled-runtime ]]; then sudo_run systemctl enable --runtime "$u" || true; fi
        (( active )) && sudo_run systemctl start "$u" || true
        continue
      }

      undo="sudo systemctl unmask $quoted_u"
      case $st in
        enabled)         undo+=" && sudo systemctl enable $quoted_u" ;;
        enabled-runtime) undo+=" && sudo systemctl enable --runtime $quoted_u" ;;
      esac
      (( active )) && undo+=" && sudo systemctl start $quoted_u"

    else
      case $st in
        enabled)
          sudo_run systemctl disable --now "$u" || {
            warn "Could not disable $u; leaving it unchanged."
            continue
          }
          undo="sudo systemctl enable $quoted_u"
          (( active )) && undo+=" && sudo systemctl start $quoted_u"
          ;;
        enabled-runtime)
          sudo_run systemctl disable --runtime --now "$u" || {
            warn "Could not disable runtime unit $u; leaving it unchanged."
            continue
          }
          undo="sudo systemctl enable --runtime $quoted_u"
          (( active )) && undo+=" && sudo systemctl start $quoted_u"
          ;;
        *)
          if (( active )); then
            sudo_run systemctl stop "$u" || {
              warn "Could not stop $u; leaving it unchanged."
              continue
            }
            undo="sudo systemctl start $quoted_u"
          else
            # No state change is required for a disabled/inactive unit.
            continue
          fi
          ;;
      esac
    fi

    if ! journal_add "$desc: $mode $u (was $st; active=$active)" "$undo"; then
      err "The change to $u was applied but its rollback entry could not be saved."
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# KDE configuration
# ---------------------------------------------------------------------------

# kde_set FILE GROUP KEY VALUE — write a KConfig key; the undo restores the exact previous value
kde_set() {
  local file=$1 group=$2 key=$3 val=$4 old undo
  old=$(kreadconfig6 --file "$file" --group "$group" --key "$key" --default __FT_UNSET__ 2>/dev/null)
  if [[ $old == "$val" ]]; then
    ok "$file [$group] $key is already $val"
    return 0
  fi
  [[ $FT_DRY_RUN == 1 ]] || backup_file "$HOME/.config/$file" >/dev/null
  run kwriteconfig6 --file "$file" --group "$group" --key "$key" "$val" || return 1
  if [[ $old == __FT_UNSET__ ]]; then
    undo="kwriteconfig6 --file $(printf %q "$file") --group $(printf %q "$group") --key $(printf %q "$key") --delete"
  else
    undo="kwriteconfig6 --file $(printf %q "$file") --group $(printf %q "$group") --key $(printf %q "$key") $(printf %q "$old")"
  fi
  journal_add "KDE $file [$group] $key=$val (was: ${old/__FT_UNSET__/unset})" "$undo"
}

kwin_reconfigure() {
  [[ $FT_DRY_RUN == 1 ]] && return 0
  dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null \
    || warn "Could not ask KWin to reload; the change applies at next login."
}
