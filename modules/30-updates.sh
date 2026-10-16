# shellcheck shell=bash
# Stage 3 — bring Fedora, the kernel, Mesa and device firmware up to date.

stage_updates() {
  header "Stage 3 — System and firmware updates"
  explain "New Mesa (RADV), kernel (amdgpu) and linux-firmware releases are the single most effective 'tweak' for a new AMD GPU. Fedora ships them quickly through normal updates — no extra repositories or custom kernels are needed."

  if propose safe "Install all pending Fedora updates" \
      "Runs 'dnf upgrade --refresh'. You will see the full transaction and confirm it in dnf." \
      "Nothing. A reboot may be needed for a new kernel or Mesa to take effect." \
      "Individual updates can be reverted with 'sudo dnf history undo <id>' (rarely advisable; prefer booting the previous kernel from the boot menu)."; then
    sudo_run dnf upgrade --refresh
  fi

  if command -v fwupdmgr >/dev/null 2>&1; then
    if propose safe "Check device firmware updates (LVFS / fwupd)" \
        "Refreshes LVFS metadata and lists firmware updates for devices that support it (SSDs, some peripherals, sometimes UEFI)." \
        "Nothing; checking is read-only. You are asked again before anything is flashed." \
        "Firmware updates generally cannot be rolled back; fwupd shows whether a downgrade is possible."; then
      run fwupdmgr refresh --force
      if fwupdmgr get-updates 2>/dev/null; then
        confirm "  Install the firmware updates listed above?" n && run fwupdmgr update
      else
        ok "No firmware updates available via LVFS."
      fi
    fi
  fi

  local newest running
  running=$(uname -r)
  newest=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n 1)
  if [[ -n $newest && $newest != "$running" ]]; then
    warn "Running kernel $running, newest installed $newest — reboot to use it."
  fi

  note "Motherboard BIOS" \
    "LVFS rarely carries desktop motherboard BIOS updates. Check your board vendor's site for the latest BIOS (new AGESA improves memory compatibility and fixes CPU bugs). In the BIOS: enable EXPO for your RAM, 'Above 4G Decoding' + 'Re-Size BAR' (Smart Access Memory), keep Secure Boot and fTPM enabled, and enable IOMMU. These are firmware settings — no Linux tweak replaces them."
}
