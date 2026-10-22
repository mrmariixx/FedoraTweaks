
# shellcheck shell=bash
# Stage 4 — service and timer optimization.
# No package removal. Essential networking, security, audio and power services
# are deliberately excluded. Only existing, relevant units are offered.

stage_services() {
  header "Stage 4 — Services and timers"

  explain "Review optional background services and timers. Each change requires confirmation. Disabling services may reduce background activity, but usually does not increase gaming FPS directly."

  local modems=''
  local tier=optional
  local raid_active=0
  local lvm_output=''
  local lvm_check=1
  local jsize=''
  local journald_config=/etc/systemd/journald.conf.d/90-fedoratweaks.conf
  local disk_rotational=''
  local trim_enabled=''

  # 1. Printing and printer discovery.
  if units_relevant cups.service cups.socket cups.path cups-browsed.service; then
    if propose optional "Disable printing services" \
        "Stops and disables CUPS and cups-browsed units that are present and relevant on this system." \
        "Printing and network printer discovery may stop working. Re-enable the services if you use a printer or scanner workflow that depends on them." \
        "./FedoraTweaks rollback — or: sudo systemctl enable --now cups.socket cups.service cups-browsed.service"; then

      svc_off disable "Printing" \
        cups-browsed.service cups.path cups.socket cups.service
    fi
  fi

  # 2. Avahi multicast DNS.
  if units_relevant avahi-daemon.service avahi-daemon.socket; then
    if propose optional "Disable Avahi (mDNS discovery)" \
        "Disables Avahi, which provides multicast DNS and local network service discovery. It may be started on demand through its socket, so the socket is handled too." \
        "Printer and scanner discovery and hostname.local resolution may stop working. Some local network applications rely on mDNS." \
        "./FedoraTweaks rollback — or: sudo systemctl unmask avahi-daemon.service avahi-daemon.socket && sudo systemctl enable --now avahi-daemon.service avahi-daemon.socket"; then

      svc_off mask "Avahi" \
        avahi-daemon.socket avahi-daemon.service
    fi
  fi

  # 3. Bluetooth.
  if units_relevant bluetooth.service; then
    explain "Bluetooth can be essential for wireless controllers, headphones, mice and keyboards."

    if propose optional "Disable Bluetooth" \
        "Masks the BlueZ Bluetooth daemon to prevent it from running or starting on demand." \
        "Bluetooth controllers, headsets, mice, keyboards and other Bluetooth peripherals will stop working." \
        "./FedoraTweaks rollback — or: sudo systemctl unmask bluetooth.service && sudo systemctl enable --now bluetooth.service"; then

      svc_off mask "Bluetooth" bluetooth.service
    fi
  fi

  # 4. Mobile broadband.
  if units_relevant ModemManager.service; then
    tier=optional
    modems=''

    if command -v mmcli >/dev/null 2>&1; then
      modems=$(mmcli -L 2>/dev/null || true)

      if grep -qiE 'no modems were found|no modems found' <<<"$modems"; then
        tier=safe
      fi
    fi

    if [[ $tier == safe ]]; then
      info "ModemManager reports no detected modems."
    else
      explain "ModemManager may be required by internal WWAN devices or USB mobile broadband modems."
    fi

    if propose "$tier" "Disable ModemManager" \
        "Stops mobile broadband management. This service is only offered because the unit is relevant on this system." \
        "Internal WWAN modems, cellular connections and compatible USB LTE/5G modems may stop working." \
        "./FedoraTweaks rollback — or: sudo systemctl unmask ModemManager.service && sudo systemctl enable --now ModemManager.service"; then

      svc_off mask "ModemManager" ModemManager.service
    fi
  fi

  # 5. NetworkManager wait-online.
  if units_relevant NetworkManager-wait-online.service; then
    if propose optional "Skip waiting for network during boot" \
        "Disables NetworkManager-wait-online. NetworkManager itself remains enabled and continues managing connectivity." \
        "Services requiring a network connection during early boot may start before networking is ready. Network-dependent mounts and server workloads need particular care." \
        "./FedoraTweaks rollback — or: sudo systemctl enable NetworkManager-wait-online.service"; then

      svc_off disable "Boot network wait" \
        NetworkManager-wait-online.service
    fi
  fi

  # 6. DNF metadata refresh.
  if units_relevant dnf-makecache.timer; then
    if propose optional "Disable automatic DNF metadata refresh" \
        "Disables the periodic metadata refresh timer to reduce scheduled background downloads and disk activity." \
        "Repository metadata may become stale between manual refreshes. DNF can refresh it when needed; use 'sudo dnf upgrade --refresh' for updates." \
        "./FedoraTweaks rollback — or: sudo systemctl enable --now dnf-makecache.timer"; then

      svc_off disable "DNF metadata timer" dnf-makecache.timer
    fi
  fi

  # 7. plocate database refresh.
  if units_relevant plocate-updatedb.timer; then
    if propose optional "Disable scheduled plocate database updates" \
        "Disables the timer that periodically rebuilds the plocate file index." \
        "The locate database may become outdated. Run 'sudo updatedb' manually if you need to refresh it. Normal filesystem access and find remain available." \
        "./FedoraTweaks rollback — or: sudo systemctl enable --now plocate-updatedb.timer"; then

      svc_off disable "plocate timer" plocate-updatedb.timer
    fi
  fi

  # 8. Software RAID monitoring.
  if [[ -r /proc/mdstat ]] &&
     ! grep -qE '^md[0-9]+[[:space:]]*:' /proc/mdstat; then
    raid_active=0
  else
    raid_active=1
  fi

  if (( raid_active == 0 )) &&
     units_relevant raid-check.timer mdmonitor.service; then

    if propose optional "Disable software RAID monitoring" \
        "No active md RAID arrays were detected in /proc/mdstat. Offers to disable the corresponding monitoring units." \
        "RAID monitoring will not be available if you later configure Linux software RAID. This does not disable hardware RAID." \
        "./FedoraTweaks rollback — or: sudo systemctl enable --now mdmonitor.service raid-check.timer"; then

      svc_off disable "mdraid monitoring" \
        raid-check.timer mdmonitor.service
    fi
  fi

  # 9. LVM monitoring.
  if units_relevant lvm2-monitor.service; then
    if command -v pvs >/dev/null 2>&1; then
      sudo_init

      if lvm_output=$(sudo pvs --noheadings -o pv_name 2>/dev/null); then
        lvm_check=0
      else
        lvm_check=1
      fi

      if (( lvm_check == 0 )) &&
         [[ -z ${lvm_output//[[:space:]]/} ]]; then

        if propose safe "Disable LVM monitoring" \
            "The LVM physical volume query returned no physical volumes. Offers to disable lvm2-monitor." \
            "LVM monitoring will not be active if you later configure LVM snapshots, mirrors or logical volumes. Re-enable it if your storage setup changes." \
            "./FedoraTweaks rollback — or: sudo systemctl enable --now lvm2-monitor.service"; then

          svc_off disable "LVM monitoring" lvm2-monitor.service
        fi

      elif (( lvm_check != 0 )); then
        warn "Could not reliably inspect LVM volumes. Keeping LVM monitoring unchanged."
      else
        info "LVM physical volumes detected; keeping LVM monitoring enabled."
      fi
    else
      warn "The pvs command is unavailable. Cannot safely determine whether LVM monitoring is needed."
    fi
  fi

  # 10. iSCSI initiator services.
  if units_relevant iscsid.socket iscsiuio.socket iscsi.service iscsi-onboot.service; then
    if propose optional "Disable iSCSI initiator services" \
        "Offers to disable relevant iSCSI sockets and services used for network block-storage connections." \
        "Network-attached iSCSI disks and storage connections may become unavailable. Do not disable these units if your root filesystem or data storage depends on iSCSI." \
        "./FedoraTweaks rollback — or: review the affected iSCSI units and restore their original enabled states"; then

      svc_off disable "iSCSI" \
        iscsi-onboot.service iscsi.service \
        iscsid.socket iscsiuio.socket
    fi
  fi

  # 11. Weekly SSD TRIM.
  if unit_exists fstrim.timer; then
    trim_enabled=$(unit_enabled_state fstrim.timer 2>/dev/null || true)

    if [[ $trim_enabled != enabled ]]; then
      disk_rotational=$(lsblk -dnro ROTA 2>/dev/null || true)

      if grep -qx '0' <<<"$disk_rotational"; then
        if propose safe "Enable weekly filesystem TRIM" \
            "Enables fstrim.timer, which periodically discards unused blocks on supported SSDs and thin-provisioned storage." \
            "The timer will schedule periodic TRIM operations. Some storage devices or filesystems may not support discard." \
            "./FedoraTweaks rollback — or: sudo systemctl disable --now fstrim.timer"; then

          if sudo_run systemctl enable --now fstrim.timer; then
            journal_add "Enabled fstrim.timer" \
              "sudo systemctl disable --now fstrim.timer"
          else
            warn "Could not enable fstrim.timer."
          fi
        fi
      else
        info "No non-rotational block device was detected, or device information is incomplete. Skipping automatic TRIM changes."
      fi
    else
      info "fstrim.timer is already enabled."
    fi
  fi

  # 12. Optional journald disk-usage cap.
  # Never overwrite an existing FedoraTweaks drop-in.
  if [[ ! -e $journald_config && ! -L $journald_config ]]; then
    jsize=$(journalctl --disk-usage 2>/dev/null |
      grep -oE '[0-9]+([.][0-9]+)?[[:space:]]*[KMGT]B?' |
      head -n 1 || true)

    if propose optional "Limit persistent system journal to 500 MiB" \
        "Creates a dedicated journald drop-in with SystemMaxUse=500M. Current reported journal usage: ${jsize:-unknown}." \
        "Older journal entries may be vacuumed to respect the configured limit. This can reduce historical logs available for troubleshooting." \
        "./FedoraTweaks rollback — remove $journald_config and restart systemd-journald"; then

      if sudo_run mkdir -p /etc/systemd/journald.conf.d &&
         root_write "$journald_config" \
           "[Journal]
SystemMaxUse=500M" \
           "journald 500 MiB cap" \
           "sudo systemctl restart systemd-journald"; then

        if sudo_run systemctl restart systemd-journald; then
          journal_add "journald SystemMaxUse=500M" \
            "Remove $journald_config and restart systemd-journald"
          ok "journald configuration updated."
        else
          warn "The configuration was written, but journald could not be restarted. Check systemd-journald status."
        fi
      else
        warn "Could not write the journald configuration."
      fi
    fi
  else
    info "FedoraTweaks journald drop-in already exists; leaving it unchanged."
  fi

  note "Deliberately kept" \
    "NetworkManager, systemd-resolved, D-Bus, polkit, SELinux, firewalld, systemd-oomd, PipeWire/WirePlumber, chronyd, fwupd, tuned/tuned-ppd, smartd, the display manager, udisks2, switcheroo-control and sssd. Their roles include networking, security, audio, power management, storage, hybrid graphics and authentication."

  ok "Stage 4 completed. Review the journal before rolling back or changing more services."
}
