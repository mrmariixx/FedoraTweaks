# shellcheck shell=bash
# Stage 9 — Fortnite / EAC Linux v2 readiness.
# Source: Epic Online Services, "Awesome Gaming on Linux Without Cheating" (2026-10-14)
#   https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2
# Epic says the requirements will be iterated on. Re-check that page before relying on this.

FT_EAC_CHECKED="2026-10-16"

_ac_row() { # STATUS NAME DETAIL
  local col
  case $1 in PASS) col=$C_GREEN ;; FAIL) col=$C_RED ;; *) col=$C_YELLOW ;; esac
  printf '  %s%-5s%s %-30s %s\n' "$col$C_BOLD" "$1" "$C_RESET" "$2" "$3"
}

stage_anticheat() {
  header "Stage 9 — Fortnite / EAC Linux v2 readiness"
  explain "Confirmed (Epic, 14 Oct 2026): Fortnite is coming to Linux and will be the first game to pilot 'Easy Anti-Cheat Linux v2'. It does NOT use a kernel module; it relies on signed kernels, Secure Boot, TPM 2.0 measured boot, IOMMU, kernel lockdown, kexec disabled and the BPF LSM, plus a systemd service that runs only while a protected game runs. Fedora's Secure Boot CA is on Epic's 'well-known keys' list. NOT yet known: a release date, the final requirement list (Epic says it will iterate), and whether Fortnite runs via Proton or natively. Checked on $FT_EAC_CHECKED."
  echo

  local cmdline sb tpm lockdown lsm kexec taint vendor
  cmdline=$(cat /proc/cmdline)

  # 1. Signed kernel & modules
  vendor=$(rpm -qf "/lib/modules/$(uname -r)/vmlinuz" --qf '%{NAME} %{VENDOR}\n' 2>/dev/null | head -n 1)
  if [[ $vendor == kernel-core*"Fedora Project"* ]]; then _ac_row PASS "Signed distro kernel" "$vendor"
  else _ac_row FAIL "Signed distro kernel" "running kernel is not Fedora's (${vendor:-unknown}) — custom kernels are not accepted"; fi

  taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)
  local bad_mods='' m signer
  while read -r m _; do
    signer=$(modinfo -F signer "$m" 2>/dev/null)
    [[ -z $signer || $signer == *Fedora* ]] || bad_mods+=" $m($signer)"
  done < <(lsmod | tail -n +2)
  if (( (taint & 12289) == 0 )) && [[ -z $bad_mods ]]; then
    _ac_row PASS "Kernel modules" "no out-of-tree, unsigned or proprietary modules (taint=$taint)"
  else
    _ac_row FAIL "Kernel modules" "taint=$taint;${bad_mods:- out-of-tree/unsigned module loaded} (akmod/DKMS modules signed with a local key are not well-known)"
  fi

  # 2. TPM 2.0
  tpm=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
  if [[ $tpm == 2 ]]; then _ac_row PASS "TPM 2.0" "present"
  else _ac_row FAIL "TPM 2.0" "not found — enable fTPM (AMD PSP) in the BIOS"; fi

  # 3. Secure Boot + enrolled MOKs
  sb=$(mokutil --sb-state 2>/dev/null)
  if grep -q 'SecureBoot enabled' <<<"$sb"; then _ac_row PASS "Secure Boot" "enabled"
  else _ac_row FAIL "Secure Boot" "${sb:-unknown} — enable it in the BIOS (standard/default keys)"; fi
  local moks
  moks=$(mokutil --list-enrolled 2>/dev/null | grep -E 'Subject:' | sed 's/.*CN *= *//' | paste -sd ';')
  if [[ -z $moks ]]; then _ac_row PASS "Machine Owner Keys" "none enrolled"
  else _ac_row WARN "Machine Owner Keys" "enrolled: $moks — Epic requires every enrolled MOK to be well-known"; fi

  # 4. Measured boot
  if [[ -e /sys/kernel/security/tpm0/binary_bios_measurements ]]; then
    local pcr9
    pcr9=$(cat /sys/class/tpm/tpm0/pcr-sha256/9 2>/dev/null)
    if [[ -n $pcr9 && $pcr9 =~ [1-9A-Fa-f] ]]; then _ac_row PASS "Measured boot" "TPM event log present, PCR 9 extended by the boot loader"
    else _ac_row WARN "Measured boot" "TPM event log present; could not confirm boot-loader measurements (PCR 9)"; fi
  else
    _ac_row FAIL "Measured boot" "no TPM event log"
  fi

  # 5. IOMMU, no passthrough
  local iommu_on=0 pt=0
  compgen -G '/sys/class/iommu/*' >/dev/null && iommu_on=1
  [[ $cmdline =~ (^|[[:space:]])(iommu=pt|iommu.passthrough=1|amd_iommu=off|iommu=off)([[:space:]]|$) ]] && pt=1
  if (( iommu_on && !pt )); then _ac_row PASS "IOMMU (no passthrough)" "active, DMA translation"
  elif (( pt )); then _ac_row FAIL "IOMMU (no passthrough)" "kernel command line disables or bypasses it"
  else _ac_row FAIL "IOMMU (no passthrough)" "not active — enable IOMMU in the BIOS (AMD CBS › NBIO)"; fi

  # 6. Lockdown integrity, explicitly on the command line
  lockdown=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
  if [[ $cmdline =~ (^|[[:space:]])lockdown=(integrity|confidentiality)([[:space:]]|$) ]]; then
    _ac_row PASS "Kernel lockdown (explicit)" "active mode: ${lockdown:-?}"
  else
    _ac_row FAIL "Kernel lockdown (explicit)" "active mode: ${lockdown:-none}; 'lockdown=integrity' is not on the command line"
  fi

  # 7. kexec disabled
  kexec=$(cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null)
  if [[ $kexec == 1 && $cmdline == *kexec_load_disabled=1* ]]; then _ac_row PASS "kexec disabled at boot" "kernel.kexec_load_disabled=1"
  else _ac_row FAIL "kexec disabled at boot" "kernel.kexec_load_disabled=${kexec:-?} (not set from the boot command line)"; fi

  # 8. BPF LSM
  lsm=$(cat /sys/kernel/security/lsm 2>/dev/null)
  if [[ ,$lsm, == *,bpf,* ]]; then _ac_row PASS "BPF LSM" "active ($lsm)"
  else _ac_row FAIL "BPF LSM" "not in the active LSM list ($lsm)"; fi

  echo
  anticheat_offer_cmdline "$cmdline" "$lsm"

  note "What you should NOT do" \
    "Do not disable Secure Boot or TPM for 'performance' — they cost nothing in games and are mandatory for EAC Linux v2. Avoid custom kernels and out-of-tree modules (an all-AMD system needs none). If you also want your own Secure Boot keys for other boot entries, Epic says to enroll them in the UEFI db, not as MOKs."
  note "Getting Fortnite" \
    "When Epic enables it, follow Epic's official instructions. Epic's launcher page lists a Linux AppImage with Fedora 43+ as a supported distro: https://launcher.epicgames.com/ . Re-run './FedoraTweaks anticheat' after Epic publishes final requirements."
}

