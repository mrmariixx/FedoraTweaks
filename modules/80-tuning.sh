
# shellcheck shell=bash
# Stage 8 — performance tuning.
# Only reversible changes with a plausible, measurable effect are offered.
# Results depend on hardware and workload; no FPS gains are guaranteed.

tune_power_profile() {
  command -v powerprofilesctl >/dev/null 2>&1 || {
    info "powerprofilesctl not found — skipping power profile."
    return 0
  }

  local cur profiles
  cur=$(powerprofilesctl get 2>/dev/null) || cur=''
  profiles=$(powerprofilesctl list 2>/dev/null) || profiles=''

  if [[ $cur == performance ]]; then
    ok "Power profile is already 'performance'."
    return 0
  fi

  if [[ -z $cur ]]; then
    warn "Could not read the current power profile."
    return 0
  fi

  if ! grep -qE '(^|[[:space:]])performance([[:space:]]|$)' <<<"$profiles"; then
    info "The performance profile is not reported as available — skipping."
    return 0
  fi

  if propose optional "Use the 'performance' power profile (currently '$cur')" \
      "Requests the performance profile through Fedora's power-profile service. It may favour responsiveness and higher clocks, depending on the CPU, firmware and power-profile backend. GameMode can instead request performance behaviour only while a game runs." \
      "Higher power consumption, fan noise and temperatures. FPS improvements are workload-dependent." \
      "./FedoraTweaks rollback — or: powerprofilesctl set $cur"; then
    if run powerprofilesctl set performance; then
      [[ $FT_DRY_RUN == 1 ]] || journal_add \
        "Power profile performance (was $cur)" \
        "powerprofilesctl set $cur"
    else
      warn "Could not switch to the performance profile."
    fi
  fi
}

tune_zram() {
  local swp pc
  swp=$(sysctl -n vm.swappiness 2>/dev/null) || swp='unknown'
  pc=$(sysctl -n vm.page-cluster 2>/dev/null) || pc='unknown'

  if [[ ! -e /dev/zram0 ]]; then
    info "No /dev/zram0 device — skipping zram tuning."
    return 0
  fi

  if [[ -f /etc/sysctl.d/90-fedoratweaks-zram.conf ]]; then
    ok "zram sysctl tuning is already configured."
    return 0
  fi

  if propose optional "Tune memory reclaim for zram (swappiness=$swp, page-cluster=$pc)" \
      "Keeps Fedora's compressed zram swap enabled, while setting vm.swappiness=180 and vm.page-cluster=0. This may help under memory pressure by allowing earlier use of compressed swap and avoiding swap readahead. It is not a general FPS tweak." \
      "Behaviour under memory pressure may change. If responsiveness worsens, roll back and reboot or restore the previous settings." \
      "./FedoraTweaks rollback — or remove /etc/sysctl.d/90-fedoratweaks-zram.conf and reboot"; then
    if root_write /etc/sysctl.d/90-fedoratweaks-zram.conf \
        "# FedoraTweaks: optional zram-oriented memory reclaim settings.
# Remove this file to revert; reboot or reload sysctl settings.
vm.swappiness = 180
vm.page-cluster = 0" \
        "zram sysctl tuning"; then
      sudo_run sysctl --system >/dev/null || warn "Could not reload sysctl settings. The file may apply at the next boot."
    fi
  fi
}

tune_ntsync() {
  if [[ -e /dev/ntsync ]]; then
    ok "/dev/ntsync exists. No persistent module configuration is needed just because it exists."
    return 0
  fi

  if ! command -v modinfo >/dev/null 2>&1 || ! modinfo ntsync >/dev/null 2>&1; then
    info "The ntsync module is unavailable in this kernel — skipping."
    return 0
  fi

  if [[ -f /etc/modules-load.d/ntsync.conf ]]; then
    info "ntsync is configured for boot, but /dev/ntsync is absent. Check the kernel log and module status."
    return 0
  fi

  if propose optional "Load the ntsync kernel module at boot" \
      "ntsync provides Windows NT synchronization primitives through /dev/ntsync. Compatible Wine/Proton versions can use it when supported. Performance and compatibility effects vary by game and software version." \
      "It may not help every game. If a game becomes less stable, remove the configuration and reboot." \
      "./FedoraTweaks rollback — or delete /etc/modules-load.d/ntsync.conf and reboot"; then
    if root_write /etc/modules-load.d/ntsync.conf \
        "# FedoraTweaks: load ntsync at boot
ntsync" "Load ntsync at boot"; then
      if [[ $FT_DRY_RUN != 1 ]]; then
        if sudo_run modprobe ntsync; then
          if [[ -e /dev/ntsync ]]; then
            ok "ntsync is loaded. Device permissions: $(stat -c '%A %U:%G' /dev/ntsync 2>/dev/null || echo unknown)."
          else
            warn "The module command completed, but /dev/ntsync is absent. Check 'journalctl -k'."
          fi
        else
          warn "Could not load ntsync now. The boot configuration may still be present."
        fi
      fi
    fi
  fi
}

