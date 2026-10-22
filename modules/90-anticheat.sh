
# shellcheck shell=bash
# Stage 9 — Fortnite / EAC Linux v2 readiness.
# Reference: https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2
# Requirements may change. This stage audits the current system and offers
# limited, reversible boot-configuration changes. It cannot certify compatibility.

FT_EAC_CHECKED="2026-10-22"

_ac_row() { # STATUS NAME DETAIL
  local status=${1:-WARN} name=${2:-Unknown} detail=${3:-}
  local color

  case $status in
    PASS) color=${C_GREEN:-} ;;
    FAIL) color=${C_RED:-} ;;
    *)    color=${C_YELLOW:-} ;;
  esac

  printf '  %s%-5s%s %-30s %s\n' \
    "${color}${C_BOLD:-}" "$status" "${C_RESET:-}" "$name" "$detail"
}

_ac_has_arg() {
  local cmdline=$1 wanted=$2 arg
  for arg in $cmdline; do
    [[ $arg == "$wanted" ]] && return 0
  done
  return 1
}

_ac_get_arg_value() {
  local cmdline=$1 prefix=$2 arg
  for arg in $cmdline; do
    if [[ $arg == "$prefix"* ]]; then
      printf '%s\n' "${arg#"$prefix"}"
      return 0
    fi
  done
  return 1
}