# Offer the missing kernel command-line pieces through grubby (Fedora's supported tool).
anticheat_offer_cmdline() {
  local cmdline=$1 lsm=$2
  local -a add=() del=()
  local a
  [[ $cmdline =~ (^|[[:space:]])lockdown=(integrity|confidentiality)([[:space:]]|$) ]] || add+=("lockdown=integrity")
  [[ $cmdline == *kexec_load_disabled=1* ]] || add+=("sysctl.kernel.kexec_load_disabled=1")
  [[ -z $lsm || ,$lsm, == *,bpf,* ]] || add+=("lsm=${lsm},bpf")
  for a in iommu=pt iommu.passthrough=1 amd_iommu=off iommu=off; do
    [[ $cmdline =~ (^|[[:space:]])$a([[:space:]]|$) ]] && del+=("$a")
  done
  (( ${#add[@]} + ${#del[@]} )) || { ok "Kernel command line already matches the published requirements."; return 0; }
  command -v grubby >/dev/null 2>&1 || { warn "grubby not found; add these kernel arguments manually: ${add[*]} ${del:+(remove: ${del[*]})}"; return 0; }

  if propose optional "Prepare the kernel command line for EAC Linux v2" \
      "Uses 'grubby --update-kernel=ALL' (Fedora's documented method; new kernels inherit it).${add:+ Adds: ${add[*]}.}${del:+ Removes: ${del[*]}.} lockdown=integrity stops even root from modifying the running kernel; disabling kexec keeps the measured-boot log truthful. Fortnite's anti-cheat is not live yet — you can also wait and apply this later." \
      "Lockdown blocks: unsigned/locally-signed kernel modules (akmods, DKMS), hibernation, /dev/mem and CPU MSR writes (ryzenadj, some undervolt/monitoring tools), and kexec-based fast reboot. Normal desktop use, Steam/Proton, amdgpu monitoring via sysfs and MangoHud are unaffected." \
      "./FedoraTweaks rollback — or: sudo grubby --update-kernel=ALL --remove-args=\"${add[*]}\"${del:+ --args=\"${del[*]}\"}. If a kernel fails to boot, press 'e' in the GRUB menu to edit the line for that boot."; then
    local undo_parts=()
    if (( ${#add[@]} )); then
      sudo_run grubby --update-kernel=ALL --args="${add[*]}" || return 1
      undo_parts+=("sudo grubby --update-kernel=ALL --remove-args=$(printf %q "${add[*]}")")
    fi
    if (( ${#del[@]} )); then
      sudo_run grubby --update-kernel=ALL --remove-args="${del[*]}" || return 1
      undo_parts+=("sudo grubby --update-kernel=ALL --args=$(printf %q "${del[*]}")")
    fi
    local undo
    undo=$(printf '%s && ' "${undo_parts[@]}"); undo=${undo% && }
    journal_add "EAC v2 kernel args (+${add[*]} -${del[*]})" "$undo"
    warn "Reboot, then run './FedoraTweaks anticheat' again to verify."
  fi
}
