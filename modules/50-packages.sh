# shellcheck shell=bash
# Stage 5 — package debloat (Fedora + KDE applications).
# For every group: only installed packages are considered, dnf resolves the full transaction
# first (--assumeno), and the group is skipped if that would remove anything protected.

# remove_group TIER TITLE WHAT LOSS PKG... — preview, check, ask, remove, journal
remove_group() {
  local tier=$1 title=$2 what=$3 loss=$4; shift 4
  local -a present=() preview=() gone=()
  local p plan blocked='' extra=''
  for p in "$@"; do pkg_installed "$p" && present+=("$p"); done
  (( ${#present[@]} )) || return 0

  sudo_init
  if ! plan=$(dnf_preview remove "${present[@]}") || [[ -z $plan ]]; then
    warn "Skipping '$title': could not reliably read dnf's removal plan (shown above). Nothing was removed."
    return 0
  fi
  mapfile -t preview <<<"$plan"
  for p in "${preview[@]}"; do is_protected "$p" && blocked+=" $p"; done
  if [[ -n $blocked ]]; then
    warn "Skipping '$title': removing it would also remove protected packages:$blocked"
    return 0
  fi
  for p in "${preview[@]}"; do [[ " ${present[*]} " == *" $p "* ]] || extra+=" $p"; done

  propose "$tier" "$title" \
    "$what  Removes: ${present[*]}.${extra:+  Also removed as dependents/unused dependencies:$extra.}" \
    "$loss" \
    "./FedoraTweaks rollback (reinstalls exactly these packages) — or: sudo dnf install ${preview[*]}" \
    || return 0

  sudo_run dnf remove "${present[@]}" || { warn "dnf did not complete the removal."; }
  [[ $FT_DRY_RUN == 1 ]] && return 0
  for p in "${preview[@]}"; do pkg_installed "$p" || gone+=("$p"); done
  (( ${#gone[@]} )) && journal_add "Removed packages ($title): ${gone[*]}" "sudo dnf install $(quote_cmd "${gone[@]}")"
}

stage_packages() {
  header "Stage 5 — Package debloat"
  explain "Removing applications frees disk space and stops a few background helpers; it does not raise in-game FPS by itself. Every group shows dnf's exact plan first. You can always reinstall with './FedoraTweaks rollback' or 'sudo dnf install <name>'."

  if [[ $(systemd-detect-virt 2>/dev/null) == none ]]; then
    remove_group safe "Virtual-machine guest tools (this is bare metal)" \
      "These agents only do something inside a virtual machine (clipboard sharing, resizing, host integration)." \
      "Nothing on a physical PC." \
      spice-vdagent qemu-guest-agent open-vm-tools open-vm-tools-desktop hyperv-daemons virtualbox-guest-additions
  fi

  remove_group optional "ABRT crash reporting" \
    "Fedora's Automatic Bug Reporting Tool watches for crashes and offers to report them to Fedora." \
    "Guided crash reports to Fedora. Crashes are still recorded by systemd-coredump ('coredumpctl list')." \
    abrt abrt-desktop abrt-cli abrt-gui abrt-applet

  remove_group optional "KDE crash handler (DrKonqi)" \
    "DrKonqi shows the 'application crashed' dialog and helps send backtraces to KDE." \
    "The crash dialog. Crashes are still logged by systemd-coredump." \
    drkonqi plasma-drkonqi

  remove_group optional "KDE PIM suite (mail, calendar, contacts, Akonadi)" \
    "KMail, Kontact, KOrganizer, Akregator, KAddressBook and the Akonadi storage service they share. Akonadi can run a database server in the background once any PIM app was used." \
    "KDE's mail/calendar/contacts apps and calendar events in the Plasma clock. Use webmail or Thunderbird instead." \
    kmail kontact korganizer akregator kaddressbook kmail-account-wizard akonadi-import-wizard \
    merkuro pim-sieve-editor pim-data-exporter ktnef kdepim-addons kdepim-runtime akonadi-server

  local -a lo
  mapfile -t lo < <(rpm -qa --qf '%{NAME}\n' | grep -E '^libreoffice-' | sort -u)
  remove_group optional "LibreOffice" \
    "The office suite (all installed LibreOffice components, listed explicitly — no wildcards are passed to dnf)." \
    "Local editing of .docx/.xlsx/.odt files. Install it again any time, or use the Flatpak." \
    "${lo[@]}"

  remove_group optional "KDE games" \
    "Small preinstalled card/puzzle games." \
    "Those games." \
    kmahjongg kmines kpat ksudoku knights kblackbox kbounce kolf

  remove_group optional "Extra media apps" \
    "Dragon Player, Elisa music player, Kamoso webcam app, K3b disc burner." \
    "Those apps. Haruna/mpv/VLC (if installed) and Gwenview are not touched." \
    dragon elisa-player kamoso k3b

  remove_group optional "KDE Connect" \
    "Phone integration daemon. It runs in the background and keeps network listeners open." \
    "Phone notifications, file sharing, clipboard sync and remote control via KDE Connect." \
    kde-connect kde-connect-libs kdeconnectd

  remove_group optional "Remote desktop and chat apps" \
    "KRDC (remote desktop client), KRFB (desktop sharing server), NeoChat (Matrix), Konversation (IRC), KTorrent." \
    "Those apps." \
    krdc krfb neochat konversation ktorrent

  remove_group optional "Rarely used utilities" \
    "Welcome wizard, help center, screen magnifier, text-to-speech helper, mouse-click helper, legacy file finder, journal viewer, QR scanner, scanner app, Fedora Media Writer." \
    "Those apps. Dolphin, Kate/KWrite, Konsole, Spectacle, Ark, Gwenview, Okular and System Settings are kept." \
    plasma-welcome khelpcenter kmag kmouth kmousetool kfind kjournald qrca skanpage mediawriter

  remove_group optional "Printing extras" \
    "The Plasma printer applet, network printer discovery and HP printer drivers. The CUPS core is left in place (disable it in the services stage)." \
    "Printer setup UI and HP printer support." \
    print-manager cups-browsed hplip hplip-gui system-config-printer-udev

  remove_group optional "Plasma Browser Integration" \
    "Connects browsers to Plasma (media controls, download progress, tab search in KRunner)." \
    "Those integrations; browsers work normally." \
    plasma-browser-integration

  explain "Discover is KDE's graphical software center. Without it you update with 'sudo dnf upgrade --refresh' and 'flatpak update'. Removing it also removes its tray update notifier (a PackageKit client)."
  remove_group optional "Discover software center" \
    "Removes Discover and its update notifier/back-ends. PackageKit itself stays (other tools may use it)." \
    "Graphical app store and update notifications." \
    plasma-discover plasma-discover-notifier plasma-discover-flatpak plasma-discover-packagekit \
    plasma-discover-offline-updates plasma-discover-kns plasma-discover-libs

  remove_group optional "Screen reader (Orca)" \
    "Orca is the screen reader for blind and low-vision users." \
    "Spoken screen reading. KEEP this if you or anyone using this PC needs it." \
    orca

  if command -v flatpak >/dev/null 2>&1 && [[ -n $(flatpak list --runtime --columns=application 2>/dev/null) ]]; then
    if propose safe "Remove unused Flatpak runtimes" \
        "Runs 'flatpak uninstall --unused', which removes runtimes and extensions that no installed app needs any more (often several GB after app updates). flatpak lists them and asks before removing." \
        "Nothing; a runtime is downloaded again automatically if an app needs it later." \
        "Not needed — removed runtimes are reinstalled on demand."; then
      sudo_run flatpak uninstall --unused
    fi
  fi

  explain "Finally, dnf can remove packages that were only installed as dependencies and are no longer needed by anything."
  local -a auto=()
  local plan
  sudo_init
  if ! plan=$(dnf_preview autoremove); then
    warn "Skipping autoremove: could not reliably read dnf's plan (shown above)."
    return 0
  fi
  [[ -n $plan ]] && mapfile -t auto <<<"$plan"
  if (( ${#auto[@]} )); then
    local p blocked=''
    for p in "${auto[@]}"; do is_protected "$p" && blocked+=" $p"; done
    if [[ -n $blocked ]]; then
      warn "Skipping autoremove: it would remove protected packages:$blocked"
    elif propose optional "Remove unneeded dependencies (dnf autoremove)" \
        "Removes ${#auto[@]} packages nothing depends on any more: ${auto[*]}" \
        "Nothing that any installed package needs." \
        "./FedoraTweaks rollback — or: sudo dnf install ${auto[*]}"; then
      sudo_run dnf autoremove
      if [[ $FT_DRY_RUN != 1 ]]; then
        local -a gone=()
        for p in "${auto[@]}"; do pkg_installed "$p" || gone+=("$p"); done
        (( ${#gone[@]} )) && journal_add "dnf autoremove: ${gone[*]}" "sudo dnf install $(quote_cmd "${gone[@]}")"
      fi
    fi
  else
    ok "No unneeded dependencies."
  fi
}