tune_shader_cache() {
  local f="$HOME/.config/environment.d/90-fedoratweaks-mesa.conf"

  if [[ -f $f ]]; then
    ok "Mesa shader-cache configuration already exists ($f) — leaving it alone."
    return 0
  fi

  if propose optional "Increase the Mesa shader-cache limit to 10 GB" \
      "Sets MESA_SHADER_CACHE_MAX_SIZE=10G for applications inheriting the user environment. A larger cache can reduce repeated shader compilation when the default cache limit is reached. It does not eliminate first-run shader compilation or guarantee fewer stutters." \
      "The cache may use up to 10 GB of disk space if needed. Steam's shader pre-caching and Mesa's own cache are separate mechanisms; both may matter depending on the game." \
      "./FedoraTweaks rollback — or delete $f and log out/in"; then
    user_write "$f" \
      "# FedoraTweaks: increase Mesa shader-cache limit.
# Takes effect for applications started after logging in again.
MESA_SHADER_CACHE_MAX_SIZE=10G" \
      "Mesa shader cache limit"
  fi
}

tune_x3d_vcache() {
  local f cur
  f=$(compgen -G '/sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode' | head -n 1)

  # This sysfs control exists only on supported dual-CCD X3D CPUs.
  [[ -n $f && -w $f ]] || return 0

  cur=$(cat "$f" 2>/dev/null) || cur=''
  [[ -n $cur ]] || {
    info "Could not read the AMD 3D V-Cache mode — skipping."
    return 0
  }

  if [[ $cur == cache ]]; then
    ok "AMD 3D V-Cache mode is already 'cache'."
    return 0
  fi

  if propose optional "Prefer the 3D V-Cache CCD for games (currently '$cur')" \
      "On supported dual-CCD Ryzen X3D processors, the amd_x3d_vcache driver exposes a mode that influences scheduling between cache-focused and frequency-focused CCDs. Whether 'cache' improves a workload depends on the game and kernel." \
      "Some workloads may perform worse. Compare repeatable benchmarks before keeping this setting." \
      "./FedoraTweaks rollback — restore '$cur' with: echo '$cur' | sudo tee '$f'"; then
    if root_write /etc/tmpfiles.d/90-fedoratweaks-x3d.conf \
        "# FedoraTweaks: set the supported AMD X3D mode at boot.
# Remove this file to stop applying the setting.
w $f - - - - cache" \
        "AMD 3D V-Cache mode" \
        "echo '$cur' | sudo tee '$f' >/dev/null"; then
      if [[ $FT_DRY_RUN != 1 ]]; then
        if printf '%s\n' cache | sudo tee "$f" >/dev/null; then
          ok "AMD X3D mode is now '$(cat "$f" 2>/dev/null || echo unknown)'."
        else
          warn "Could not change the AMD X3D mode immediately; check the sysfs control."
        fi
      fi
    fi
  fi
}

tune_writeback() {
  local f=/etc/sysctl.d/90-fedoratweaks-writeback.conf memg
  [[ -f $f ]] && {
    ok "Write-back limits are already configured."
    return 0
  }

  memg=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)
  [[ $memg =~ ^[0-9]+$ ]] || memg=0

  if propose optional "Limit dirty-data bursts (vm.dirty_bytes = 256 MiB)" \
      "Linux normally allows a percentage of RAM to hold dirty, unwritten data before throttling and flushing. A fixed 256 MiB dirty-data limit and 64 MiB background threshold may reduce large write bursts during installs or downloads. Results depend on storage speed and workload." \
      "May reduce peak throughput for large writes or copies. It is not expected to improve FPS when the system is idle." \
      "./FedoraTweaks rollback — remove $f and reboot or reload sysctl settings"; then
    if root_write "$f" \
        "# FedoraTweaks: optional dirty-data write-back limits.
# Remove this file to revert to the kernel defaults.
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864" \
        "Write-back limits"; then
      sudo_run sysctl --system >/dev/null || warn "Could not reload sysctl settings. The file may apply at the next boot."
    fi
  fi
}

