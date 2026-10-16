# shellcheck shell=bash
# Stage 8 — performance tuning. Only changes with a plausible, measurable effect are offered.
# Everything else is explained and deliberately NOT applied.

tune_power_profile() {
  command -v powerprofilesctl >/dev/null 2>&1 || { info "powerprofilesctl not found — skipping power profile."; return 0; }
  local cur
  cur=$(powerprofilesctl get 2>/dev/null)
  if [[ $cur == performance ]]; then ok "Power profile is already 'performance'."; return 0; fi
  [[ -z $cur ]] && { warn "Could not read the current power profile."; return 0; }
  if propose optional "Use the 'performance' power profile (currently '$cur')" \
      "Fedora manages power profiles with tuned-ppd. 'performance' tells amd-pstate to favour high clocks (EPP=performance) and keeps the GPU/CPU from clocking down as eagerly. Alternatively stay on 'balanced' and let GameMode raise it only while a game runs." \
      "Higher idle power and temperatures (a few watts to tens of watts). Gains are usually small on a desktop; check 1% lows with MangoHud." \
      "./FedoraTweaks rollback — or: powerprofilesctl set $cur"; then
    run powerprofilesctl set performance && journal_add "Power profile performance (was $cur)" "powerprofilesctl set $cur"
  fi
}

tune_zram() {
  local swp pc
  swp=$(sysctl -n vm.swappiness 2>/dev/null); pc=$(sysctl -n vm.page-cluster 2>/dev/null)
  if [[ ! -e /dev/zram0 ]]; then info "No zram device — skipping swap tuning."; return 0; fi
  [[ -f /etc/sysctl.d/90-fedoratweaks-zram.conf ]] && { ok "zram sysctl tuning already applied."; return 0; }
  if propose optional "Tune the kernel for zram swap (currently swappiness=$swp, page-cluster=$pc)" \
      "Fedora swaps to compressed RAM (zram) by default — keep that. Because zram is fast, the kernel can be told to use it earlier (vm.swappiness=180) and to stop reading ahead 8 pages at a time (vm.page-cluster=0). This mainly helps when RAM is nearly full (game + browser + Discord); with 32 GB+ it rarely matters." \
      "Nothing functional. If you see more stutter under memory pressure, roll back." \
      "./FedoraTweaks rollback — values return to defaults after a reboot"; then
    root_write /etc/sysctl.d/90-fedoratweaks-zram.conf "# FedoraTweaks: zram-friendly reclaim. Remove this file to revert (reboot).
vm.swappiness = 180
vm.page-cluster = 0" "zram sysctl tuning" && sudo_run sysctl --system >/dev/null
  fi
}

tune_ntsync() {
  if ! modinfo ntsync >/dev/null 2>&1; then
    info "This kernel has no ntsync module — skipping."
    return 0
  fi
  if [[ -e /dev/ntsync ]] && [[ -f /etc/modules-load.d/ntsync.conf ]]; then
    ok "ntsync is loaded at boot."
    return 0
  fi
  if propose optional "Load the ntsync kernel module at boot" \
      "ntsync implements Windows NT synchronization primitives in the kernel. Recent Proton/Wine versions use /dev/ntsync when it exists instead of esync/fsync. It can improve frame pacing in some CPU-heavy games; many games show no difference." \
      "Nothing expected. If a Proton version misbehaves, roll this back and reboot." \
      "./FedoraTweaks rollback — or delete /etc/modules-load.d/ntsync.conf and reboot"; then
    root_write /etc/modules-load.d/ntsync.conf "ntsync" "Load ntsync at boot" && sudo_run modprobe ntsync
    if [[ $FT_DRY_RUN != 1 ]]; then
      if [[ -r /dev/ntsync && -w /dev/ntsync ]]; then ok "/dev/ntsync is usable by your user."
      else warn "/dev/ntsync exists but is not read/writable by your user ($(stat -c '%A %U:%G' /dev/ntsync 2>/dev/null)). Proton will fall back to fsync."; fi
    fi
  fi
}

