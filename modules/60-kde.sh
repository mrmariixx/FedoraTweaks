
# shellcheck shell=bash
# Stage 6 — KDE Plasma: lighter, without removing Plasma components.
# Changes are per-user KConfig keys or XDG autostart overrides.
# Preserve existing user configuration and journal successful changes.

# Autostart entries: FILE|TIER|WHAT|LOSS
FT_AUTOSTART_CANDIDATES=(
  "org.kde.discover.notifier.desktop|optional|Discover's tray update checker.|Update notifications in the tray."
  "org.kde.kdeconnect.daemon.desktop|optional|KDE Connect daemon.|Phone integration and device synchronization."
  "org.kde.kalendarac.desktop|optional|KDE calendar reminder daemon.|Pop-up calendar reminders."
  "org.kde.kunifiedpush-distributor.desktop|optional|Push notification distributor used by compatible applications.|Push notifications for supported applications."
  "geoclue-demo-agent.desktop|optional|GeoClue location agent, if provided by the installed desktop.|Location access for applications that depend on this agent."
  "abrt-applet.desktop|optional|ABRT crash notification applet.|Graphical crash-report notifications."
  "kaccess.desktop|optional|KDE keyboard accessibility helper.|Sticky, slow and bounce key features. Keep enabled if you use them."
  "gmenudbusmenuproxy.desktop|optional|Exports GTK application menus to Plasma's global menu integration.|GTK application menus in a global menu widget."
)

# kde_get FILE GROUP KEY — current value, or 'unset'.
kde_get() {
  local file=$1 group=$2 key=$3 value

  if ! command -v kreadconfig6 >/dev/null 2>&1; then
    printf '%s\n' unset
    return 0
  fi

  value=$(kreadconfig6 \
    --file "$file" \
    --group "$group" \
    --key "$key" \
    --default unset 2>/dev/null) || value=unset

  printf '%s\n' "${value:-unset}"
}

