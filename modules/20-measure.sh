
# shellcheck shell=bash
# Stage 2 — baseline measurement, before/after comparison and MangoHud analysis.
# Read-only system diagnostics; writes measurement files only.

FT_CPU_SAMPLE=${FT_CPU_SAMPLE:-30}

_secs() {
  awk -v us="${1:-0}" 'BEGIN { printf "%.2f", us / 1000000 }'
}

_div() {
  awk -v v="${1:-0}" -v d="${2:-1}" \
    'BEGIN { if (d != 0) printf "%.2f", v / d; else print "0.00" }'
}

# Select the AMD GPU hwmon exposing the largest non-zero VRAM allocation.
# On hybrid systems this normally avoids selecting the Ryzen iGPU.
_dgpu_hwmon() {
  local h best='' best_vram=0 vram

  for h in /sys/class/hwmon/hwmon*; do
    [[ -d $h ]] || continue
    [[ $(cat "$h/name" 2>/dev/null) == amdgpu ]] || continue

    vram=$(cat "$h/device/mem_info_vram_total" 2>/dev/null) || continue
    [[ $vram =~ ^[0-9]+$ ]] || continue

    if (( vram > best_vram )); then
      best=$h
      best_vram=$vram
    fi
  done

  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

_hwmon_named() {
  local h

  for h in /sys/class/hwmon/hwmon*; do
    [[ -d $h ]] || continue
    if [[ $(cat "$h/name" 2>/dev/null) == "$1" ]]; then
      printf '%s\n' "$h"
      return 0
    fi
  done

  return 1
}

# Emit a metric only if the input is a valid non-negative integer.
_metric_uint() {
  local key=$1 value=${2:-}
  [[ $value =~ ^[0-9]+$ ]] || return 0
  printf '%s=%s\n' "$key" "$value"
}

# Read a systemd timestamp in microseconds.
_boot_timestamp() {
  systemctl show -P "$1" 2>/dev/null
}

# Convert two monotonic timestamps into seconds, if both are valid.
_boot_delta() {
  local start=${1:-} finish=${2:-}

  [[ $start =~ ^[0-9]+$ && $finish =~ ^[0-9]+$ ]] || return 0
  (( finish >= start )) || return 0

  _secs "$(( finish - start ))"
}

measure_metrics() {
  local mt ma st sf
  local total used swap_total swap_free
  local fw ld kernel_us initrd userspace graphical finish
  local h value cpu_temp
  local -a cpu_before=() cpu_after=()
  local cpu_total_before cpu_idle_before
  local cpu_total_after cpu_idle_after
  local cpu_total_delta cpu_idle_delta
  local cpu_busy

  # Memory and swap, in KiB from /proc/meminfo.
  read -r mt ma st sf < <(
    awk '
      /^MemTotal:/     { t=$2 }
      /^MemAvailable:/ { a=$2 }
      /^SwapTotal:/    { s=$2 }
      /^SwapFree:/     { f=$2 }
      END { print t+0, a+0, s+0, f+0 }
    ' /proc/meminfo
  )

  if (( mt > 0 && ma <= mt )); then
    echo "mem_total_mib=$(( mt / 1024 ))"
    echo "mem_used_mib=$(( (mt - ma) / 1024 ))"
    echo "mem_available_mib=$(( ma / 1024 ))"
  fi

  if (( st >= sf )); then
    echo "swap_used_mib=$(( (st - sf) / 1024 ))"
    echo "swap_total_mib=$(( st / 1024 ))"
  fi

  echo "procs_total=$(ps -e --no-headers 2>/dev/null | wc -l)"
  echo "procs_userspace=$(ps -e --no-headers -o pid=,ppid= 2>/dev/null |
    awk '$1 != 2 && $2 != 2 { n++ } END { print n+0 }')"

  echo "services_running=$(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | wc -l)"
  echo "user_services_running=$(systemctl --user list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | wc -l)"
  echo "services_enabled=$(systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null | wc -l)"
  echo "packages=$(rpm -qa 2>/dev/null | wc -l)"

  # Root filesystem usage. Do not turn a parsing error into zero.
  value=$(df -BM --output=used / 2>/dev/null | awk 'NR==2 { gsub(/M/, "", $1); print $1 }')
  [[ $value =~ ^[0-9]+$ ]] && echo "disk_root_used_mib=$value"

  # systemd boot timestamps are monotonic microseconds.
  fw=$(_boot_timestamp FirmwareTimestampMonotonic)
  ld=$(_boot_timestamp LoaderTimestampMonotonic)
  kernel_us=$(_boot_timestamp KernelTimestampMonotonic)
  initrd=$(_boot_timestamp InitRDTimestampMonotonic)
  userspace=$(_boot_timestamp UserspaceTimestampMonotonic)
  graphical=$(systemctl show -P ActiveEnterTimestampMonotonic graphical.target 2>/dev/null)
  finish=$(_boot_timestamp FinishTimestampMonotonic)

  value=$(_boot_delta "$fw" "$ld")
  [[ -n $value ]] && echo "boot_firmware_s=$value"

  value=$(_boot_delta "$ld" "$kernel_us")
  [[ -n $value ]] && echo "boot_loader_s=$value"

  value=$(_boot_delta "$kernel_us" "$initrd")
  [[ -n $value ]] && echo "boot_kernel_to_initrd_s=$value"

  value=$(_boot_delta "$initrd" "$userspace")
  [[ -n $value ]] && echo "boot_initrd_to_userspace_s=$value"

  value=$(_boot_delta "$userspace" "$graphical")
  [[ -n $value ]] && echo "boot_userspace_to_graphical_s=$value"

  value=$(_boot_delta "$kernel_us" "$finish")
  [[ -n $value ]] && echo "boot_kernel_to_finished_s=$value"

  # CPU temperature. k10temp is not present on every AMD CPU.
  if h=$(_hwmon_named k10temp); then
    if [[ -r $h/temp1_input ]]; then
      cpu_temp=$(cat "$h/temp1_input" 2>/dev/null)
      if [[ $cpu_temp =~ ^-?[0-9]+$ ]]; then
        echo "cpu_temp_c=$(_div "$cpu_temp" 1000)"
      fi
    fi
  fi

  # /proc/cpuinfo frequency is a snapshot, not a true time average.
  value=$(awk -F: '
    /^cpu MHz/ {
      gsub(/^[ \t]+/, "", $2)
      if ($2 ~ /^[0-9.]+$/) { sum += $2; n++ }
    }
    END { if (n) printf "%.0f", sum/n }
  ' /proc/cpuinfo)

  [[ -n $value ]] && echo "cpu_mhz_snapshot_avg=$value"

  # Dedicated AMD GPU sensors, when exposed by the driver.
  if h=$(_dgpu_hwmon); then
    for value in temp1_input temp2_input power1_average power1_input freq1_input; do
      [[ -r $h/$value ]] || continue
      [[ $(cat "$h/$value" 2>/dev/null) =~ ^[0-9]+$ ]] || continue
    done

    if [[ -r $h/temp1_input ]]; then
      value=$(cat "$h/temp1_input" 2>/dev/null)
      [[ $value =~ ^[0-9]+$ ]] &&
        echo "gpu_edge_c=$(_div "$value" 1000)"
    fi

    if [[ -r $h/temp2_input ]]; then
      value=$(cat "$h/temp2_input" 2>/dev/null)
      [[ $value =~ ^[0-9]+$ ]] &&
        echo "gpu_junction_c=$(_div "$value" 1000)"
    fi

    if [[ -r $h/power1_average ]]; then
      value=$(cat "$h/power1_average" 2>/dev/null)
      [[ $value =~ ^[0-9]+$ ]] &&
        echo "gpu_power_w=$(_div "$value" 1000000)"
    elif [[ -r $h/power1_input ]]; then
      value=$(cat "$h/power1_input" 2>/dev/null)
      [[ $value =~ ^[0-9]+$ ]] &&
        echo "gpu_power_w=$(_div "$value" 1000000)"
    fi

    if [[ -r $h/freq1_input ]]; then
      value=$(cat "$h/freq1_input" 2>/dev/null)
      [[ $value =~ ^[0-9]+$ ]] &&
        echo "gpu_sclk_mhz=$(_div "$value" 1000000)"
    fi
  fi

  # CPU utilization: sample /proc/stat over a configurable interval.
  # I/O wait is treated as idle, which avoids counting storage waits as CPU work.
  read -r -a cpu_before < <(
    awk '/^cpu / {
      total=0
      for (i=2; i<=9; i++) total += $i
      print total, $5+$6
      exit
    }' /proc/stat
  )

  if (( ${#cpu_before[@]} != 2 )); then
    warn "Could not read initial CPU counters."
    return 0
  fi

  sleep "$FT_CPU_SAMPLE"

  read -r -a cpu_after < <(
    awk '/^cpu / {
      total=0
      for (i=2; i<=9; i++) total += $i
      print total, $5+$6
      exit
    }' /proc/stat
  )

  if (( ${#cpu_after[@]} != 2 )); then
    warn "Could not read final CPU counters."
    return 0
  fi

  cpu_total_before=${cpu_before[0]}
  cpu_idle_before=${cpu_before[1]}
  cpu_total_after=${cpu_after[0]}
  cpu_idle_after=${cpu_after[1]}

  cpu_total_delta=$(( cpu_total_after - cpu_total_before ))
  cpu_idle_delta=$(( cpu_idle_after - cpu_idle_before ))

  if (( cpu_total_delta > 0 && cpu_idle_delta >= 0 )); then
    cpu_busy=$(awk -v t="$cpu_total_delta" -v i="$cpu_idle_delta" \
      'BEGIN {
        b=100*(1-i/t)
        if (b<0) b=0
        if (b>100) b=100
        printf "%.2f", b
      }')
    echo "cpu_busy_pct=$cpu_busy"
  fi
}

stage_baseline() {
  header "Stage 2 — Baseline measurement (read-only)"

  explain "Measures idle RAM, CPU utilization, services, packages, boot timing and available temperatures. For comparable results, reboot, log in, wait two minutes, and close background applications. Repeat after changes and reboots."

  local up label dir started
  local had_pipefail=0
  local rc=0

  # Validate sampling configuration.
  [[ $FT_CPU_SAMPLE =~ ^[0-9]+$ ]] &&
    (( FT_CPU_SAMPLE >= 1 && FT_CPU_SAMPLE <= 300 )) ||
    die "FT_CPU_SAMPLE must be an integer between 1 and 300 seconds."

  [[ -d $FT_BASELINE_DIR && -w $FT_BASELINE_DIR ]] ||
    die "Baseline directory is missing or not writable: $FT_BASELINE_DIR"

  up=$(awk '{ print int($1) }' /proc/uptime)

  if (( up > 1800 )); then
    warn "Uptime is $(( up / 60 )) minutes; session activity may affect measurements."
    confirm "Measure now anyway? (Recommended: reboot first)" n || return 0
  elif (( up < 120 )); then
    info "Letting the session settle for $(( 120 - up )) seconds ..."
    sleep $(( 120 - up ))
    up=$(awk '{ print int($1) }' /proc/uptime)
  fi

  read -r -p "Label for this measurement (e.g. stock, after-services): " label </dev/tty ||
    die "Unable to read the measurement label."

  label=${label//[^A-Za-z0-9._-]/_}
  label=${label:0:40}
  label=${label:-unnamed}

  umask 077
  started=$(date +%Y%m%d-%H%M%S)
  dir=$(mktemp -d "$FT_BASELINE_DIR/${started}-${label}-XXXXXX") ||
    die "Cannot create baseline directory."

  info "Measuring CPU for ${FT_CPU_SAMPLE}s. Please leave the system idle."

  {
    printf 'label=%s\n' "$label"
    printf 'date=%s\n' "$(date '+%F %T %z')"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'uptime_s=%s\n' "$up"
    measure_metrics
  } >"$dir/metrics.env" || rc=$?

  if (( rc != 0 )); then
    warn "Metric collection reported an error; inspect the partial results."
  fi

  rpm -qa --qf '%{NAME}.%{ARCH}\n' 2>/dev/null |
    sort -u >"$dir/packages.txt" ||
    warn "Could not collect the complete package list."

  systemctl list-unit-files --type=service --state=enabled \
    --no-legend --no-pager 2>/dev/null |
    awk '{ print $1 }' | sort >"$dir/enabled-units.txt"

  systemctl list-units --type=service --state=running \
    --no-legend --no-pager 2>/dev/null |
    awk '{ print $1 }' | sort >"$dir/running-services.txt"

  systemctl --user list-units --type=service --state=running \
    --no-legend --no-pager 2>/dev/null |
    awk '{ print $1 }' | sort >"$dir/running-user-services.txt"

  ps -eo rss=,comm= --sort=-rss 2>/dev/null |
    head -n 40 >"$dir/top-processes.txt"

  if [[ -s $dir/metrics.env ]]; then
    sed 's/=/\t/' "$dir/metrics.env" |
      column -t -s $'\t' | sed 's/^/    /'
  else
    warn "No metrics were collected."
    return 1
  fi

  ok "Baseline saved: $dir"
  explain "Compare runs under the same conditions. Idle RAM can change because of caches and services; a smaller process count does not necessarily mean better gaming performance."

  return "$rc"
}

_baseline_get() {
  local file=$1 key=$2
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); print; exit }' \
    "$file/metrics.env" 2>/dev/null
}

stage_compare() {
  header "Compare measurements"

  local -a dirs=()
  local i a b A B
  local key label va vb delta
  local removed added
  local missing=0

  [[ -d $FT_BASELINE_DIR ]] ||
    die "Baseline directory does not exist: $FT_BASELINE_DIR"

  mapfile -t dirs < <(
    find "$FT_BASELINE_DIR" -mindepth 2 -maxdepth 2 \
      -type f -name metrics.env -printf '%h\n' 2>/dev/null | sort
  )

  if (( ${#dirs[@]} < 2 )); then
    warn "At least two baselines are needed. Run baseline before and after a change."
    return 0
  fi

  for i in "${!dirs[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "$(basename "${dirs[$i]}")"
  done

  read -r -p "Select before and after (e.g. 1 ${#dirs[@]}): " a b </dev/tty ||
    die "Unable to read comparison selection."

  a=${a:-1}
  b=${b:-${#dirs[@]}}

  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] &&
    (( a >= 1 && b >= 1 && a <= ${#dirs[@]} && b <= ${#dirs[@]} )) ||
    { err "Invalid selection."; return 1; }

  (( a != b )) || {
    err "Select two different baselines."
    return 1
  }

  A=${dirs[$((a - 1))]}
  B=${dirs[$((b - 1))]}

  printf '\n  %-36s %12s %12s %11s\n' \
    "Metric" "before" "after" "delta"

  while IFS='|' read -r key label; do
    va=$(_baseline_get "$A" "$key")
    vb=$(_baseline_get "$B" "$key")

    [[ -z $va && -z $vb ]] && continue

    if [[ -z $va || -z $vb ]]; then
      delta="n/a"
      (( missing += 1 ))
    elif [[ $va =~ ^-?[0-9]+([.][0-9]+)?$ &&
            $vb =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
      delta=$(awk -v x="$va" -v y="$vb" \
        'BEGIN { printf "%+.2f", y-x }')
    else
      delta="n/a"
    fi

    printf '  %-36s %12s %12s %11s\n' \
      "$label" "${va:--}" "${vb:--}" "$delta"
  done <<'EOF'
mem_total_mib|Total RAM (MiB)
mem_used_mib|RAM used (MiB)
mem_available_mib|RAM available (MiB)
swap_total_mib|Total swap (MiB)
swap_used_mib|Swap used (MiB)
cpu_busy_pct|CPU busy during sample (%)
procs_userspace|Userspace processes
procs_total|All processes
services_running|System services running
user_services_running|User services running
services_enabled|Enabled services
packages|Installed RPMs
disk_root_used_mib|Root filesystem used (MiB)
boot_firmware_s|Firmware phase (s)
boot_loader_s|Bootloader phase (s)
boot_kernel_to_initrd_s|Kernel to initrd timestamp (s)
boot_initrd_to_userspace_s|Initrd to userspace timestamp (s)
boot_userspace_to_graphical_s|Userspace to graphical target (s)
boot_kernel_to_finished_s|Kernel to boot finished (s)
cpu_temp_c|CPU temperature (°C)
cpu_mhz_snapshot_avg|CPU clock snapshot average (MHz)
gpu_edge_c|GPU edge temperature (°C)
gpu_junction_c|GPU junction temperature (°C)
gpu_power_w|GPU power (W)
gpu_sclk_mhz|GPU core clock (MHz)
EOF

  printf '\nPackage changes:\n'

  if [[ -r $A/packages.txt && -r $B/packages.txt ]]; then
    removed=$(comm -23 "$A/packages.txt" "$B/packages.txt" | wc -l)
    added=$(comm -13 "$A/packages.txt" "$B/packages.txt" | wc -l)
    printf '  Removed: %s\n  Added:   %s\n' "$removed" "$added"

    if (( removed > 0 )); then
      printf '\nRemoved packages:\n'
      comm -23 "$A/packages.txt" "$B/packages.txt" | head -n 30
    fi

    if (( added > 0 )); then
      printf '\nAdded packages:\n'
      comm -13 "$A/packages.txt" "$B/packages.txt" | head -n 30
    fi
  else
    warn "A package list is missing."
  fi

  printf '\nSystem services:\n'
  if [[ -r $A/running-services.txt && -r $B/running-services.txt ]]; then
    printf '  Stopped since before:\n'
    comm -23 "$A/running-services.txt" "$B/running-services.txt" |
      sed 's/^/    /'

    printf '  Started since before:\n'
    comm -13 "$A/running-services.txt" "$B/running-services.txt" |
      sed 's/^/    /'
  else
    warn "A system service list is missing."
  fi

  printf '\nUser services:\n'
  if [[ -r $A/running-user-services.txt &&
        -r $B/running-user-services.txt ]]; then
    printf '  Stopped since before:\n'
    comm -23 "$A/running-user-services.txt" "$B/running-user-services.txt" |
      sed 's/^/    /'

    printf '  Started since before:\n'
    comm -13 "$A/running-user-services.txt" "$B/running-user-services.txt" |
      sed 's/^/    /'
  fi

  (( missing == 0 )) ||
    warn "$missing metric(s) were missing in one of the two measurements."

  explain "Delta means after minus before. Lower is not always better: temperature, CPU load, RAM usage and boot timestamps must be interpreted in context. Idle measurements do not predict in-game FPS; use comparable MangoHud logs for that."
}

# bench FILE.csv... — analyze MangoHud frametime logs without root.
bench_mangohud() {
  if (( $# == 0 )); then
    die "Usage: ./FedoraTweaks bench <mangohud-log.csv> [more.csv ...]"
  fi

  local f tmp sorted_tmp rc
  local valid=0

  for f in "$@"; do
    if [[ ! -f $f || ! -r $f ]]; then
      err "Cannot read regular file: $f"
      continue
    fi

    tmp=$(mktemp "${TMPDIR:-/tmp}/fedora-tweaks-bench.XXXXXX") || {
      err "Cannot create temporary file."
      continue
    }

    sorted_tmp="${tmp}.sorted"

    # MangoHud frametime values are normally milliseconds.
    # Normalize the header and discard invalid/non-positive samples.
    if ! awk -F, '
      NR == 1 {
        sub(/^\xef\xbb\xbf/, "", $0)
        for (i=1; i<=NF; i++) {
          name=$i
          gsub(/^[ \t"]+|[ \t"\r]+$/, "", name)
          if (name == "frametime") col=i
        }
        if (!col) exit 2
        next
      }
      {
        v=$col
        gsub(/^[ \t"]+|[ \t"\r]+$/, "", v)
        if (v ~ /^[0-9]+([.][0-9]+)?$/ && v > 0)
          print v
      }
    ' "$f" >"$tmp"; then
      err "$f: missing or invalid frametime CSV header."
      rm -f -- "$tmp" "$sorted_tmp"
      continue
    fi

    if [[ ! -s $tmp ]]; then
      err "$f: no valid positive frametime samples."
      rm -f -- "$tmp" "$sorted_tmp"
      continue
    fi

    if ! sort -gr "$tmp" >"$sorted_tmp"; then
      err "$f: sorting samples failed."
      rm -f -- "$tmp" "$sorted_tmp"
      continue
    fi

    printf '\n%s%s%s\n' "$C_BOLD" "$(basename "$f")" "$C_RESET"

    awk '
      {
        a[NR]=$1
        s+=$1
        ss+=$1*$1
      }
      END {
        n=NR
        if (!n || s<=0) {
          print "  No valid samples."
          exit 1
        }

        mean=s/n
        var=ss/n-mean*mean
        if (var<0) var=0
        sd=sqrt(var)

        # Logs are sorted slowest-to-fastest.
        # Use ceiling so the tail always contains at least one frame.
        k1=int(n*0.01)
        if (n*0.01 > k1) k1++
        if (k1<1) k1=1

        k01=int(n*0.001)
        if (n*0.001 > k01) k01++
        if (k01<1) k01=1

        for (i=1; i<=k1; i++) w1+=a[i]
        for (i=1; i<=k01; i++) w01+=a[i]

        printf "  Frames              %d\n", n
        printf "  Duration            %.2f s (sum of frame times)\n", s/1000
        printf "  Average FPS         %.2f\n", 1000*n/s
        printf "  1%% low FPS          %.2f\n", 1000/(w1/k1)
        printf "  0.1%% low FPS        %.2f\n", 1000/(w01/k01)
        printf "  Mean frametime      %.3f ms\n", mean
        printf "  Frametime stdev     %.3f ms\n", sd
        printf "  99th percentile     %.3f ms (slow-frame tail)\n", a[k1]
        printf "  Worst frametime     %.3f ms\n", a[1]
      }
    ' "$sorted_tmp"

    rc=$?
    rm -f -- "$tmp" "$sorted_tmp"

    if (( rc == 0 )); then
      (( valid += 1 ))
    else
      err "$f: unable to calculate statistics."
    fi
  done

  echo

  if (( valid == 0 )); then
    err "No logs could be analyzed."
    return 1
  fi

  explain "For meaningful comparisons, use the same game scene, resolution, graphics settings, power profile and capture duration. Run at least three tests per configuration. Average FPS is not enough: examine 1% lows, 0.1% lows and frametime stability. Very short logs can make low-percentile statistics misleading."
}
