# shellcheck shell=bash
# Stage 1 — read-only audit. Changes nothing; writes a plain-text report you can share.

audit_section() {
  printf '\n%s## %s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"
  printf '%s' "$C_DIM"; wrap '   ' "Tells us: $2"; printf '%s' "$C_RESET"
}

audit_body() {
  printf 'FedoraTweaks %s audit — %s\n' "$FT_VERSION" "$(date '+%F %T')"

  audit_section "Fedora release and kernel" \
    "which release/kernel you run, whether the kernel is Fedora's signed build, and whether a reboot is pending."
  ro 'grep -E "^(PRETTY_NAME|VERSION_ID|VARIANT_ID)=" /etc/os-release'
  ro 'uname -r'
  ro 'rpm -q kernel-core --qf "%{VERSION}-%{RELEASE}.%{ARCH}  vendor: %{VENDOR}\n" | sort -V | tail -n 3'

  audit_section "CPU" \
    "CPU model, the frequency driver (amd-pstate-epp is expected on Zen 2+), governor and energy-performance preference."
  ro 'lscpu | grep -E "^(Model name|CPU\(s\)|Thread\(s\) per core|CPU max MHz)"'
  ro 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver /sys/devices/system/cpu/amd_pstate/status 2>/dev/null'
  ro 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null'
  ro 'journalctl -k -b --no-pager -o cat | grep -i microcode | head -n 3'

  audit_section "GPU, driver and ReBAR" \
    "that amdgpu drives your card, VRAM size, PCIe link, and whether Resizable BAR (Smart Access Memory) is active — amdgpu logs 'BAR=' roughly equal to VRAM when it is."
  ro 'lspci -nnk | grep -EA3 "VGA|Display|3D controller"'
  ro 'for d in /sys/class/drm/card[0-9]*/device; do [ "$(cat $d/vendor 2>/dev/null)" = 0x1002 ] || continue; echo "$d: VRAM $(( $(cat $d/mem_info_vram_total 2>/dev/null || echo 0) / 1048576 )) MiB, PCIe $(cat $d/current_link_speed 2>/dev/null) x$(cat $d/current_link_width 2>/dev/null), perf level $(cat $d/power_dpm_force_performance_level 2>/dev/null)"; done'
  ro 'journalctl -k -b --no-pager -o cat | grep -iE "amdgpu.*(VRAM|BAR|aper)" | head -n 6'
  ro 'sudo lspci -vv -d 1002: 2>/dev/null | grep -iA3 "Resizable BAR" | head -n 12'

  audit_section "Mesa, Vulkan and firmware" \
    "Mesa/RADV versions, whether 32-bit Vulkan (needed by Steam/Proton) is installed, and GPU firmware packages."
  ro 'rpm -q mesa-dri-drivers mesa-vulkan-drivers mesa-vulkan-drivers.i686 mesa-dri-drivers.i686 vulkan-loader vulkan-loader.i686 linux-firmware amd-gpu-firmware amd-ucode-firmware 2>&1'
  ro 'command -v vulkaninfo >/dev/null && vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName|driverInfo|apiVersion" || echo "vulkaninfo not installed (package vulkan-tools)"'
  ro 'journalctl -k -b --no-pager -o cat | grep -iE "amdgpu.*(firmware|fw).*(fail|error|missing)" | head -n 5 || true'

  audit_section "Memory, storage and motherboard" \
    "RAM size and configured speed (is EXPO active?), disks/filesystems, board model and BIOS version (old BIOS = old AGESA)."
  ro 'free -h'
  ro 'sudo dmidecode -t memory 2>/dev/null | grep -E "^\s+(Size|Speed|Configured Memory Speed|Part Number):" | grep -v "No Module" | sort | uniq -c'
  ro 'lsblk -o NAME,SIZE,TYPE,FSTYPE,ROTA,MODEL,MOUNTPOINTS'
  ro 'findmnt -no SOURCE,FSTYPE,OPTIONS /'
  ro 'cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date 2>/dev/null | paste -sd " "'

  audit_section "KDE Plasma and display protocol" \
    "Plasma/KWin versions, that the session is Wayland, and which login manager is in use."
  ro 'plasmashell --version 2>/dev/null; kwin_wayland --version 2>/dev/null'
  ro 'echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-?}"'
  ro 'readlink -f /etc/systemd/system/display-manager.service'

  audit_section "Packages" \
    "how many RPMs are installed, which groups and repositories are enabled, the largest packages, and Flatpaks."
  ro 'rpm -qa | wc -l'
  ro 'dnf repolist 2>/dev/null'
  ro 'dnf group list --installed 2>/dev/null | head -n 40'
  ro 'rpm -qa --qf "%{SIZE}\t%{NAME}\n" | sort -rn | head -n 25 | awk -F"\t" "{printf \"%8.1f MiB  %s\n\", \$1/1048576, \$2}"'
  ro 'command -v flatpak >/dev/null && flatpak list --app --columns=application,installation || echo "flatpak not installed"'

  audit_section "systemd services and timers" \
    "what starts at boot, what is running right now, scheduled background jobs, and failed units."
  ro 'systemctl list-unit-files --type=service --state=enabled --no-legend | awk "{print \$1}" | column -c 120'
  ro 'systemctl list-units --type=service --state=running --no-legend | awk "{print \$1}" | column -c 120'
  ro 'systemctl list-timers --all --no-pager | head -n 30'
  ro 'systemctl --failed --no-legend --no-pager'
  ro 'systemctl --user list-units --type=service --state=running --no-legend | awk "{print \$1}" | column -c 120'

  audit_section "Startup applications" \
    "XDG autostart entries (system-wide and yours). A user file with Hidden=true overrides the system one."
  ro 'ls /etc/xdg/autostart/'
  ro 'ls ~/.config/autostart/ 2>/dev/null || echo "(none)"'

  audit_section "Resource usage" \
    "current RAM use, the 25 largest processes, process counts and load. Measure properly with the baseline stage."
  ro 'uptime'
  ro 'ps -eo rss=,comm= --sort=-rss | head -n 25 | awk "{printf \"%8.1f MiB  %s\n\", \$1/1024, \$2}"'
  ro 'echo "processes: $(ps -e --no-headers | wc -l)"'

  audit_section "Boot time" \
    "firmware vs. loader vs. kernel vs. userspace time, and which units hold up boot."
  ro 'systemd-analyze time'
  ro 'systemd-analyze blame --no-pager | head -n 20'
  ro 'systemd-analyze critical-chain --no-pager | head -n 25'

  audit_section "Power, memory management and swap" \
    "power profile (Fedora uses tuned-ppd), zram swap, and kernel memory settings relevant to games."
  ro 'command -v powerprofilesctl >/dev/null && powerprofilesctl get || echo "powerprofilesctl not found"'
  ro 'zramctl 2>/dev/null; swapon --show'
  ro 'sysctl vm.swappiness vm.page-cluster vm.max_map_count kernel.split_lock_mitigate 2>/dev/null'
  ro 'systemctl is-active systemd-oomd'

  audit_section "Security posture" \
    "Secure Boot, SELinux, firewall, kernel lockdown and TPM — relevant to the EAC Linux v2 requirements."
  ro 'mokutil --sb-state 2>&1'
  ro 'getenforce 2>/dev/null; systemctl is-active firewalld'
  ro 'cat /sys/kernel/security/lockdown 2>/dev/null; cat /sys/kernel/security/lsm 2>/dev/null; echo'
  ro 'echo "TPM version: $(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo none)"'
  ro 'cat /proc/cmdline'

  audit_section "Quick observations" "automatic hints from the data above. Nothing is changed."
  audit_observations
}

