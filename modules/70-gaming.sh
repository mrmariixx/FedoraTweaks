
# shellcheck shell=bash
# Stage 7 — AMD gaming stack: Mesa/RADV, 32-bit Vulkan, GameMode,
# MangoHud, RPM Fusion and native Steam RPM.
#
# No proprietary AMD driver or custom kernel is installed.
# Existing user configurations are preserved.

repo_enabled() {
  local repo=$1
  dnf repolist --enabled 2>/dev/null |
    awk 'NR > 1 { print $1 }' |
    grep -Fxq -- "$repo"
}

enable_rpmfusion() {
  local ver kdir k
  local -a keys=()

  ver=$(rpm -E '%fedora' 2>/dev/null) || {
    err "Could not determine the Fedora release."
    return 1
  }

  if [[ ! $ver =~ ^[0-9]+$ ]]; then
    err "Unexpected Fedora release value: $ver"
    return 1
  fi

  if pkg_installed rpmfusion-free-release &&
     pkg_installed rpmfusion-nonfree-release; then
    ok "RPM Fusion free and nonfree release packages are installed."
    return 0
  fi

  if [[ ${FT_DRY_RUN:-0} == 1 ]]; then
    info "Dry run: RPM Fusion release packages and signing keys were not installed."
    return 0
  fi

  # Fedora's distribution-gpg-keys package provides locally installed keys.
  if ! pkg_installed distribution-gpg-keys; then
    install_pkgs "RPM Fusion signing keys" distribution-gpg-keys || {
      err "Could not install Fedora's distribution-gpg-keys package."
      return 1
    }
  fi

  kdir=/usr/share/distribution-gpg-keys/rpmfusion

  for k in \
    "$kdir/RPM-GPG-KEY-rpmfusion-free-fedora-$ver" \
    "$kdir/RPM-GPG-KEY-rpmfusion-nonfree-fedora-$ver"; do
    [[ -r $k ]] && keys+=("$k")
  done

  if (( ${#keys[@]} == 2 )); then
    for k in "${keys[@]}"; do
      sudo_run rpmkeys --import "$k" || {
        err "Could not import RPM Fusion signing key: $k"
        return 1
      }
    done
  else
    warn "Fedora's distribution-gpg-keys package does not provide both RPM Fusion keys for Fedora $ver."
    warn "DNF may ask you to verify repository signing keys. Verify their fingerprints using RPM Fusion's official documentation before accepting them."
  fi

  if ! sudo_run dnf install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$ver.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$ver.noarch.rpm"; then
    err "Could not install the RPM Fusion release packages."
    return 1
  fi

  pkg_installed rpmfusion-free-release &&
    pkg_installed rpmfusion-nonfree-release || {
      warn "RPM Fusion installation could not be verified."
      return 1
    }

  journal_add \
    "Installed RPM Fusion free and nonfree release packages" \
    "Review RPM Fusion repository configuration before removing its release packages."

  ok "RPM Fusion free and nonfree are installed."
}

write_mangohud_config() {
  local cfg="$HOME/.config/MangoHud/MangoHud.conf"
  local logdir="$FT_STATE_DIR/mangohud-logs"

  if [[ -e $cfg || -L $cfg ]]; then
    ok "MangoHud configuration already exists ($cfg); leaving it untouched."
    return 0
  fi

  if ! propose optional "Create a MangoHud benchmarking configuration" \
      "Creates a compact overlay with FPS, frametime, CPU/GPU statistics, temperatures, clocks, power, VRAM and RAM. Logs are directed to $logdir. The configuration is only used when MangoHud is launched." \
      "Nothing unless a game is launched with MangoHud. Available metrics depend on the GPU, driver and permissions." \
      "./FedoraTweaks rollback — or remove $cfg"; then
    return 0
  fi

  if [[ ${FT_DRY_RUN:-0} != 1 ]]; then
    if ! mkdir -p "$logdir"; then
      warn "Could not create the MangoHud log directory."
      return 1
    fi
  fi

  if user_write "$cfg" "# Written by FedoraTweaks
# Documentation: https://github.com/flightlessmango/MangoHud
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
# Optional FPS caps can be configured for a VRR display.
# Example: fps_limit=0,141 for a compatible 144 Hz display.
fps_limit=0
fps_limit_method=late
toggle_fps_limit=Shift_L+F1" "MangoHud configuration"; then
    ok "MangoHud configuration created."
  else
    warn "Could not create the MangoHud configuration."
    return 1
  fi
}

gaming_flathub_apps() {
  command -v flatpak >/dev/null 2>&1 || {
    info "Flatpak is not installed; skipping optional Flatpak applications."
    return 0
  }

  local remote_list='' filter='' opts=''
  local entry id name what

  remote_list=$(flatpak remotes --system --columns=name 2>/dev/null || true)

  if ! grep -Fxq flathub <<<"$remote_list"; then
    if propose optional "Add the Flathub system repository" \
        "Adds the official Flathub repository for system-wide Flatpak applications such as ProtonPlus and Heroic." \
        "Adds another software source. Applications installed from Flathub are managed separately from DNF packages." \
        "./FedoraTweaks rollback — remove the flathub system remote only if no installed applications depend on it."; then

      if sudo_run flatpak remote-add --if-not-exists --system \
          flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        journal_add \
          "Added Flathub system remote" \
          "sudo flatpak remote-delete flathub"
      else
        warn "Could not add the Flathub system remote."
        return 0
      fi
    else
      return 0
    fi
  else
    filter=$(flatpak remotes --system --columns=name,filter 2>/dev/null |
      awk '$1 == "flathub" {print $2; exit}')
    opts=$(flatpak remotes --system --columns=name,options 2>/dev/null |
      awk '$1 == "flathub" {print $2; exit}')

    if [[ ( -n $filter && $filter != - ) || $opts == *disabled* ]]; then
      warn "The existing Flathub remote is filtered or disabled. FedoraTweaks will not alter its filter or enabled state automatically."
      info "Enable or unfilter Flathub manually if you want to install the optional gaming applications."
      return 0
    fi
  fi

  remote_list=$(flatpak remotes --system --columns=name 2>/dev/null || true)
  grep -Fxq flathub <<<"$remote_list" || {
    info "Flathub is not available; skipping optional gaming applications."
    return 0
  }

  for entry in \
    "com.vysp3r.ProtonPlus|ProtonPlus|A graphical manager for community compatibility tools such as Proton-GE, where supported by the target launcher." \
    "com.heroicgameslauncher.hgl|Heroic Games Launcher|A community launcher for Epic Games Store, GOG and Amazon Games, with configurable Wine and Proton compatibility tools."; do

    IFS='|' read -r id name what <<<"$entry"

    if flatpak info --system "$id" >/dev/null 2>&1; then
      ok "$name is already installed."
      continue
    fi

    if ! propose optional "$name (Flatpak)" \
        "$what" \
        "Nothing until you launch the application. Disk usage depends on the application and its runtimes." \
        "./FedoraTweaks rollback — or: sudo flatpak uninstall --system $id"; then
      continue
    fi

    if sudo_run flatpak install --system flathub "$id"; then
      journal_add \
        "Installed Flatpak application $id" \
        "sudo flatpak uninstall --system $id"
    else
      warn "Could not install $name."
    fi
  done
}

gaming_gamemode_config() {
  pkg_installed gamemode || {
    info "GameMode is not installed; skipping its configuration."
    return 0
  }

  local cfg="$HOME/.config/gamemode.ini"

  if [[ -e $cfg || -L $cfg ]]; then
    ok "GameMode configuration already exists ($cfg); leaving it untouched."
  elif propose optional "Create a minimal GameMode configuration" \
      "Creates a user configuration that requests screensaver inhibition while a GameMode session is active. It does not force CPU/GPU clocks, overclock the GPU or change process priority." \
      "The screensaver may be inhibited during a GameMode session." \
      "./FedoraTweaks rollback — or remove $cfg"; then

    if user_write "$cfg" "; Written by FedoraTweaks
; Documentation: man gamemoded

[general]
inhibit_screensaver=1

[gpu]
; No forced clocks, overclocking or GPU power-limit changes." \
        "GameMode configuration"; then
      ok "GameMode configuration created."
    else
      warn "Could not create the GameMode configuration."
    fi
  fi

  if command -v gamemoded >/dev/null 2>&1; then
    info "GameMode daemon executable is available."
  else
    info "The GameMode daemon executable was not found; verify the installed package."
  fi
}

stage_gaming() {
  header "Stage 7 — AMD gaming stack"

  explain "Fedora's AMD graphics stack uses the amdgpu kernel driver and Mesa's RADV Vulkan driver. Steam and Proton may also need 32-bit Vulkan libraries. GameMode and MangoHud are optional tools; none guarantees higher FPS."

  # --- Check the AMD kernel driver ----------------------------------------
  if command -v lspci >/dev/null 2>&1; then
    if ! lspci -k 2>/dev/null |
        grep -A4 -iE 'VGA compatible controller|3D controller|Display controller' |
        grep -q 'Kernel driver in use: amdgpu'; then
      warn "No GPU was found using the amdgpu kernel driver in the PCI display-device listing. Check 'lspci -k' and the active graphics session before assuming the AMD GPU is unavailable."
    else
      ok "An AMD GPU is using the amdgpu kernel driver."
    fi
  else
    info "lspci is unavailable; skipping the GPU driver check."
  fi

  # --- Vulkan --------------------------------------------------------------
  if propose safe "Install Mesa Vulkan drivers and tools" \
      "Requests the RADV/Mesa Vulkan driver, the 32-bit Vulkan stack needed by compatible 32-bit games and Steam components, and vulkan-tools for diagnostics." \
      "Installs packages and dependencies. Exact disk usage depends on what is already installed." \
      "./FedoraTweaks rollback — review the package journal before removing any graphics packages"; then

    install_pkgs "Vulkan" \
      mesa-vulkan-drivers \
      mesa-vulkan-drivers.i686 \
      mesa-dri-drivers.i686 \
      vulkan-loader \
      vulkan-loader.i686 \
      vulkan-tools
  fi

  # --- GameMode ------------------------------------------------------------
  if propose safe "Install GameMode" \
      "Installs Feral Interactive's GameMode. Compatible games can request temporary system optimizations by using 'gamemoderun %command%' in Steam launch options." \
      "Installs GameMode and its dependencies. Actual benefits depend on the system and workload." \
      "./FedoraTweaks rollback — review the package journal before removing GameMode"; then

    install_pkgs "GameMode" gamemode gamemode.i686
  fi

  # --- MangoHud ------------------------------------------------------------
  if propose safe "Install MangoHud" \
      "Installs an in-game performance overlay and logger for FPS, frame times and available CPU/GPU metrics. Launch compatible games with 'mangohud %command%'." \
      "Installs MangoHud and its dependencies. The overlay is used only by applications launched with it." \
      "./FedoraTweaks rollback — review the package journal before removing MangoHud"; then

    if install_pkgs "MangoHud" mangohud mangohud.i686; then
      write_mangohud_config
    fi
  fi

  # --- Monitoring ----------------------------------------------------------
  if propose optional "Install monitoring tools" \
      "Installs nvtop and lm_sensors where available, for GPU and sensor monitoring." \
      "Installs monitoring utilities and their dependencies. Sensor availability varies by hardware." \
      "./FedoraTweaks rollback — review the package journal before removing the tools"; then

    install_pkgs "Monitoring" nvtop lm_sensors
  fi

  # --- RPM Fusion ----------------------------------------------------------
  explain "RPM Fusion provides the native Steam RPM and additional multimedia packages. The standard AMD graphics driver remains supplied by Fedora."

  if ! pkg_installed rpmfusion-free-release ||
     ! pkg_installed rpmfusion-nonfree-release; then

    if propose optional "Enable RPM Fusion free and nonfree" \
        "Installs the official RPM Fusion release packages for the current Fedora release. Required below for the native Steam RPM." \
        "Adds two repositories and their metadata to DNF operations." \
        "./FedoraTweaks rollback — inspect installed packages and repository configuration before removing RPM Fusion"; then

      enable_rpmfusion
    fi
  else
    ok "RPM Fusion release packages are already installed."
  fi

  # --- Native Steam --------------------------------------------------------
  if pkg_installed rpmfusion-nonfree-release; then
    if propose optional "Install Steam (native RPM)" \
        "Installs the Steam package from RPM Fusion. Steam downloads its own client updates and compatibility tools. Example launch options: 'gamemoderun mangohud %command%'." \
        "Installs Steam and its dependencies, including required 32-bit libraries." \
        "./FedoraTweaks rollback — review the package journal before removing Steam"; then

      install_pkgs "Steam" steam
    fi
  else
    info "RPM Fusion nonfree is not installed; skipping the native Steam RPM."
  fi

  # --- Optional Mesa VA-API codec package ---------------------------------
  if pkg_installed rpmfusion-free-release &&
     pkg_installed mesa-va-drivers &&
     command -v dnf >/dev/null 2>&1 &&
     dnf repoquery --available mesa-va-drivers-freeworld >/dev/null 2>&1; then

    if propose optional "Install Mesa VA-API Freeworld codecs" \
        "Offers the RPM Fusion Freeworld VA-API driver package for supported codec use cases. This is primarily relevant to hardware-accelerated media playback and encoding, not game FPS." \
        "Changes the selected VA-API package and may affect codec availability. Review DNF's proposed transaction before accepting." \
        "./FedoraTweaks rollback — swap back to the matching Fedora mesa-va-drivers package"; then

      if sudo_run dnf swap mesa-va-drivers mesa-va-drivers-freeworld; then
        journal_add \
          "Swapped mesa-va-drivers for mesa-va-drivers-freeworld" \
          "sudo dnf swap mesa-va-drivers-freeworld mesa-va-drivers"
      else
        warn "Could not swap the Mesa VA-API package. Keep the existing driver if DNF reports a conflict."
      fi
    fi
  else
    info "Mesa VA-API Freeworld package is not available from the enabled repositories, or the relevant packages are not installed; skipping."
  fi

  # --- Lutris --------------------------------------------------------------
  if propose optional "Install Lutris" \
      "Installs the Lutris game manager from the enabled Fedora repositories, where available. It can manage supported Wine-based games and launchers." \
      "Installs Lutris and dependencies. Some games still require additional configuration and may not work on Linux." \
      "./FedoraTweaks rollback — review the package journal before removing Lutris"; then

    install_pkgs "Lutris" lutris
  fi

  # --- User configurations and optional Flatpak apps ----------------------
  gaming_gamemode_config
  gaming_flathub_apps

  # --- Verify Vulkan -------------------------------------------------------
  if command -v vulkaninfo >/dev/null 2>&1 &&
     [[ ${FT_DRY_RUN:-0} != 1 ]]; then

    local vulkan_summary=''
    if vulkan_summary=$(vulkaninfo --summary 2>&1); then
      info "Vulkan device summary:"
      grep -E 'deviceName|driverName|driverInfo' <<<"$vulkan_summary" |
        sed 's/^/    /' || true
    else
      warn "vulkaninfo could not enumerate Vulkan devices. Check the driver and Vulkan loader installation."
    fi
  else
    info "vulkaninfo is unavailable or this is a dry run; skipping Vulkan enumeration."
  fi

  # --- Guidance ------------------------------------------------------------
  note "GPU tuning and fan control" \
    "No overclocking, undervolting, forced clocks, fan curves or power-limit changes are applied. Those operations are hardware- and driver-specific and can cause instability. Consider a dedicated GPU control utility only after verifying support for your exact hardware and Fedora release."

  note "Epic Games Store on Linux" \
    "Do not assume that Epic Games provides an officially supported native Linux launcher. Heroic is a community launcher for Epic, GOG and Amazon Games, but game compatibility depends on each title, its anti-cheat system and the current Linux support status."

  note "Benchmarking" \
    "For useful before/after comparisons, keep the game version, graphics settings, resolution, scene and background workload the same. Compare average FPS alongside frame-time consistency and 1% lows; a single short run is not conclusive."

  ok "Stage 7 completed. Review package transactions and test Vulkan before benchmarking games."
}
