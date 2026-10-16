# shellcheck shell=bash
# Stage 6 — KDE Plasma: lighter, without removing anything Plasma needs.
# All changes are per-user KConfig keys or XDG autostart overrides; each is journaled.

# Autostart entries that are safe to hide on a gaming desktop: FILE|TIER|WHAT|LOSS
FT_AUTOSTART_CANDIDATES=(
  "org.kde.discover.notifier.desktop|optional|Discover's tray update checker (polls PackageKit).|Update notifications in the tray."
  "org.kde.kdeconnect.daemon.desktop|optional|KDE Connect daemon.|Phone integration."
  "org.kde.kalendarac.desktop|optional|Calendar reminder daemon; it starts Akonadi.|Pop-up reminders for KDE calendar events."
  "org.kde.kunifiedpush-distributor.desktop|optional|Push-notification distributor used by NeoChat/Tokodon.|Push notifications for those apps."
  "geoclue-demo-agent.desktop|optional|GeoClue location agent.|Location for apps that ask for it (night color can use a manual location)."
  "abrt-applet.desktop|optional|ABRT crash notifier.|Crash report pop-ups."
  "kaccess.desktop|optional|Accessibility helper for sticky/slow/bounce keys.|Those keyboard accessibility features. Keep it if you use them."
  "gmenudbusmenuproxy.desktop|optional|Exports GTK app menus to a Plasma global-menu widget.|Global menus for GTK apps (only matters with a global menu widget)."
)

# kde_get FILE GROUP KEY — current value, or 'unset'
kde_get() { kreadconfig6 --file "$1" --group "$2" --key "$3" --default unset 2>/dev/null || echo unset; }