stage_anticheat() {
  header "Stage 9 — Fortnite / EAC Linux v2 readiness"

  explain "Epic announced EAC Linux v2 on 14 October 2026, with Fortnite planned as its initial pilot. Published requirements cover signed kernels and modules, Secure Boot and trusted keys, TPM 2.0, measured boot, IOMMU, kernel lockdown, disabled kexec and an active BPF LSM. The final requirements and release date may change. This is a diagnostic checklist, not an Epic compatibility certification. Checked: $FT_EAC_CHECKED."

  printf '\n'

  local cmdline sb tpm lockdown lsm kexec taint
  local kernel_image kernel_pkg kernel_vendor
  local mok_output mok_count
  local module_count unsigned_count external_signer_count
  local iommu_on=0 iommu_conflict=0
  local pcr_file pcr_value
  local m signer
  local -a module_warnings=()

  cmdline=$(cat /proc/cmdline 2>/dev/null) || cmdline=''

  # 1. Running kernel package identity.
  kernel_image="/boot/vmlinuz-$(uname -r)"
  kernel_pkg=''
  kernel_vendor=''

  if [[ -e $kernel_image ]]; then
    kernel_pkg=$(rpm -qf "$kernel_image" --qf '%{NAME}\n' 2>/dev/null | head -n 1)
    kernel_vendor=$(rpm -qf "$kernel_image" --qf '%{VENDOR}\n' 2>/dev/null | head -n 1)
  fi

  if [[ $kernel_pkg == kernel-core && $kernel_vendor == *Fedora* ]]; then
    _ac_row PASS "Kernel package" "$kernel_pkg; vendor: $kernel_vendor"
    _ac_row WARN "Kernel signature" "Package ownership does not prove the running kernel's signature is trusted by Epic."
  elif [[ -n $kernel_pkg ]]; then
    _ac_row WARN "Kernel package" "$kernel_pkg; vendor: ${kernel_vendor:-unknown}. Verify its signature and trusted signing key."
  else
    _ac_row WARN "Kernel package" "Could not identify the owner of $kernel_image. This alone does not establish whether the kernel is signed."
  fi

  # 2. Loaded modules and kernel taint.
  taint=$(cat /proc/sys/kernel/tainted 2>/dev/null) || taint=unknown
  module_count=0
  unsigned_count=0
  external_signer_count=0

  if command -v lsmod >/dev/null 2>&1 && command -v modinfo >/dev/null 2>&1; then
    while read -r m _; do
      [[ -n $m ]] || continue
      ((module_count += 1))

      signer=$(modinfo -F signer "$m" 2>/dev/null | head -n 1)

      if [[ -z $signer ]]; then
        ((unsigned_count += 1))
        module_warnings+=("$m")
      elif [[ $signer != *Fedora* ]]; then
        # Signer text is not a reliable way to identify Epic-approved keys.
        ((external_signer_count += 1))
      fi
    done < <(lsmod 2>/dev/null | tail -n +2)
  fi

  if [[ $taint =~ ^[0-9]+$ ]]; then
    if (( (taint & 12289) != 0 )); then
      _ac_row WARN "Kernel taint" "taint=$taint; one or more relevant taint flags are set. This is not proof of EAC incompatibility."
    else
      _ac_row PASS "Kernel taint" "taint=$taint; selected taint flags are clear."
    fi
  else
    _ac_row WARN "Kernel taint" "Could not read the kernel taint value."
  fi

  if (( unsigned_count > 0 )); then
    _ac_row WARN "Loaded module signatures" "$unsigned_count of $module_count modules have no signer reported by modinfo. Check: ${module_warnings[*]}"
  elif (( module_count > 0 )); then
    _ac_row WARN "Loaded module signatures" "$module_count modules inspected; signer names do not prove Epic trust."
  else
    _ac_row WARN "Loaded module signatures" "Could not inspect loaded modules."
  fi

  if (( external_signer_count > 0 )); then
    _ac_row WARN "Module signing keys" "$external_signer_count signer names do not contain 'Fedora'; this is not proof that those keys are untrusted."
  fi

  # 3. TPM 2.0.
  tpm=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null) || tpm=''

  if [[ $tpm == 2 ]]; then
    _ac_row PASS "TPM 2.0" "TPM version 2 reported by sysfs."
  else
    _ac_row FAIL "TPM 2.0" "TPM 2 was not confirmed through /sys/class/tpm/tpm0. Check firmware settings and TPM tools."
  fi

  # 4. Secure Boot.
  if command -v mokutil >/dev/null 2>&1; then
    sb=$(mokutil --sb-state 2>&1) || sb='Could not query Secure Boot state.'

    if grep -qi 'SecureBoot enabled' <<<"$sb"; then
      _ac_row PASS "Secure Boot" "enabled according to mokutil."
    elif grep -qi 'SecureBoot disabled' <<<"$sb"; then
      _ac_row FAIL "Secure Boot" "disabled. Check UEFI settings and trusted boot keys."
    else
      _ac_row WARN "Secure Boot" "$sb"
    fi
  else
    sb=''
    _ac_row WARN "Secure Boot" "mokutil is not installed; state could not be verified."
  fi

  # 5. Enrolled MOKs.
  if command -v mokutil >/dev/null 2>&1; then
    mok_output=$(mokutil --list-enrolled 2>/dev/null) || mok_output=''
    mok_count=$(grep -c 'Subject:' <<<"$mok_output" 2>/dev/null || true)

    if [[ ! $mok_count =~ ^[0-9]+$ ]]; then
      mok_count=0
    fi

    if (( mok_count == 0 )); then
      _ac_row WARN "Enrolled MOKs" "No MOK subjects were reported, or the query failed. This does not verify the firmware db/dbx key set."
    else
      _ac_row WARN "Enrolled MOKs" "$mok_count subject entries found. Verify every enrolled MOK against Epic's approved-key policy."
    fi
  else
    _ac_row WARN "Enrolled MOKs" "mokutil unavailable; enrolled keys could not be inspected."
  fi

  # 6. Measured boot.
  if [[ -r /sys/kernel/security/tpm0/binary_bios_measurements ]]; then
    _ac_row PASS "TPM event log" "binary BIOS measurement log is present."
    _ac_row WARN "Measured boot verification" "A readable event log alone does not verify all required PCR measurements or their trust chain."
  else
    _ac_row WARN "TPM event log" "Expected event-log path is absent or unreadable. Check firmware, securityfs and the platform's event-log location."
  fi

  # 7. IOMMU and passthrough.
  if compgen -G '/sys/class/iommu/*' >/dev/null; then
    iommu_on=1
  fi

  if [[ $cmdline =~ (^|[[:space:]])(iommu=pt|iommu.passthrough=1|amd_iommu=off|iommu=off)([[:space:]]|$) ]]; then
    iommu_conflict=1
  fi

  if (( iommu_conflict )); then
    _ac_row FAIL "IOMMU arguments" "A potentially conflicting IOMMU argument is present. Review firmware and kernel configuration."
  elif (( iommu_on )); then
    _ac_row PASS "IOMMU sysfs" "IOMMU devices are exposed; this does not prove every EAC requirement is satisfied."
  else
    _ac_row WARN "IOMMU sysfs" "No IOMMU device was found at /sys/class/iommu. Check BIOS/UEFI and kernel support."
  fi

  # 8. Kernel lockdown.
  lockdown=''
  if [[ -r /sys/kernel/security/lockdown ]]; then
    lockdown=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
  fi

  if _ac_has_arg "$cmdline" "lockdown=integrity" ||
     _ac_has_arg "$cmdline" "lockdown=confidentiality"; then
    _ac_row PASS "Lockdown argument" "explicit lockdown argument is present; active mode: ${lockdown:-unknown}."
  elif [[ $lockdown == integrity || $lockdown == confidentiality ]]; then
    _ac_row WARN "Kernel lockdown" "active mode '$lockdown', but no explicit lockdown=integrity/confidentiality argument was found."
  else
    _ac_row FAIL "Kernel lockdown" "no active integrity/confidentiality mode was confirmed, and no explicit argument was found."
  fi

  # 9. kexec disabled.
  kexec=$(cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null) || kexec='unknown'

  if [[ $kexec == 1 ]] && _ac_has_arg "$cmdline" "sysctl.kernel.kexec_load_disabled=1"; then
    _ac_row PASS "kexec disabled" "sysctl value is 1 and the boot command line contains the requested setting."
  elif [[ $kexec == 1 ]]; then
    _ac_row WARN "kexec disabled" "sysctl value is 1, but the expected boot argument was not found."
  else
    _ac_row FAIL "kexec disabled" "kernel.kexec_load_disabled=${kexec}; verify the published requirement and supported configuration method."
  fi

  # 10. BPF LSM.
  lsm=$(cat /sys/kernel/security/lsm 2>/dev/null) || lsm=''

  if [[ ",$lsm," == *,bpf,* ]]; then
    _ac_row PASS "BPF LSM" "bpf appears in the active LSM list: $lsm"
  else
    _ac_row FAIL "BPF LSM" "bpf is absent from the reported active LSM list: ${lsm:-unknown}. Check kernel configuration and LSM ordering."
  fi

  printf '\n'

  anticheat_offer_cmdline "$cmdline"

  note "Interpretazione dei risultati" \
    "PASS indica solamente che il controllo locale descritto è stato superato. Non certifica che la chiave di firma sia approvata da Epic, che il measured boot sia valido secondo EAC o che Fortnite funzioni. FAIL e WARN indicano controlli da approfondire, non una previsione di ban."

  note "Modifiche da evitare" \
    "Non disabilitare Secure Boot, TPM, SELinux o altri controlli di sicurezza per ottenere più FPS. Non installare kernel o moduli di provenienza incerta. Prima di applicare nuovi requisiti di avvio, verifica la documentazione ufficiale aggiornata e conserva un metodo per avviare il sistema con una configurazione precedente."

  note "Come ottenere Fortnite" \
    "Epic ha annunciato il progetto Linux e il pilot EAC Linux v2, ma questo controllo non rende il gioco disponibile. Segui gli annunci ufficiali e ripeti il controllo quando saranno pubblicati i requisiti definitivi: https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2"
}

