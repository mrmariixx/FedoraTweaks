# shellcheck shell=bash
# Stage 4 — services and timers. Only units that exist AND are enabled/running are offered.
# Never touched: NetworkManager, systemd-resolved, D-Bus, polkit, SELinux, firewalld,
# systemd-oomd, PipeWire/WirePlumber, chronyd, fwupd, power management, the display manager.

stage_services() {
  header "Stage 4 — Services and timers"
  explain "Each service below is only offered if it exists and is enabled or running on this system. Disabled services can always be re-enabled; nothing is uninstalled here. Expect small savings (a few MB of RAM each, fewer background wakeups) — not higher FPS."

  if units_relevant cups.service cups.socket cups.path cups-browsed.service; then
    propose optional "Disable printing (CUPS)" \
      "Stops and disables the CUPS print server and cups-browsed, which constantly listens for network printers." \
      "You cannot print or scan-to-print until re-enabled. PDF export still works." \
      "./FedoraTweaks rollback — or: sudo systemctl enable --now cups.socket cups.service cups-browsed.service" \
      && svc_off disable "Printing" cups-browsed.service cups.path cups.socket cups.service
  fi

  if units_relevant avahi-daemon.service avahi-daemon.socket; then
    propose optional "Disable Avahi (mDNS / zero-conf discovery)" \
      "Masks avahi-daemon, which announces this PC and discovers network printers, scanners and '.local' hostnames. Masking is needed because D-Bus would otherwise start it on demand." \
      "Automatic discovery of network printers/scanners and resolving 'name.local' addresses. Browsers and KDE Connect use their own discovery and keep working." \
      "./FedoraTweaks rollback — or: sudo systemctl unmask avahi-daemon.socket avahi-daemon.service && sudo systemctl enable --now avahi-daemon.socket" \
      && svc_off mask "Avahi" avahi-daemon.socket avahi-daemon.service
  fi

  if units_relevant bluetooth.service; then
    explain "Bluetooth: many gamepads (Xbox, DualSense) and headsets use it. Keep it unless you are sure."
    propose optional "Disable Bluetooth" \
      "Masks the BlueZ daemon so it does not run or get started on demand." \
      "All Bluetooth devices: controllers, headsets, mice, keyboards." \
      "./FedoraTweaks rollback — or: sudo systemctl unmask bluetooth.service && sudo systemctl enable --now bluetooth.service" \
      && svc_off mask "Bluetooth" bluetooth.service
  fi

  if units_relevant ModemManager.service; then
    local modems tier=optional
    modems=$(mmcli -L 2>/dev/null)
    grep -qi 'no modems were found' <<<"$modems" && tier=safe
    propose "$tier" "Disable ModemManager" \
      "Masks ModemManager, which manages mobile broadband (4G/5G/WWAN) modems. $( [[ $tier == safe ]] && echo 'No modems were detected on this PC.')" \
      "Mobile broadband modems and USB LTE sticks." \
      "./FedoraTweaks rollback — or: sudo systemctl unmask ModemManager.service && sudo systemctl enable --now ModemManager.service" \
      && svc_off mask "ModemManager" ModemManager.service
  fi

  if units_relevant NetworkManager-wait-online.service; then
    propose optional "Do not wait for the network during boot" \
      "Disables NetworkManager-wait-online, which delays the end of boot until a network connection is up. NetworkManager itself keeps running and connects normally." \
      "Services that need the network very early (NFS/SMB mounts in /etc/fstab, some servers) may start before the network. Typical desktops are unaffected. Measurable with 'systemd-analyze'." \
      "./FedoraTweaks rollback — or: sudo systemctl enable NetworkManager-wait-online.service" \
      && svc_off disable "Boot network wait" NetworkManager-wait-online.service
  fi

  if units_relevant dnf-makecache.timer; then
    propose optional "Disable automatic DNF metadata refresh" \
      "Disables dnf-makecache.timer, which periodically downloads repository metadata in the background (network + disk + CPU activity that can coincide with gaming)." \
      "Nothing functional: dnf refreshes metadata when you run it (use 'dnf upgrade --refresh'). Discover, if kept, still checks for updates itself." \
      "./FedoraTweaks rollback — or: sudo systemctl enable --now dnf-makecache.timer" \
      && svc_off disable "DNF metadata timer" dnf-makecache.timer
  fi

  if units_relevant plocate-updatedb.timer; then
    propose optional "Disable the daily 'locate' database rebuild" \
      "Disables plocate-updatedb.timer, which scans the whole filesystem daily for the 'locate' command." \
      "'locate' results become stale (run 'sudo updatedb' manually when needed). 'find' and Dolphin search are unaffected." \
      "./FedoraTweaks rollback — or: sudo systemctl enable --now plocate-updatedb.timer" \
      && svc_off disable "plocate timer" plocate-updatedb.timer
  fi

  if units_relevant raid-check.timer mdmonitor.service && ! grep -q '^md' /proc/mdstat 2>/dev/null; then
    propose safe "Disable software-RAID monitoring (no RAID arrays found)" \
      "Disables mdmonitor and the weekly raid-check timer. /proc/mdstat shows no md arrays on this system." \
      "Nothing unless you later create an mdadm software RAID." \
      "./FedoraTweaks rollback — or: sudo systemctl enable --now mdmonitor.service raid-check.timer" \
      && svc_off disable "mdraid monitoring" raid-check.timer mdmonitor.service
  fi

  if units_relevant lvm2-monitor.service; then
    sudo_init
    if [[ -z $(sudo pvs --noheadings 2>/dev/null) ]]; then
      propose safe "Disable LVM monitoring (no LVM volumes found)" \
        "Disables lvm2-monitor, which watches LVM snapshots/mirrors. Fedora uses Btrfs by default and 'pvs' shows no LVM physical volumes." \
        "Nothing unless you later set up LVM." \
        "./FedoraTweaks rollback — or: sudo systemctl enable --now lvm2-monitor.service" \
        && svc_off disable "LVM monitoring" lvm2-monitor.service
    fi
  fi

  if units_relevant iscsid.socket iscsiuio.socket iscsi.service iscsi-onboot.service; then
    propose optional "Disable iSCSI initiator services" \
      "Disables iSCSI sockets/services, used only to mount network block storage (SAN)." \
      "Access to iSCSI network disks." \
      "./FedoraTweaks rollback" \
      && svc_off disable "iSCSI" iscsi-onboot.service iscsi.service iscsid.socket iscsiuio.socket
  fi

  if unit_exists fstrim.timer && [[ $(unit_enabled_state fstrim.timer) != enabled ]] \
     && lsblk -dno ROTA 2>/dev/null | grep -qx ' *0'; then
    if propose safe "Enable weekly SSD TRIM (fstrim.timer)" \
        "Tells your SSDs once a week which blocks are free, which keeps write performance steady over time. Fedora normally enables this; it is currently off here." \
        "Nothing." \
        "./FedoraTweaks rollback — or: sudo systemctl disable --now fstrim.timer"; then
      sudo_run systemctl enable --now fstrim.timer && journal_add "Enabled fstrim.timer" "sudo systemctl disable --now fstrim.timer"
    fi
  fi

  if [[ ! -f /etc/systemd/journald.conf.d/90-fedoratweaks.conf ]]; then
    local jsize
    jsize=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n 1)
    if propose optional "Cap system logs at 500 MB (currently ${jsize:-unknown})" \
        "journald may keep up to 10% of the filesystem (max 4 GB) of logs. This caps it at 500 MB — weeks of history on a desktop." \
        "Older log history beyond the cap." \
        "./FedoraTweaks rollback — or delete /etc/systemd/journald.conf.d/90-fedoratweaks.conf"; then
      sudo_run mkdir -p /etc/systemd/journald.conf.d \
        && root_write /etc/systemd/journald.conf.d/90-fedoratweaks.conf "[Journal]
SystemMaxUse=500M" "journald 500 MB cap" "sudo systemctl restart systemd-journald" \
        && sudo_run systemctl restart systemd-journald
    fi
  fi

  note "Deliberately kept" \
    "NetworkManager, systemd-resolved, D-Bus, polkit, SELinux, firewalld, systemd-oomd, PipeWire/WirePlumber, chronyd (clock), fwupd, tuned/tuned-ppd (power profiles), smartd (disk health), the display manager, udisks2 (USB drives) and switcheroo-control (needed when the Ryzen iGPU and a discrete GPU are both active). sssd is left alone: Fedora's authentication stack may use it."
}