stage_kde() {
  header "Stage 6 — KDE Plasma"

  if [[ ${FT_IS_KDE:-0} != 1 ]]; then
    warn "Not in a supported Plasma 6 session, or kwriteconfig6 is unavailable. Skipping KDE changes."
    return 0
  fi

  if ! command -v kwriteconfig6 >/dev/null 2>&1 ||
     ! command -v kreadconfig6 >/dev/null 2>&1; then
    warn "KConfig tools are incomplete. Skipping KDE changes to avoid unreliable reads or writes."
    return 0
  fi

  explain "This stage changes user-level Plasma settings only. It does not remove Plasma packages or intentionally alter networking, security, audio, screen locking or display-manager services. Desktop optimizations mainly affect responsiveness and background activity; they do not guarantee higher FPS in games."

  # --- Baloo file indexing -------------------------------------------------
  local baloo_enabled='unset'
  local idx_size=''
  local baloo_changed=0

  if command -v balooctl6 >/dev/null 2>&1; then
    baloo_enabled=$(kde_get baloofilerc 'Basic Settings' Indexing-Enabled)

    if [[ ${baloo_enabled,,} == false ]]; then
      ok "Baloo file indexing is already disabled."
    else
      idx_size=$(du -sh "$HOME/.local/share/baloo" 2>/dev/null |
        awk 'NR == 1 {print $1}')

      if propose optional "Disable Baloo file indexing" \
          "Disables KDE's file-content indexing service. Current index directory size: ${idx_size:-unknown}. This may reduce background disk activity after large file changes." \
          "Content-based and indexed file search in KRunner and compatible applications may become less useful or slower. Ordinary file access and find remain available." \
          "./FedoraTweaks rollback — or: balooctl6 enable"; then

        if run balooctl6 disable; then
          journal_add "Baloo indexing disabled" "balooctl6 enable"
          baloo_changed=1
          ok "Baloo indexing disable command completed."

          if [[ -d $HOME/.local/share/baloo ]] &&
             confirm "  Purge the existing Baloo index (${idx_size:-size unknown}) to reclaim disk space?" n; then

            if run balooctl6 purge; then
              journal_add "Purged Baloo search index" \
                "The index will be rebuilt when indexing is enabled again."
              ok "Baloo index purge command completed."
            else
              warn "Could not purge the Baloo index."
            fi
          fi
        else
          warn "Could not disable Baloo. No successful change was recorded."
        fi
      fi
    fi
  else
    info "balooctl6 is unavailable; skipping Baloo changes."
  fi

  # --- Session restore -----------------------------------------------------
  local login_mode
  login_mode=$(kde_get ksmserverrc General loginMode)

  if [[ $login_mode == emptySession ]]; then
    ok "Login is already configured to start with an empty session."
  elif propose optional "Start each login with an empty session" \
      "Sets Plasma's login mode to emptySession, avoiding automatic restoration of applications from the previous login." \
      "Applications previously open at logout will not automatically reopen. Save your work before logging out." \
      "./FedoraTweaks rollback — or System Settings > Session > Desktop Session"; then

    if kde_set ksmserverrc General loginMode emptySession; then
      ok "Empty-session login setting applied."
    else
      warn "Could not update the session restore setting."
    fi
  fi

  # --- Animations ----------------------------------------------------------
  local animation_factor
  animation_factor=$(kde_get kdeglobals KDE AnimationDurationFactor)

  if [[ $animation_factor == 0 ]]; then
    ok "Plasma animations are already configured as instant."
  elif propose optional "Turn off Plasma UI animations" \
      "Sets AnimationDurationFactor=0 for the current user, making supported Plasma animations instantaneous." \
      "Desktop transitions and animations. This is a visual preference, not a gaming FPS optimization." \
      "./FedoraTweaks rollback — or System Settings > General Behavior > Animation speed"; then

    if kde_set kdeglobals KDE AnimationDurationFactor 0; then
      ok "Plasma animation setting applied."
    else
      warn "Could not update the animation setting."
    fi
  fi

  # --- Blur and background contrast ---------------------------------------
  local blur_enabled contrast_enabled
  blur_enabled=$(kde_get kwinrc Plugins blurEnabled)
  contrast_enabled=$(kde_get kwinrc Plugins contrastEnabled)

  if [[ $blur_enabled == false && $contrast_enabled == false ]]; then
    ok "Blur and background contrast are already disabled."
  elif propose optional "Disable blur and background contrast" \
      "Disables KWin's blur and background-contrast effects where supported. This can reduce rendering work for translucent desktop surfaces." \
      "Panels and menus lose their blur or frosted-glass appearance. The effect on fullscreen gaming performance is usually small or unmeasurable." \
      "./FedoraTweaks rollback — or System Settings > Window Management > Desktop Effects"; then

    local blur_rc=0 contrast_rc=0

    kde_set kwinrc Plugins blurEnabled false || blur_rc=$?
    kde_set kwinrc Plugins contrastEnabled false || contrast_rc=$?

    if (( blur_rc == 0 && contrast_rc == 0 )); then
      if kwin_reconfigure; then
        ok "Blur and background-contrast settings applied."
      else
        warn "Settings were written, but KWin could not be reconfigured. Log out and back in if needed."
      fi
    else
      warn "One or more effect settings could not be written. Review the current KWin configuration."
    fi
  fi

  # --- Tearing for fullscreen games ---------------------------------------
  local tearing
  tearing=$(kde_get kwinrc Compositing AllowTearing)

  if [[ $tearing == true ]]; then
    ok "AllowTearing is already enabled."
  elif propose optional "Allow tearing for eligible fullscreen games" \
      "Enables KWin's AllowTearing setting. With compatible fullscreen applications and V-Sync disabled, this may reduce presentation latency." \
      "Visible screen tearing may occur. Results depend on KWin, the graphics driver, the application and display configuration. VRR can improve the experience on supported hardware, but does not guarantee tear-free output." \
      "./FedoraTweaks rollback — or System Settings > Display & Monitor, if the option is available"; then

    if kde_set kwinrc Compositing AllowTearing true; then
      if kwin_reconfigure; then
        ok "Fullscreen tearing setting applied."
      else
        warn "The setting was written, but KWin could not be reconfigured."
      fi
    else
      warn "Could not update KWin's AllowTearing setting."
    fi
  fi

  # --- XDG autostart overrides --------------------------------------------
  explain "Autostart overrides are per-user files in ~/.config/autostart. Existing user customizations are never overwritten. A Hidden=true override can suppress a matching system autostart entry."

  local entry file tier what loss system_entry target
  local autostart_dir="$HOME/.config/autostart"

  for entry in "${FT_AUTOSTART_CANDIDATES[@]}"; do
    IFS='|' read -r file tier what loss <<<"$entry"

    [[ -n $file ]] || continue

    system_entry="/etc/xdg/autostart/$file"
    target="$autostart_dir/$file"

    # Only handle entries provided by the system autostart directory.
    if [[ ! -f $system_entry ]]; then
      continue
    fi

    # Do not overwrite a pre-existing user override.
    if [[ -e $target || -L $target ]]; then
      if [[ -f $target ]] &&
         grep -qiE '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true([[:space:]]*($|#))' "$target"; then
        continue
      fi

      info "Skipping $file: a user override already exists at $target."
      continue
    fi

    if propose "$tier" "Disable autostart: ${file%.desktop}" \
        "$what" \
        "$loss" \
        "./FedoraTweaks rollback — or remove $target if FedoraTweaks created it"; then

      if user_write "$target" \
          $'[Desktop Entry]\nHidden=true' \
          "Autostart hidden: $file"; then
        ok "Created per-user autostart override for $file."
      else
        warn "Could not create the autostart override for $file."
      fi
    fi
  done

  # --- Login splash -------------------------------------------------------
  local splash_engine
  splash_engine=$(kde_get ksplashrc KSplash Engine)

  if [[ $splash_engine == none ]]; then
    ok "The Plasma splash engine is already disabled."
  elif propose optional "Disable the Plasma login splash animation" \
      "Sets the Plasma splash engine to none for the current user." \
      "The visual splash animation after login." \
      "./FedoraTweaks rollback — or System Settings > Colors & Themes > Splash Screen"; then

    if kde_set ksplashrc KSplash Engine none; then
      if kde_set ksplashrc KSplash Theme None; then
        ok "Splash-screen settings applied."
      else
        warn "The splash engine was changed, but the theme setting could not be updated."
      fi
    else
      warn "Could not update the splash-screen setting."
    fi
  fi

  # --- Manual recommendations --------------------------------------------
  note "Mouse acceleration" \
    "If you prefer a consistent mouse feel, open System Settings > Mouse & Touchpad and review the acceleration profile for your device. A flat profile disables acceleration where supported. Some games use raw input and may ignore desktop pointer settings."

  note "Thumbnails and file previews" \
    "Not changed. Dolphin previews are generally generated when relevant folders are accessed. Disabling them globally may reduce convenience without producing a meaningful gaming benefit."

  note "Widgets and KDED modules" \
    "Remove unused widgets manually if desired. Many desktop modules are lightweight or start on demand, so disabling them indiscriminately is unlikely to provide measurable performance improvements."

  if [[ ${XDG_SESSION_TYPE:-unknown} != wayland ]]; then
    warn "This session is not identified as Wayland. Plasma Wayland may offer better integration with modern display features, but verify your GPU, monitor and application compatibility before switching."
  fi

  ok "Stage 6 completed. Review the FedoraTweaks journal before reverting or changing settings."
}
