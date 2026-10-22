
# shellcheck shell=bash
# Stage 5 — package debloat (Fedora + KDE applications).
# Only installed packages are considered.
# Every DNF removal is previewed before confirmation.
# Protected packages in the preview block the entire operation.

# remove_group TIER TITLE WHAT LOSS PKG...
# Preview -> protect -> ask -> remove -> verify -> journal.
remove_group() {
  local tier=$1 title=$2 what=$3 loss=$4
  shift 4

  local -a present=() preview=() gone=()
  local p plan blocked='' extra='' removal_rc=0
  local quoted_packages=''

  for p in "$@"; do
    [[ -n $p ]] || continue
    if pkg_installed "$p"; then
      present+=("$p")
    fi
  done

  (( ${#present[@]} > 0 )) || return 0

  sudo_init

  if ! plan=$(dnf_preview remove "${present[@]}"); then
    warn "Skipping '$title': DNF could not provide a reliable removal plan. Nothing was removed."
    return 0
  fi

  if [[ -z ${plan//[[:space:]]/} ]]; then
    warn "Skipping '$title': DNF returned an empty removal plan for installed packages. Nothing was removed."
    return 0
  fi

  mapfile -t preview <<<"$plan"

  if (( ${#preview[@]} == 0 )); then
    warn "Skipping '$title': the removal plan could not be parsed."
    return 0
  fi

  # Reject malformed or duplicate entries instead of assuming the preview
  # contains only valid package names.
  local -A seen=()
  local -a validated=()

  for p in "${preview[@]}"; do
    [[ -n $p ]] || continue

    if [[ ! $p =~ ^[[:alnum:]_.+:-]+$ ]]; then
      warn "Skipping '$title': unexpected entry in DNF's removal plan: '$p'."
      return 0
    fi

    if [[ -z ${seen[$p]+x} ]]; then
      seen[$p]=1
      validated+=("$p")
    fi
  done

  preview=("${validated[@]}")

  if (( ${#preview[@]} == 0 )); then
    warn "Skipping '$title': no valid package names were found in DNF's removal plan."
    return 0
  fi

  # Check every package DNF plans to remove, not just the requested packages.
  for p in "${preview[@]}"; do
    if is_protected "$p"; then
      blocked+=" $p"
    fi
  done

  if [[ -n $blocked ]]; then
    warn "Skipping '$title': DNF would remove protected packages:$blocked"
    return 0
  fi

  # Identify packages pulled into the transaction as additional removals.
  for p in "${preview[@]}"; do
    if [[ " ${present[*]} " != *" $p "* ]]; then
      extra+=" $p"
    fi
  done

  quoted_packages=$(quote_cmd "${preview[@]}")

  if ! propose "$tier" "$title" \
      "$what Removes: ${present[*]}.${extra:+ Also included in the DNF transaction:$extra.}" \
      "$loss" \
      "./FedoraTweaks rollback — or: sudo dnf install $quoted_packages"; then
    return 0
  fi

  if sudo_run dnf remove "${present[@]}"; then
    removal_rc=0
  else
    removal_rc=$?
    warn "DNF removal failed for '$title' (exit code $removal_rc). Checking which packages, if any, were actually removed."
  fi

  # A dry run must never be recorded as a completed removal.
  [[ ${FT_DRY_RUN:-0} == 1 ]] && return 0

  # Verify actual state instead of trusting the requested transaction.
  for p in "${preview[@]}"; do
    if ! pkg_installed "$p"; then
      gone+=("$p")
    fi
  done

  if (( ${#gone[@]} > 0 )); then
    journal_add \
      "Removed packages ($title): ${gone[*]}" \
      "sudo dnf install $(quote_cmd "${gone[@]}")"
  fi

  if (( removal_rc != 0 )); then
    warn "Review the DNF transaction and FedoraTweaks journal before continuing."
    return 0
  fi

  if (( ${#gone[@]} == 0 )); then
    info "No packages from '$title' were found to have been removed."
  else
    ok "Verified removal for '$title': ${gone[*]}"
  fi
}

stage_packages() {
  header "Stage 5 — Package debloat"

  explain "This stage removes selected applications, not core gaming components. Removing applications mainly saves disk space and may reduce background activity; it does not directly increase in-game FPS. Each group is previewed by DNF and skipped if its transaction includes a protected package."

  # Virtual-machine guest agents.
  if command -v systemd-detect-virt >/dev/null 2>&1 &&
     [[ $(systemd-detect-virt 2>/dev/null) == none ]]; then

    remove_group safe "Virtual-machine guest tools (bare metal)" \
      "These agents provide integration features inside virtual machines, such as clipboard sharing and guest communication." \
      "Virtual-machine integration features, if you later run this installation as a guest." \
      spice-vdagent qemu-guest-agent open-vm-tools open-vm-tools-desktop \
      hyperv-daemons virtualbox-guest-additions
  fi

  # Crash reporting.
  remove_group optional "ABRT crash reporting" \
    "Fedora's Automatic Bug Reporting Tool collects crash information and provides reporting workflows." \
    "ABRT reporting tools. Other crash logging facilities may remain available, depending on the installed system." \
    abrt abrt-desktop abrt-cli abrt-gui abrt-applet

  remove_group optional "KDE crash handler (DrKonqi)" \
    "DrKonqi provides KDE's graphical crash dialog and backtrace reporting workflow." \
    "The KDE graphical crash-reporting dialog. Other crash logging tools may remain available." \
    drkonqi plasma-drkonqi

  # KDE PIM.
  remove_group optional "KDE PIM suite" \
    "Removes selected KDE mail, calendar, contacts, RSS and PIM support applications that are installed. DNF decides whether shared components can be removed safely." \
    "The selected KDE PIM applications and potentially their shared storage services. Calendar integration in the Plasma clock may be affected." \
    kmail kontact korganizer akregator kaddressbook kmail-account-wizard \
    akonadi-import-wizard merkuro pim-sieve-editor pim-data-exporter \
    ktnef kdepim-addons kdepim-runtime akonadi-server

  # LibreOffice: derive package names from installed RPMs.
  local -a lo=()

  mapfile -t lo < <(
    rpm -qa --qf '%{NAME}\n' 2>/dev/null |
      grep -E '^libreoffice-' |
      sort -u
  )

  if (( ${#lo[@]} > 0 )); then
    remove_group optional "LibreOffice" \
      "Removes the installed LibreOffice components identified by RPM. No package wildcards are passed to DNF." \
      "Local LibreOffice document editing. Reinstall the suite if you need it later." \
      "${lo[@]}"
  else
    info "No installed LibreOffice RPM components detected."
  fi

  # KDE games.
  remove_group optional "KDE games" \
    "Removes selected preinstalled card, board and puzzle games." \
    "The selected games." \
    kmahjongg kmines kpat ksudoku knights kblackbox kbounce kolf

  # Media applications.
  remove_group optional "Extra media applications" \
    "Removes selected media applications and disc-burning tools." \
    "Dragon Player, Elisa, Kamoso and K3b functionality, where installed. Other media players are not explicitly targeted." \
    dragon elisa-player kamoso k3b

  # Phone integration.
  remove_group optional "KDE Connect" \
    "Removes KDE Connect and selected related components." \
    "Phone notifications, file transfer, clipboard synchronization and remote control through KDE Connect." \
    kde-connect kde-connect-libs kdeconnectd

  # Remote desktop and chat applications.
  remove_group optional "Remote desktop and chat applications" \
    "Removes selected clients and applications for remote desktop, desktop sharing, Matrix, IRC and torrent downloads." \
    "The selected applications." \
    krdc krfb neochat konversation ktorrent

  # Utilities.
  remove_group optional "Optional KDE utilities" \
    "Removes selected welcome, help, accessibility, search, journal, QR, scanner and media-writing applications." \
    "The selected utilities. Core desktop applications such as Dolphin, Kate, Konsole, Spectacle, Ark, Gwenview, Okular and System Settings are not explicitly targeted." \
    plasma-welcome khelpcenter kmag kmouth kmousetool kfind kjournald \
    qrca skanpage mediawriter

  # Printing-related applications and drivers.
  remove_group optional "Printing extras" \
    "Removes selected printer configuration tools, printer discovery integration and HP printer support packages." \
    "Printer setup interfaces, network printer discovery integration and HP printer drivers, where installed. The CUPS core is not explicitly targeted." \
    print-manager cups-browsed hplip hplip-gui system-config-printer-udev

  # Browser integration.
  remove_group optional "Plasma Browser Integration" \
    "Removes the browser extension integration host for Plasma." \
    "Plasma media controls, download progress and browser integration with KRunner. Browsers themselves remain untouched unless DNF reports a dependency transaction, in which case the protected-package check applies." \
    plasma-browser-integration

  # Discover.
  explain "Discover is KDE's graphical software center. Removing it means managing applications and updates through DNF and, for Flatpaks, the Flatpak command-line tools."

  remove_group optional "Discover software center" \
    "Removes installed Discover components included in the proposed DNF transaction." \
    "The graphical software center and related Discover functionality. DNF and Flatpak command-line tools can still be used if installed." \
    plasma-discover plasma-discover-notifier plasma-discover-flatpak \
    plasma-discover-packagekit plasma-discover-offline-updates \
    plasma-discover-kns plasma-discover-libs

  # Accessibility.
  remove_group optional "Screen reader (Orca)" \
    "Orca is a screen reader for blind and low-vision users." \
    "Spoken screen reading. Keep Orca installed if anyone using this computer needs it." \
    orca

  # Flatpak cleanup.
  # Use the current user's Flatpak installation; do not run a user cleanup
  # as root, which can target a different installation.
  if command -v flatpak >/dev/null 2>&1; then
    local flatpak_user_apps=''

    flatpak_user_apps=$(flatpak list --user --columns=application 2>/dev/null || true)

    if [[ -n $flatpak_user_apps ]]; then
      if propose optional "Remove unused user Flatpak runtimes" \
          "Runs 'flatpak uninstall --user --unused'. Flatpak determines which user-installed runtimes and extensions are no longer required." \
          "Unused user runtimes and extensions are removed. They can generally be downloaded again if required later." \
          "Run 'flatpak install --user' for the required application or runtime again."; then

        if [[ ${FT_DRY_RUN:-0} == 1 ]]; then
          info "Dry run: user Flatpak cleanup was not executed."
        elif flatpak uninstall --user --unused; then
          ok "User Flatpak cleanup completed."
        else
          warn "User Flatpak cleanup did not complete successfully."
        fi
      fi
    else
      info "No user-installed Flatpak applications detected; skipping user runtime cleanup."
    fi
  fi

  # DNF autoremove.
  explain "Finally, DNF can identify packages that were installed as dependencies and are no longer required. This transaction receives the same protected-package checks as the other removals."

  local -a auto=()
  local plan=''
  local p blocked=''
  local -a validated_auto=()

  sudo_init

  if ! plan=$(dnf_preview autoremove); then
    warn "Skipping autoremove: DNF could not provide a reliable plan."
    return 0
  fi

  if [[ -n ${plan//[[:space:]]/} ]]; then
    mapfile -t auto <<<"$plan"
  fi

  if (( ${#auto[@]} > 0 )); then
    local -A auto_seen=()

    for p in "${auto[@]}"; do
      [[ -n $p ]] || continue

      if [[ ! $p =~ ^[[:alnum:]_.+:-]+$ ]]; then
        warn "Skipping autoremove: unexpected package name in the DNF plan: '$p'."
        return 0
      fi

      if [[ -z ${auto_seen[$p]+x} ]]; then
        auto_seen[$p]=1
        validated_auto+=("$p")
      fi
    done

    auto=("${validated_auto[@]}")
  fi

  if (( ${#auto[@]} > 0 )); then
    for p in "${auto[@]}"; do
      if is_protected "$p"; then
        blocked+=" $p"
      fi
    done

    if [[ -n $blocked ]]; then
      warn "Skipping autoremove: DNF would remove protected packages:$blocked"

    elif propose optional "Remove unneeded dependencies (DNF autoremove)" \
        "DNF proposes removing ${#auto[@]} packages: ${auto[*]}" \
        "Packages DNF considers no longer required. Review the transaction carefully; dependency metadata can be imperfect, and optional applications may rely on packages not marked as required." \
        "./FedoraTweaks rollback — or: sudo dnf install $(quote_cmd "${auto[@]}")"; then

      local autoremove_rc=0

      if sudo_run dnf autoremove; then
        autoremove_rc=0
      else
        autoremove_rc=$?
        warn "DNF autoremove failed (exit code $autoremove_rc). Verifying actual package state."
      fi

      if [[ ${FT_DRY_RUN:-0} != 1 ]]; then
        local -a gone=()

        for p in "${auto[@]}"; do
          if ! pkg_installed "$p"; then
            gone+=("$p")
          fi
        done

        if (( ${#gone[@]} > 0 )); then
          journal_add \
            "DNF autoremove removed: ${gone[*]}" \
            "sudo dnf install $(quote_cmd "${gone[@]}")"
        fi
      fi

      if (( autoremove_rc == 0 )); then
        ok "DNF autoremove transaction completed."
      else
        warn "Review DNF output and the FedoraTweaks journal before continuing."
      fi
    fi
  else
    ok "DNF reports no unneeded dependencies."
  fi

  ok "Stage 5 completed. Review the transaction output and journal before proceeding."
}