stage_kde() {
  header "Stage 6 — KDE Plasma"
  if [[ $FT_IS_KDE != 1 ]]; then
    warn "Not in a Plasma 6 session (or kwriteconfig6 missing) — skipping."
    return 0
  fi
  explain "Plasma stays complete: launcher, Dolphin, clipboard, notifications, screen locking, display settings, PipeWire and Wayland are untouched. KWin bypasses compositing for fullscreen games (direct scan-out), so desktop effects mostly affect the desktop, not in-game FPS."

  # --- Baloo file indexing -------------------------------------------------
  if command -v balooctl6 >/dev/null 2>&1 \
     && [[ $(kde_get baloofilerc 'Basic Settings' Indexing-Enabled) != false ]]; then
    local idx_size
    idx_size=$(du -sh "$HOME/.local/share/baloo" 2>/dev/null | cut -f1)
    if propose optional "Disable Baloo file indexing" \
        "Turns off the background indexer that reads your files to build a search database (current index: ${idx_size:-none}). Game libraries with many small files make it work hard after installs/updates." \
        "Full-text and fast file search in KRunner/Dolphin. Dolphin can still search filenames (slower), and 'find'/'locate' work." \
        "./FedoraTweaks rollback — or: balooctl6 enable"; then
      run balooctl6 disable && journal_add "Baloo indexing disabled" "balooctl6 enable"
      if [[ -d $HOME/.local/share/baloo ]] && confirm "  Also delete the existing index (${idx_size}) to free space?" n; then
        run balooctl6 purge
      fi
    fi
  else
    ok "Baloo indexing already disabled (or not installed)."
  fi

  # --- Session restore -------------------------------------------------------
  if [[ $(kde_get ksmserverrc General loginMode) == emptySession ]]; then
    ok "Login already starts with an empty session."
  elif propose optional "Start each login with an empty session" \
      "Plasma normally reopens the apps that were running at logout. This starts clean instead, so idle RAM after login is predictable and stale apps do not linger." \
      "Automatic reopening of previous apps." \
      "./FedoraTweaks rollback — or System Settings › Session › Desktop Session"; then
    kde_set ksmserverrc General loginMode emptySession
  fi

  # --- Animations --------------------------------------------------------------
  if [[ $(kde_get kdeglobals KDE AnimationDurationFactor) == 0 ]]; then
    ok "Animations are already off."
  elif propose optional "Turn off UI animations" \
      "Sets Plasma's global animation speed to instant (AnimationDurationFactor=0). Menus and windows appear immediately." \
      "Animations. No effect on in-game performance." \
      "./FedoraTweaks rollback — or System Settings › General Behavior › Animation speed"; then
    kde_set kdeglobals KDE AnimationDurationFactor 0
  fi

  # --- Blur / translucency -----------------------------------------------------
  if [[ $(kde_get kwinrc Plugins blurEnabled) == false && $(kde_get kwinrc Plugins contrastEnabled) == false ]]; then
    ok "Blur and background contrast are already off."
  elif propose optional "Disable blur and background-contrast effects" \
      "Disables KWin's blur and background contrast effects behind panels and menus — the most GPU-costly desktop effects." \
      "Frosted-glass look of panels/menus. Mostly cosmetic; little to no change in fullscreen games." \
      "./FedoraTweaks rollback — or System Settings › Window Management › Desktop Effects"; then
    kde_set kwinrc Plugins blurEnabled false
    kde_set kwinrc Plugins contrastEnabled false
    kwin_reconfigure
  fi

  # --- Tearing for fullscreen games -----------------------------------------
  local tearing
  tearing=$(kde_get kwinrc Compositing AllowTearing)
  if [[ $tearing != true ]]; then
    if propose optional "Allow tearing in fullscreen games (lower latency)" \
        "Lets KWin present frames immediately for fullscreen apps that request it (in-game V-Sync OFF). Current setting: $tearing. This lowers input latency at the cost of possible screen tearing; with a FreeSync/VRR monitor and an FPS cap just below the refresh rate, tearing is usually invisible." \
        "Tear-free presentation for games that disable V-Sync. Games with V-Sync ON are unaffected." \
        "./FedoraTweaks rollback — or System Settings › Display & Monitor › 'Allow tearing in fullscreen'"; then
      kde_set kwinrc Compositing AllowTearing true
      kwin_reconfigure
    fi
  else
    ok "Tearing for fullscreen games is already allowed."
  fi

  # --- Autostart entries -----------------------------------------------------
  explain "Autostart: a file with 'Hidden=true' in ~/.config/autostart overrides the system entry for your user only. Nothing is uninstalled."
  local entry file tier what loss target
  for entry in "${FT_AUTOSTART_CANDIDATES[@]}"; do
    IFS='|' read -r file tier what loss <<<"$entry"
    [[ -f /etc/xdg/autostart/$file ]] || continue
    target="$HOME/.config/autostart/$file"
    if [[ -f $target ]] && grep -qi '^Hidden=true' "$target"; then continue; fi
    if propose "$tier" "Do not autostart: ${file%.desktop}" "$what" "$loss" \
        "./FedoraTweaks rollback — or delete $target"; then
      user_write "$target" $'[Desktop Entry]\nHidden=true' "Autostart hidden: $file"
    fi
  done

  # --- Login splash --------------------------------------------------------
  if [[ $(kde_get ksplashrc KSplash Engine) == none ]]; then
    ok "Login splash screen is already off."
  elif propose optional "Skip the splash screen after login" \
      "Turns off Plasma's splash animation (ksplashrc Engine=none), so the desktop shows as soon as it is ready instead of after the animation." \
      "The splash animation." \
      "./FedoraTweaks rollback — or System Settings › Colors & Themes › Splash Screen"; then
    kde_set ksplashrc KSplash Engine none
    kde_set ksplashrc KSplash Theme None
  fi

  note "Mouse acceleration (do this by hand)" \
    "For consistent aim, open System Settings › Mouse & Touchpad, pick your mouse and set the acceleration profile to 'None' (flat), leaving speed at the default. It is not scripted because Plasma stores it per device under keys that are not documented. Verify with: sudo libinput list-devices (look at 'Accel profile'). Many games use raw input and ignore it anyway."
  note "Thumbnails and file previews" \
    "Not changed. Dolphin generates previews only for folders you open, so disabling them saves nothing while gaming."
  note "Widgets and kded modules" \
    "Remove unused panel widgets by right-clicking them. Background kded modules are tiny and on-demand; toggling them individually has no measurable benefit."
  [[ ${XDG_SESSION_TYPE:-} == wayland ]] || warn "You are not in a Wayland session. Choose 'Plasma (Wayland)' at the login screen — VRR, tearing control and HDR need it."
}
