# shellcheck shell=bash
# Stage 2 — baseline measurement, before/after comparison and MangoHud log analysis.

FT_CPU_SAMPLE=${FT_CPU_SAMPLE:-30}

_secs() { awk -v us="${1:-0}" 'BEGIN { printf "%.2f", us / 1000000 }'; }
_div()  { awk -v v="${1:-0}" -v d="$2" 'BEGIN { printf "%.1f", v / d }'; }

# Pick the amdgpu hwmon with the most VRAM (the discrete card, not the Ryzen iGPU).
_dgpu_hwmon() {
  local h best='' best_vram=-1 vram
  for h in /sys/class/hwmon/hwmon*; do
    [[ $(cat "$h/name" 2>/dev/null) == amdgpu ]] || continue
    vram=$(cat "$h/device/mem_info_vram_total" 2>/dev/null || echo 0)
    (( vram > best_vram )) && { best=$h; best_vram=$vram; }
  done
  [[ -n $best ]] && printf '%s' "$best"
}

_hwmon_named() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [[ $(cat "$h/name" 2>/dev/null) == "$1" ]] && { printf '%s' "$h"; return 0; }
  done
  return 1
}

measure_metrics() {
  local mt ma st sf
  read -r mt ma st sf < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{s=$2} /^SwapFree:/{f=$2} END{print t, a, s, f}' /proc/meminfo)
  echo "mem_total_mib=$(( mt / 1024 ))"
  echo "mem_used_mib=$(( (mt - ma) / 1024 ))"
  echo "swap_used_mib=$(( (st - sf) / 1024 ))"
  echo "procs_total=$(ps -e --no-headers | wc -l)"
  echo "procs_userspace=$(ps -e --no-headers -o pid=,ppid= | awk '$1 != 2 && $2 != 2' | wc -l)"
  echo "services_running=$(systemctl list-units --type=service --state=running --no-legend | wc -l)"
  echo "user_services_running=$(systemctl --user list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)"
  echo "services_enabled=$(systemctl list-unit-files --state=enabled --no-legend | wc -l)"
  echo "packages=$(rpm -qa | wc -l)"
  echo "disk_root_used_mib=$(df -BM --output=used / | tail -n 1 | tr -dc 0-9)"

  local fw ld fin gr
  fw=$(systemctl show -P FirmwareTimestampMonotonic 2>/dev/null)
  ld=$(systemctl show -P LoaderTimestampMonotonic 2>/dev/null)
  fin=$(systemctl show -P FinishTimestampMonotonic 2>/dev/null)
  gr=$(systemctl show -P ActiveEnterTimestampMonotonic graphical.target 2>/dev/null)
  echo "boot_firmware_s=$(_secs $(( ${fw:-0} - ${ld:-0} )))"
  echo "boot_loader_s=$(_secs "${ld:-0}")"
  echo "boot_graphical_s=$(_secs "${gr:-0}")"
  echo "boot_finished_s=$(_secs "${fin:-0}")"

  local h
  if h=$(_hwmon_named k10temp); then
    echo "cpu_temp_c=$(_div "$(cat "$h/temp1_input" 2>/dev/null)" 1000)"
  fi
  echo "cpu_mhz_avg=$(awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "%.0f", s / n }' /proc/cpuinfo)"
  if h=$(_dgpu_hwmon); then
    echo "gpu_edge_c=$(_div "$(cat "$h/temp1_input" 2>/dev/null)" 1000)"
    [[ -r $h/temp2_input ]] && echo "gpu_junction_c=$(_div "$(cat "$h/temp2_input")" 1000)"
    if [[ -r $h/power1_average ]]; then echo "gpu_power_w=$(_div "$(cat "$h/power1_average")" 1000000)"
    elif [[ -r $h/power1_input ]]; then echo "gpu_power_w=$(_div "$(cat "$h/power1_input")" 1000000)"; fi
    [[ -r $h/freq1_input ]] && echo "gpu_sclk_mhz=$(_div "$(cat "$h/freq1_input")" 1000000)"
  fi

  local -a a b
  read -r -a a < <(awk '/^cpu / { print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat)
  sleep "$FT_CPU_SAMPLE"
  read -r -a b < <(awk '/^cpu / { print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat)
  echo "cpu_busy_pct=$(awk -v t=$(( b[0] - a[0] )) -v i=$(( b[1] - a[1] )) 'BEGIN { if (t > 0) printf "%.2f", 100 * (1 - i / t); else print 0 }')"
}

stage_baseline() {
  header "Stage 2 — Baseline measurement (read-only)"
  explain "Records idle RAM, idle CPU, process/service counts, boot time, temperatures and clocks so every later change can be compared against real numbers. For reproducible results: reboot, log in, open only this terminal, and wait about two minutes before measuring. Run it again after each stage (and after a reboot) to compare."
  local up label dir
  up=$(awk '{ print int($1) }' /proc/uptime)
  if (( up > 1800 )); then
    warn "Uptime is $(( up / 60 )) minutes; caches and leftover apps inflate idle numbers."
    confirm "Measure now anyway? (Recommended: reboot first, then './FedoraTweaks baseline')" n || return 0
  elif (( up < 120 )); then
    info "Letting the session settle for $(( 120 - up )) s ..."
    sleep $(( 120 - up ))
  fi
  read -r -p "Label for this measurement (e.g. 'stock', 'after-services'): " label </dev/tty
  label=${label//[^A-Za-z0-9._-]/_}
  dir="$FT_BASELINE_DIR/$(date +%Y%m%d-%H%M%S)${label:+-$label}"
  mkdir -p "$dir" || return 1
  info "Measuring (idle CPU is sampled for ${FT_CPU_SAMPLE}s — please don't touch the machine) ..."
  {
    echo "label=${label:-unnamed}"
    echo "date=$(date '+%F %T')"
    echo "kernel=$(uname -r)"
    echo "uptime_s=$up"
    measure_metrics
  } >"$dir/metrics.env"
  rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u >"$dir/packages.txt"
  systemctl list-unit-files --state=enabled --no-legend | awk '{ print $1 }' | sort >"$dir/enabled-units.txt"
  systemctl list-units --type=service --state=running --no-legend | awk '{ print $1 }' | sort >"$dir/running-services.txt"
  ps -eo rss=,comm= --sort=-rss | head -n 40 >"$dir/top-processes.txt"
  sed 's/=/\t/' "$dir/metrics.env" | column -t -s $'\t' | sed 's/^/    /'
  ok "Saved to $dir"
}

_baseline_get() { sed -n "s/^$2=//p" "$1/metrics.env" | head -n 1; }

stage_compare() {
  header "Compare measurements"
  local -a dirs
  mapfile -t dirs < <(find "$FT_BASELINE_DIR" -mindepth 2 -maxdepth 2 -name metrics.env -printf '%h\n' 2>/dev/null | sort)
  if (( ${#dirs[@]} < 2 )); then
    warn "Need at least two measurements. Run './FedoraTweaks baseline' before and after a change."
    return 0
  fi
  local i
  for i in "${!dirs[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "$(basename "${dirs[$i]}")"; done
  local a b
  read -r -p "Compare which? 'before after' numbers [1 ${#dirs[@]}]: " a b </dev/tty
  a=${a:-1}; b=${b:-${#dirs[@]}}
  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] && (( a >= 1 && b >= 1 && a <= ${#dirs[@]} && b <= ${#dirs[@]} )) \
    || { err "Invalid selection"; return 1; }
  local A=${dirs[$((a - 1))]} B=${dirs[$((b - 1))]}

  printf '\n  %-34s %12s %12s %10s\n' "Metric" "before" "after" "delta"
  local key label va vb
  while IFS='|' read -r key label; do
    va=$(_baseline_get "$A" "$key"); vb=$(_baseline_get "$B" "$key")
    [[ -z $va && -z $vb ]] && continue
    printf '  %-34s %12s %12s %10s\n' "$label" "${va:--}" "${vb:--}" \
      "$(awk -v x="$va" -v y="$vb" 'BEGIN { if (x ~ /^-?[0-9.]+$/ && y ~ /^-?[0-9.]+$/) printf "%+.1f", y - x; else print "" }')"
  done <<'EOF'
mem_used_mib|Idle RAM used (MiB)
swap_used_mib|Swap used (MiB)
cpu_busy_pct|Idle CPU busy (%)
procs_userspace|Userspace processes
procs_total|All tasks incl. kernel threads
services_running|System services running
user_services_running|User services running
services_enabled|Enabled units
packages|Installed RPMs
disk_root_used_mib|Root FS used (MiB)
boot_firmware_s|Boot: firmware (s)
boot_loader_s|Boot: loader (s)
boot_graphical_s|Boot: kernel→graphical.target (s)
boot_finished_s|Boot: kernel→boot finished (s)
cpu_temp_c|CPU Tctl idle (°C)
cpu_mhz_avg|CPU avg clock idle (MHz)
gpu_edge_c|GPU edge idle (°C)
gpu_junction_c|GPU junction idle (°C)
gpu_power_w|GPU power idle (W)
gpu_sclk_mhz|GPU core clock idle (MHz)
EOF

  local removed added
  removed=$(comm -23 "$A/packages.txt" "$B/packages.txt" | wc -l)
  added=$(comm -13 "$A/packages.txt" "$B/packages.txt" | wc -l)
  printf '\n  Packages: %d removed, %d added.  Running services removed:' "$removed" "$added"
  comm -23 "$A/running-services.txt" "$B/running-services.txt" | paste -sd ' ' | sed 's/^/ /'
  echo
  explain "Read these numbers honestly: removing desktop apps saves disk space and a little idle memory, but it rarely changes in-game FPS. Use 'bench' with MangoHud logs to judge gaming performance. Differences under ~2–3% in idle CPU/RAM are within run-to-run noise."
}

# bench FILE.csv... — summarise MangoHud frametime logs (works on any Linux, no root needed)
bench_mangohud() {
  if (( $# == 0 )); then
    die "Usage: ./FedoraTweaks bench <mangohud-log.csv> [more.csv ...]"
  fi
  local f sorted
  for f in "$@"; do
    [[ -r $f ]] || { err "Cannot read $f"; continue; }
    sorted=$(awk -F, '
      !col { for (i = 1; i <= NF; i++) if ($i == "frametime") col = i; next }
      { v = $col + 0; if (v > 0) print v }' "$f" | sort -gr)
    if [[ -z $sorted ]]; then
      err "$f: no 'frametime' column found — is this a MangoHud log (not the _summary file)?"
      continue
    fi
    printf '\n%s%s%s\n' "$C_BOLD" "$(basename "$f")" "$C_RESET"
    awk '
      { a[NR] = $1; s += $1; ss += $1 * $1 }
      END {
        n = NR; mean = s / n; var = ss / n - mean * mean; sd = var > 0 ? sqrt(var) : 0
        k1 = int(n * 0.01);  if (k1 < 1) k1 = 1
        k01 = int(n * 0.001); if (k01 < 1) k01 = 1
        for (i = 1; i <= k1; i++) w1 += a[i]
        for (i = 1; i <= k01; i++) w01 += a[i]
        printf "  frames            %d\n", n
        printf "  duration          %.1f s\n", s / 1000
        printf "  average FPS       %.1f\n", 1000 * n / s
        printf "  1%% low FPS        %.1f   (mean of slowest 1%% of frames)\n", 1000 / (w1 / k1)
        printf "  0.1%% low FPS      %.1f\n", 1000 / (w01 / k01)
        printf "  frametime mean    %.2f ms\n", mean
        printf "  frametime stdev   %.2f ms   (lower = smoother)\n", sd
        printf "  99th pct frame    %.2f ms\n", a[k1]
        printf "  worst frame       %.2f ms\n", a[1]
      }' <<<"$sorted"
  done
  echo
  explain "Compare runs of the same scene, same settings, same duration, at least 3 runs each. Treat differences smaller than the run-to-run spread as noise."
}
