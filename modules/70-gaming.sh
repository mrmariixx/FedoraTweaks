# shellcheck shell=bash
# Stage 7 — AMD gaming stack: Mesa/RADV + 32-bit Vulkan, GameMode, MangoHud, RPM Fusion, native Steam RPM.

repo_enabled() { dnf repolist --enabled 2>/dev/null | awk '{ print $1 }' | grep -qx "$1"; }

enable_rpmfusion() {
  local ver kdir k
  local -a keys=()
  ver=$(rpm -E %fedora)
  if pkg_installed rpmfusion-free-release && pkg_installed rpmfusion-nonfree-release; then
    ok "RPM Fusion free and nonfree are already configured."
    return 0
  fi
  # Fedora 45 enforces RPM signatures, so the release packages need their keys imported first.
  # Take the keys from Fedora's own signed distribution-gpg-keys package rather than the web.
  install_pkgs "RPM Fusion signing keys" distribution-gpg-keys || return 1
  kdir=/usr/share/distribution-gpg-keys/rpmfusion
  for k in "$kdir/RPM-GPG-KEY-rpmfusion-free-fedora-$ver" "$kdir/RPM-GPG-KEY-rpmfusion-nonfree-fedora-$ver"; do
    [[ -r $k ]] && keys+=("$k")
  done
  if (( ${#keys[@]} == 2 )); then
    for k in "${keys[@]}"; do sudo_run rpmkeys --import "$k" || return 1; done
  else
    warn "distribution-gpg-keys has no RPM Fusion keys for Fedora $ver yet. dnf will show the key fingerprint — compare it with https://rpmfusion.org/keys before accepting."
  fi
  sudo_run dnf install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$ver.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$ver.noarch.rpm" \
    || { err "Could not install the RPM Fusion release packages."; return 1; }
  [[ $FT_DRY_RUN == 1 ]] && return 0
  pkg_installed rpmfusion-free-release && pkg_installed rpmfusion-nonfree-release || return 1
  journal_add "Enabled RPM Fusion free + nonfree" "sudo dnf remove rpmfusion-free-release rpmfusion-nonfree-release"
}

write_mangohud_config() {
  local cfg="$HOME/.config/MangoHud/MangoHud.conf" logdir="$FT_STATE_DIR/mangohud-logs"
  if [[ -f $cfg ]]; then
    ok "MangoHud config already exists ($cfg) — leaving it alone."
    return 0
  fi
  if propose optional "Write a MangoHud config for benchmarking" \
      "Creates $cfg: compact overlay (FPS, frametime graph, CPU/GPU load, temperatures, clocks, power, VRAM) and logging to $logdir. Shift_R+F12 toggles the overlay; Shift_L+F2 starts/stops a log for './FedoraTweaks bench'." \
      "Nothing; MangoHud only runs when you launch a game with it." \
      "./FedoraTweaks rollback — or delete $cfg"; then
    [[ $FT_DRY_RUN == 1 ]] || mkdir -p "$logdir"
    user_write "$cfg" "# Written by FedoraTweaks — see https://github.com/flightlessmango/MangoHud
fps
frametime
frame_timing
cpu_stats
cpu_temp
cpu_mhz
gpu_stats
gpu_temp
gpu_junction_temp
gpu_core_clock
gpu_power
vram
ram
position=top-left
toggle_hud=Shift_R+F12
toggle_logging=Shift_L+F2
output_folder=$logdir
log_duration=60
autostart_log=0
# FPS cap for VRR monitors: list values and cycle with Shift_L+F1, e.g. fps_limit=0,141 (refresh rate minus 3)
fps_limit=0
fps_limit_method=late
toggle_fps_limit=Shift_L+F1" "MangoHud config"
  fi
}

gaming_flathub_apps() {
  command -v flatpak >/dev/null 2>&1 || { info "flatpak is not installed — skipping Flathub apps."; return 0; }
  local filter opts
  if ! flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub; then
    if propose optional "Add the Flathub repository" \
        "Adds Flathub (flathub.org), the main Flatpak app store, system-wide. Needed for ProtonPlus and Heroic below." \
        "Nothing; it adds a software source." \
        "./FedoraTweaks rollback — or: sudo flatpak remote-delete flathub"; then
      sudo_run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
        && journal_add "Added Flathub remote" "sudo flatpak remote-delete --force flathub"
    fi
  else
    filter=$(flatpak remotes --system --columns=name,filter 2>/dev/null | awk '$1 == "flathub" { print $2 }')
    opts=$(flatpak remotes --system --columns=name,options 2>/dev/null | awk '$1 == "flathub" { print $2 }')
    if [[ ( -n $filter && $filter != - ) || $opts == *disabled* ]]; then
      if propose optional "Enable the full Flathub catalogue" \
          "Fedora ships Flathub disabled or filtered to a small list of apps, which hides ProtonPlus and Heroic. This enables it and removes the filter." \
          "Nothing; more apps become available." \
          "./FedoraTweaks rollback"; then
        sudo_run flatpak remote-modify --enable --no-filter flathub \
          && journal_add "Enabled/unfiltered Flathub" "sudo flatpak remote-modify $( [[ $opts == *disabled* ]] && echo --disable ) $( [[ -n $filter && $filter != - ]] && printf -- '--filter=%q' "$filter" ) flathub"
      fi
    fi
  fi
  flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub || return 0

  local entry id name what
  for entry in \
    "com.vysp3r.ProtonPlus|ProtonPlus|Installs and updates community Proton builds (Proton-GE and others) for Steam, Lutris and Heroic. Some games run better — or only — with Proton-GE; pick it per game in Steam › Properties › Compatibility." \
    "com.heroicgameslauncher.hgl|Heroic Games Launcher|Open-source launcher for the Epic Games Store, GOG and Amazon Games, running games through Proton/Wine with per-game settings."; do
    IFS='|' read -r id name what <<<"$entry"
    if flatpak info --system "$id" >/dev/null 2>&1; then ok "$name is already installed."; continue; fi
    if propose optional "$name (Flatpak, Flathub)" "$what" "Nothing; about 100–300 MB of disk." \
        "./FedoraTweaks rollback — or: flatpak uninstall $id"; then
      sudo_run flatpak install -y --system flathub "$id" \
        && journal_add "Installed Flatpak $id" "sudo flatpak uninstall -y --system $id"
    fi
  done
}

gaming_gamemode_config() {
  pkg_installed gamemode || return 0
  local cfg="$HOME/.config/gamemode.ini"
  if [[ -f $cfg ]]; then
    ok "GameMode config already exists ($cfg) — leaving it alone."
  elif propose optional "GameMode: raise the game's CPU and I/O priority" \
      "Writes $cfg so that, while a game started with 'gamemoderun' runs, GameMode also renices it (nice -10) and gives it the highest best-effort I/O priority. GPU settings stay untouched on purpose." \
      "Nothing; it only applies while a GameMode game runs. Renicing needs the 'gamemode' group (offered next)." \
      "./FedoraTweaks rollback — or delete $cfg"; then
    user_write "$cfg" "; Written by FedoraTweaks — see 'man gamemoded'
[general]
renice=10
ioprio=0
inhibit_screensaver=1

[gpu]
; GPU tuning (forced clocks/overclocks) is deliberately left off — see docs/WHATDOESITDO.md
;apply_gpu_optimisations=accept-responsibility" "GameMode config"
  fi
  if getent group gamemode >/dev/null && ! id -nG | tr ' ' '\n' | grep -qx gamemode; then
    if propose optional "Add $USER to the 'gamemode' group" \
        "Lets GameMode renice games (required for the setting above). Takes effect after logging out and back in." \
        "Nothing." \
        "./FedoraTweaks rollback — or: sudo gpasswd -d $USER gamemode"; then
      sudo_run usermod -aG gamemode "$USER" && journal_add "Added $USER to group gamemode" "sudo gpasswd -d $USER gamemode"
    fi
  fi
}

stage_gaming() {
  header "Stage 7 — AMD gaming stack"
  explain "AMD on Fedora needs no proprietary driver: the amdgpu kernel driver, Mesa's RADV Vulkan driver and linux-firmware come from Fedora itself. What games additionally need is the 32-bit Vulkan driver (Steam/Proton), and optionally GameMode and MangoHud."

  if ! lsmod | grep -q '^amdgpu'; then
    warn "The amdgpu kernel module is not loaded. On an all-AMD PC this usually means the monitor is on the wrong output or the GPU is not detected. Check 'lspci -k'."
  fi

  if propose safe "Mesa Vulkan drivers incl. 32-bit + vulkan-tools" \
      "Makes sure RADV (64- and 32-bit), the Vulkan loader and 'vulkaninfo' are installed. Steam/Proton and DXVK/VKD3D need the 32-bit driver for 32-bit games and the Steam client." \
      "Nothing (adds ~100 MB)." \
      "./FedoraTweaks rollback (removes only what this step added)"; then
    install_pkgs "Vulkan" mesa-vulkan-drivers mesa-vulkan-drivers.i686 mesa-dri-drivers.i686 \
      vulkan-loader vulkan-loader.i686 vulkan-tools
  fi

  if propose safe "GameMode" \
      "Feral's GameMode raises the CPU performance preference, I/O and scheduling priority only while a game runs. Use it per game in Steam launch options: gamemoderun %command%" \
      "Nothing; it is idle unless a game requests it. Effect is often small on desktop Ryzen with amd-pstate; measure with MangoHud." \
      "./FedoraTweaks rollback"; then
    install_pkgs "GameMode" gamemode gamemode.i686
  fi

  if propose safe "MangoHud" \
      "Overlay and logger for FPS, frametimes, temperatures, clocks and power — the tool used for the before/after gaming benchmarks. Use per game: mangohud %command%" \
      "Nothing; it only loads into games you launch with it." \
      "./FedoraTweaks rollback"; then
    install_pkgs "MangoHud" mangohud mangohud.i686 && write_mangohud_config
  fi

  if propose optional "Monitoring tools (nvtop, lm_sensors)" \
      "nvtop shows AMD GPU load, VRAM, clocks and power per process; 'sensors' shows CPU (k10temp) and GPU temperatures and fan speed." \
      "Nothing." \
      "./FedoraTweaks rollback"; then
    install_pkgs "Monitoring" nvtop lm_sensors
  fi

  # --- RPM Fusion + Steam ----------------------------------------------------
  explain "Steam's client is proprietary, so Fedora itself does not ship it. The native RPM comes from RPM Fusion nonfree, the long-standing community repository Fedora's own docs point to."
  if propose optional "Enable RPM Fusion (free + nonfree)" \
      "Adds the RPM Fusion repositories. Required for the native Steam RPM and the full-codec Mesa VA-API driver. Signing keys are imported from Fedora's distribution-gpg-keys package." \
      "Nothing; adds two repositories (more metadata to download on updates)." \
      "./FedoraTweaks rollback — or: sudo dnf remove rpmfusion-free-release rpmfusion-nonfree-release"; then
    enable_rpmfusion
  fi

  if pkg_installed rpmfusion-nonfree-release || [[ $FT_DRY_RUN == 1 ]]; then
    if propose optional "Steam (native RPM)" \
        "Installs the 'steam' package from RPM Fusion nonfree. It pulls in the 32-bit libraries Steam needs and udev rules for Steam Input controllers. Proton is downloaded by Steam itself. Launch options per game: gamemoderun mangohud %command%" \
        "Nothing." \
        "./FedoraTweaks rollback — or: sudo dnf remove steam"; then
      install_pkgs "Steam" steam
    fi
  else
    info "RPM Fusion nonfree is not enabled — skipping the Steam RPM. (The Flathub Steam Flatpak is the alternative.)"
  fi

  if pkg_installed rpmfusion-free-release && pkg_installed mesa-va-drivers \
     && [[ -n $(dnf repoquery --available mesa-va-drivers-freeworld 2>/dev/null) ]]; then
    if propose optional "Mesa VA-API driver with H.264/HEVC (freeworld)" \
        "Fedora's Mesa VA-API driver omits patent-encumbered codecs. The RPM Fusion 'freeworld' build restores hardware H.264/HEVC encode/decode — useful for OBS recording, Steam Remote Play and browser video. Not an FPS change." \
        "Nothing." \
        "./FedoraTweaks rollback — or: sudo dnf swap mesa-va-drivers-freeworld mesa-va-drivers"; then
      sudo_run dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld \
        && journal_add "Swapped to mesa-va-drivers-freeworld" "sudo dnf swap -y mesa-va-drivers-freeworld mesa-va-drivers"
      if pkg_installed mesa-va-drivers.i686; then
        sudo_run dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 \
          && journal_add "Swapped to mesa-va-drivers-freeworld.i686" "sudo dnf swap -y mesa-va-drivers-freeworld.i686 mesa-va-drivers.i686"
      fi
    fi
  fi

  if propose optional "Lutris (native RPM, Fedora repository)" \
      "Game manager for Battle.net, EA app, Ubisoft Connect, emulators and other non-Steam games, with ready-made install scripts." \
      "Nothing; adds Wine-related dependencies." \
      "./FedoraTweaks rollback"; then
    install_pkgs "Lutris" lutris
  fi
  gaming_gamemode_config
  gaming_flathub_apps

  if command -v vulkaninfo >/dev/null 2>&1 && [[ $FT_DRY_RUN != 1 ]]; then
    info "Vulkan devices:"
    vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|driverInfo' | sed 's/^/    /'
  fi

  note "Fan control and overclocking" \
    "The GPU firmware already runs a sensible fan curve. Custom fan curves, undervolting and power limits need amdgpu 'overdrive' (kernel parameter amdgpu.ppfeaturemask), which may flag the kernel as tainted. LACT (the most complete AMD GPU control app) is only available from the unofficial COPR 'ilyaz/LACT' or as a Flatpak, so this tool does not install it. Overdrive is not enabled; see docs/WHATDOESITDO.md."
  note "Epic Games Launcher" \
    "Epic lists a native Linux launcher (AppImage) with Fedora 43+ among supported distros at https://launcher.epicgames.com/ . Download it there yourself; this tool does not fetch binaries."
}