tune_pipewire_latency() {
  command -v pw-metadata >/dev/null 2>&1 || {
    info "PipeWire tools are unavailable — skipping audio latency tuning."
    return 0
  }

  local f="$HOME/.config/pipewire/pipewire.conf.d/90-fedoratweaks-lowlatency.conf"

  [[ -f $f ]] && {
    ok "PipeWire latency configuration already exists ($f) — leaving it alone."
    return 0
  }

  if propose optional "Lower PipeWire's default quantum to 256 samples" \
      "Sets the default clock quantum to 256 samples, with a minimum of 32 and maximum of 2048. At 48 kHz, 256 samples represent about 5.3 ms per quantum, not the complete end-to-end audio latency. Applications can request different buffer sizes." \
      "More frequent audio processing can increase CPU wake-ups and cause crackling on some hardware. Test voice chat and games; use 512 samples if 256 is unstable." \
      "./FedoraTweaks rollback — remove $f, then restart the user PipeWire services"; then
    if user_write "$f" \
        "# FedoraTweaks: optional PipeWire clock quantum settings.
# Remove this file to revert.
context.properties = {
    default.clock.quantum     = 256
    default.clock.min-quantum = 32
    default.clock.max-quantum = 2048
}" \
        "PipeWire default quantum"; then
      if [[ $FT_DRY_RUN != 1 ]]; then
        systemctl --user restart pipewire pipewire-pulse wireplumber ||
          warn "Could not restart every PipeWire user service. Log out/in to apply the configuration."
      fi
    fi
  fi
}

report_kernel_defaults() {
  local mmc driver pstate
  mmc=$(sysctl -n vm.max_map_count 2>/dev/null) || mmc=''
  if [[ $mmc =~ ^[0-9]+$ ]] && (( mmc >= 1048576 )); then
    ok "vm.max_map_count=$mmc."
  elif [[ $mmc =~ ^[0-9]+$ ]]; then
    warn "vm.max_map_count=$mmc is below 1048576. Some games may need a higher limit; inspect /usr/lib/sysctl.d/ before changing it."
  else
    info "Could not read vm.max_map_count."
  fi

  driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo unknown)
  pstate=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo n/a)
  ok "CPU frequency driver: $driver; amd_pstate status: $pstate. No automatic change applied."

  if systemctl is-active --quiet systemd-oomd; then
    ok "systemd-oomd is active."
  else
    info "systemd-oomd is not active; no change applied."
  fi
}

stage_tuning() {
  header "Stage 8 — Performance tuning"
  explain "These options are experimental or workload-dependent. Apply one at a time, reboot or log out if required, then compare repeatable MangoHud benchmarks. Keep only changes that show a consistent benefit."

  report_kernel_defaults
  tune_power_profile
  tune_zram
  tune_ntsync
  tune_shader_cache
  tune_x3d_vcache
  tune_writeback
  tune_pipewire_latency

  local scx_repo
  scx_repo=$(dnf repoquery --available --qf '%{repoid}\n' scx-scheds 2>/dev/null | head -n 1)

  note "sched-ext schedulers (scx_lavd, scx_bpfland, etc.)" \
    "$( if [[ $scx_repo == fedora || $scx_repo == updates ]]; then
          echo "scx-scheds appears available from Fedora's '$scx_repo' repository. Availability and supported schedulers depend on the Fedora release and kernel."
        else
          echo "scx-scheds was not found in the enabled Fedora repositories. No third-party repository will be added automatically."
        fi ) Test schedulers only if you understand how to return to the default scheduler. Compare several repeatable runs; there is no universally best scheduler for games."

  note "Not applied — and why" \
    "• mitigations=off: disables CPU security protections for a workload-dependent performance effect. Not recommended.
• Disabling split-lock detection: can affect system behaviour and is relevant only to specific workloads; inspect kernel logs before considering it.
• amdgpu.ppfeaturemask, forced GPU clocks and power limits: can increase heat and power, reduce stability and require hardware-specific testing.
• Custom kernels: can complicate Secure Boot, maintenance and troubleshooting. No claim is made that every custom kernel necessarily breaks game anti-cheat.
• iommu=pt: not a general gaming-performance tweak. No blanket compatibility claim about EAC is made here.
• kernel.nmi_watchdog=0 / nowatchdog: removes monitoring functionality for a benefit that is usually difficult to measure in games.
• Transparent hugepages 'always': has no consistent gaming benefit and may introduce memory-compaction overhead.
• TCP BBR or qdisc changes: mainly affect network throughput and queueing; they do not automatically lower game-server ping.
• noatime: Fedora's common Btrfs setup already uses relatime; expected benefit is negligible.
• Generic gaming sysctl bundles, arbitrary I/O scheduler changes, disabling SELinux/firewalld/journald or disabling zram: can reduce security, reliability or responsiveness without a reliable FPS gain."
}