# Offer limited kernel command-line changes via grubby.
# Do not automatically rewrite the LSM list: doing so can accidentally omit
# SELinux or another active security module.
anticheat_offer_cmdline() {
  local cmdline=$1
  local arg
  local -a add=() del=()

  if ! _ac_has_arg "$cmdline" "lockdown=integrity" &&
     ! _ac_has_arg "$cmdline" "lockdown=confidentiality"; then
    add+=("lockdown=integrity")
  fi

  if ! _ac_has_arg "$cmdline" "sysctl.kernel.kexec_load_disabled=1"; then
    add+=("sysctl.kernel.kexec_load_disabled=1")
  fi

  for arg in iommu=pt iommu.passthrough=1 amd_iommu=off iommu=off; do
    if _ac_has_arg "$cmdline" "$arg"; then
      del+=("$arg")
    fi
  done

  if (( ${#add[@]} == 0 && ${#del[@]} == 0 )); then
    ok "No missing lockdown/kexec arguments or known conflicting IOMMU arguments were detected."
    return 0
  fi

  if ! command -v grubby >/dev/null 2>&1; then
    warn "grubby is unavailable. No boot configuration was changed."
    (( ${#add[@]} )) && info "Arguments to review: ${add[*]}"
    (( ${#del[@]} )) && info "Potentially conflicting arguments to review: ${del[*]}"
    return 0
  fi

  if ! propose optional "Review kernel arguments for EAC Linux v2" \
      "Proposes lockdown=integrity and disabling kexec through the kernel command line, and removes detected conflicting IOMMU arguments. Epic's requirements may change. Lockdown can block modules and low-level tools that are not signed with trusted keys. Review every proposed argument before accepting." \
      "Changes the boot arguments for all kernels selected by grubby. Lockdown may affect locally signed or unsigned modules and some low-level utilities. Keep a working recovery path and reboot only when prepared." \
      "./FedoraTweaks rollback — restore the exact previous kernel arguments from a saved configuration or recovery boot entry."; then
    return 0
  fi

  if [[ ${FT_DRY_RUN:-0} == 1 ]]; then
    info "Dry run: no kernel arguments will be changed."
    (( ${#add[@]} )) && info "Would add: ${add[*]}"
    (( ${#del[@]} )) && info "Would remove: ${del[*]}"
    return 0
  fi

  local old_args
  old_args=$(grubby --info=ALL 2>/dev/null) || {
    warn "Could not read grubby configuration; refusing to change boot arguments."
    return 1
  }

  if (( ${#add[@]} )); then
    if ! sudo_run grubby --update-kernel=ALL --args="${add[*]}"; then
      warn "Could not add the requested kernel arguments."
      return 1
    fi
  fi

  if (( ${#del[@]} )); then
    if ! sudo_run grubby --update-kernel=ALL --remove-args="${del[*]}"; then
      warn "Could not remove conflicting IOMMU arguments. Review the boot configuration before rebooting."
      return 1
    fi
  fi

  journal_add \
    "Updated kernel arguments for EAC readiness (+${add[*]} -${del[*]})" \
    "Restore the previous kernel arguments from the backup/recovery entry; do not assume removing the new arguments alone restores the original configuration."

  warn "Kernel arguments were changed for configured kernels. Reboot only when ready, keep a recovery path, then run './FedoraTweaks anticheat' again."
}
