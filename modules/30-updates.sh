
# shellcheck shell=bash
# Stage 3 — official Fedora updates, DNF optimization and device firmware.
# No custom kernels, third-party repositories or automatic BIOS flashing.

stage_updates() {
  header "Stage 3 — System and firmware updates"

  explain "Updates Fedora packages, kernel, Mesa/RADV and device firmware through supported system tools. Review every proposed transaction before confirming it."

  local update_rc=0
  local mpd='' mpd_file=''
  local running='' newest=''
  local fwupd_output='' fwupd_tmp=''
  local fwupd_refresh_ok=0
  local dry_run=${FT_DRY_RUN:-0}

  # 1. Official Fedora system updates.
  if propose safe "Install pending Fedora updates" \
      "Runs 'dnf upgrade --refresh' to refresh repository metadata and update installed packages. Review the transaction before accepting it." \
      "Packages and dependencies may change. A reboot may be needed for kernel, firmware or system library updates." \
      "Review 'sudo dnf history'. Where supported, boot the previous kernel from the boot menu. DNF history undo is not a universal rollback."; then

    if sudo_run dnf upgrade --refresh; then
      ok "Fedora update command completed."
      journal_add "dnf upgrade --refresh" \
        "Review DNF history and package-specific recovery options"
    else
      update_rc=$?
      warn "Fedora update command failed (exit code $update_rc). Check DNF output before continuing."
    fi
  fi

  # 2. Optional DNF parallel downloads.
  # Read the last configured value without concatenating unrelated digits.
  if [[ -r /etc/dnf/dnf.conf ]]; then
    mpd_file=/etc/dnf/dnf.conf
  fi

  if [[ -n $mpd_file ]]; then
    mpd=$(awk -F= '
      /^[[:space:]]*max_parallel_downloads[[:space:]]*=/ {
        v=$2
        gsub(/[[:space:]#;].*$/, "", v)
        if (v ~ /^[0-9]+$/) value=v
      }
      END { if (value != "") print value }
    ' "$mpd_file")
  fi

  if [[ -z $mpd ]]; then
    mpd=$(awk -F= '
      /^[[:space:]]*max_parallel_downloads[[:space:]]*=/ {
        v=$2
        gsub(/[[:space:]#;].*$/, "", v)
        if (v ~ /^[0-9]+$/) value=v
      }
      END { if (value != "") print value }
    ' /etc/dnf/libdnf5.conf.d/*.conf 2>/dev/null)
  fi

  if [[ -z $mpd || ! $mpd =~ ^[0-9]+$ ]] || (( mpd < 10 )); then
    if propose optional "Optimize DNF download concurrency" \
        "Sets max_parallel_downloads=10 to allow up to ten simultaneous package downloads. This can help on fast connections; actual speed depends on mirrors and bandwidth." \
        "No package changes. More simultaneous network connections may be used." \
        "Undo with 'sudo dnf config-manager unsetopt max_parallel_downloads' if supported by your installed DNF version."; then

      if sudo_run dnf config-manager setopt max_parallel_downloads=10; then
        journal_add "dnf max_parallel_downloads=10" \
          "sudo dnf config-manager unsetopt max_parallel_downloads"
        ok "Requested DNF download setting."
      else
        warn "Could not configure DNF download concurrency. Check whether the config-manager plugin is installed."
      fi
    fi
  else
    info "DNF parallel downloads already configured to $mpd."
  fi

  # 3. Optional LVFS device firmware updates.
  if command -v fwupdmgr >/dev/null 2>&1; then
    if propose safe "Check device firmware updates (fwupd/LVFS)" \
        "Refreshes firmware metadata and checks for updates supported by your hardware. Firmware installation is a separate operation requiring confirmation." \
        "Metadata is refreshed. Installing firmware can reboot devices or the computer and may be difficult or impossible to reverse." \
        "Check the device vendor's recovery and downgrade instructions before installing firmware."; then

      if (( dry_run == 1 )); then
        info "Dry run: skipping actual LVFS metadata refresh and firmware checks."
      else
        if run fwupdmgr refresh --force; then
          fwupd_refresh_ok=1
        else
          warn "Firmware metadata refresh failed. Skipping the update check."
        fi

        if (( fwupd_refresh_ok == 1 )); then
          fwupd_tmp=$(mktemp "${TMPDIR:-/tmp}/fedora-tweaks-fwupd.XXXXXX") ||
            warn "Could not create a temporary file for firmware diagnostics."

          if [[ -n $fwupd_tmp ]]; then
            if fwupdmgr get-updates >"$fwupd_tmp" 2>&1; then
              fwupd_output=$(cat "$fwupd_tmp")
              printf '%s\n' "$fwupd_output"

              if grep -qiE 'no updates|no updatable devices|nothing to do' <<<"$fwupd_output"; then
                ok "No firmware updates reported by fwupd."
              elif grep -qiE 'Devices with no available firmware updates|Devices with the latest available firmware' <<<"$fwupd_output" &&
                   ! grep -qiE 'Upgrade available|Update available|New version|will be upgraded' <<<"$fwupd_output"; then
                ok "No firmware upgrades appear to be available."
              else
                if confirm "Install the firmware updates shown above?" n; then
                  if run fwupdmgr update; then
                    ok "Firmware update command completed. Follow any on-screen instructions."
                    journal_add "fwupdmgr update" \
                      "Firmware rollback depends on device and vendor support"
                  else
                    warn "Firmware update command failed. Follow the device-specific recovery instructions if necessary."
                  fi
                else
                  info "Firmware installation skipped."
                fi
              fi
            else
              warn "Could not retrieve firmware updates. This does not prove that no updates exist."
              cat "$fwupd_tmp"
            fi

            rm -f -- "$fwupd_tmp"
          fi
        fi
      fi
    fi
  else
    info "fwupd is not installed; skipping LVFS firmware checks."
  fi

  # 4. Installed versus running kernel.
  running=$(uname -r)

  newest=$(rpm -q kernel-core \
    --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null |
    sort -V | tail -n 1)

  if [[ -n $newest ]]; then
    if [[ $newest != "$running" ]]; then
      warn "Running kernel: $running. Newest installed kernel: $newest."
      explain "Reboot when convenient to load the installed kernel. Keep the previous working kernel available until the new one is tested."
    else
      ok "Running kernel matches the newest installed kernel-core package."
    fi
  else
    warn "Could not determine the newest installed kernel-core package."
  fi

  # 5. Reboot status.
  if command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      info "No reboot requirement reported by needs-restarting."
    else
      warn "A reboot may be required. Review the output of 'sudo dnf needs-restarting -r' or check your installed plugin's supported syntax."
    fi
  else
    info "needs-restarting is unavailable; reboot status was not verified."
  fi

  # 6. Motherboard firmware and BIOS settings.
  note "Motherboard BIOS and UEFI" \
    "Check your motherboard vendor's official support page for BIOS updates and read the release notes before installing. EXPO/XMP can improve memory performance but may cause instability on some systems. Above 4G Decoding and Re-Size BAR can benefit supported GPUs. Secure Boot, TPM and IOMMU should be configured according to your security, compatibility and virtualization needs; none should be changed blindly."

  if (( update_rc != 0 )); then
    warn "Stage 3 finished with an update error. Review the DNF transaction and logs."
    return "$update_rc"
  fi

  ok "Stage 3 completed."
  return 0
}