audit_observations() {
  local d vram bar
  [[ ${XDG_SESSION_TYPE:-} == wayland ]] || echo "   - Session is not Wayland (${XDG_SESSION_TYPE:-unknown}). Plasma 6 on Fedora is Wayland-first."
  for d in /sys/class/drm/card[0-9]*/device; do
    [[ $(cat "$d/vendor" 2>/dev/null) == 0x1002 ]] || continue
    vram=$(( $(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 ))
    (( vram > 2048 )) || continue
    bar=$(journalctl -k -b --no-pager -o cat 2>/dev/null | grep -oE 'BAR=[0-9]+M' | head -n 1 | tr -dc 0-9)
    if [[ -n $bar ]] && (( bar < vram / 2 )); then
      echo "   - Resizable BAR looks OFF (BAR ${bar} MiB < VRAM ${vram} MiB). Enable 'Above 4G Decoding' and 'Re-Size BAR' in the BIOS."
    elif [[ -n $bar ]]; then
      echo "   - Resizable BAR looks ON (BAR ${bar} MiB, VRAM ${vram} MiB)."
    fi
  done
  [[ $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null) == active ]] \
    || echo "   - amd-pstate is not in 'active' (EPP) mode. That is fine on older CPUs; on Zen 3+ check the BIOS CPPC setting."
  rpm -q --quiet mesa-vulkan-drivers.i686 || echo "   - 32-bit Vulkan driver missing (installed by the gaming stage / Steam)."
  units_relevant cups-browsed.service && echo "   - cups-browsed is running (network printer discovery)."
  [[ $(kreadconfig6 --file baloofilerc --group 'Basic Settings' --key 'Indexing-Enabled' 2>/dev/null) == false ]] \
    || echo "   - Baloo file indexing is enabled."
  mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled' || echo "   - Secure Boot is not enabled (required by EAC Linux v2)."
  echo "   (end of observations)"
}

stage_audit() {
  header "Stage 1 — Audit (read-only)"
  explain "Collects facts about this machine. Nothing is changed. A few hardware queries (PCIe BAR, RAM speed) need sudo for reading only."
  sudo_init
  local report
  report="$FT_REPORT_DIR/audit-$(date +%Y%m%d-%H%M%S).txt"
  audit_body 2>&1 | tee /dev/tty | sed 's/\x1b\[[0-9;]*m//g' >"$report"
  echo
  ok "Audit report saved: $report"
  explain "Share this file when asking for system-specific advice. It contains hardware and package details but no passwords or personal files."
}