tune_shader_cache() {
  local f="$HOME/.config/environment.d/90-fedoratweaks-mesa.conf"
  [[ -f $f ]] && { ok "Mesa shader cache size already configured."; return 0; }
  if propose optional "Larger Mesa shader cache for non-Steam games (10 GB)" \
      "Mesa caches compiled shaders so they do not recompile (stutter) next time. The default cap is about 1 GB, which large games launched outside Steam (Heroic, Lutris, Epic launcher) can exceed, causing re-compilation stutter. Steam games use Steam's own per-game shader cache and are not affected." \
      "Up to 10 GB of disk in ~/.cache/mesa_shader_cache* (only used if games need it)." \
      "./FedoraTweaks rollback — or delete $f and log out/in"; then
    user_write "$f" "# FedoraTweaks: allow Mesa's shader cache to grow (applies after re-login)
MESA_SHADER_CACHE_MAX_SIZE=10G" "Mesa shader cache 10G"
  fi
}

report_kernel_defaults() {
  local mmc
  mmc=$(sysctl -n vm.max_map_count 2>/dev/null)
  if [[ -n $mmc ]] && (( mmc >= 1048576 )); then
    ok "vm.max_map_count=$mmc (Fedora's gaming-friendly default; nothing to change)."
  else
    warn "vm.max_map_count=$mmc is below 1048576; some games (e.g. via Proton) need more. Fedora normally sets this — check /usr/lib/sysctl.d/."
  fi
  ok "CPU frequency driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo unknown), amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo n/a). Nothing to change — this is the recommended driver."
  systemctl is-active --quiet systemd-oomd && ok "systemd-oomd is active (keeps the desktop responsive under memory pressure)."
}

stage_tuning() {
  header "Stage 8 — Performance tuning"
  explain "These are optional and measurable. Apply one, reboot if needed, measure with MangoHud ('./FedoraTweaks bench'), and keep it only if it helps on your hardware."
  report_kernel_defaults
  tune_power_profile
  tune_zram
  tune_ntsync
  tune_shader_cache

  local scx_repo
  scx_repo=$(dnf repoquery --available --qf '%{repoid}\n' scx-scheds 2>/dev/null | head -n 1)
  note "sched-ext schedulers (scx_lavd, scx_bpfland …)" \
    "$( if [[ $scx_repo == fedora || $scx_repo == updates ]]; then
          echo "scx-scheds is available from Fedora's '$scx_repo' repository."
        else
          echo "scx-scheds is not in Fedora's enabled repositories on this system (third-party COPRs exist; not used here)."
        fi ) Test without installing a service: run e.g. 'sudo scx_lavd' in a terminal, play, and press Ctrl+C to return to the default scheduler instantly. Keep one only if MangoHud logs show better 1% lows across several runs. Interaction with EAC Linux v2 is unknown."

  note "Not applied — and why" \
    "• mitigations=off: disables CPU security mitigations; modern Zen CPUs gain little and you lose protection. Do not use.
• Disabling split-lock detection (kernel.split_lock_mitigate=0): only helps specific games that trigger split locks (you would see 'split lock detection' in 'journalctl -k'). Apply manually only for such a game.
• amdgpu.ppfeaturemask / forcing power_dpm_force_performance_level=high: unlocks overclocking/fan control or pins clocks; raises heat and power, can cause instability, and recent kernels may flag the system as tainted. Not a general speed-up.
• Custom kernels (CachyOS, Zen, XanMod): not signed with Fedora's key, so they break Secure Boot and EAC Linux v2. Fedora's kernel already has a current scheduler (EEVDF), amd-pstate and the latest amdgpu.
• iommu=pt: conflicts with EAC Linux v2 and brings no gaming benefit.
• 'Gaming' sysctl bundles, I/O scheduler swaps, disabling journald/SELinux/firewalld, disabling zram: placebo or harmful."
}
