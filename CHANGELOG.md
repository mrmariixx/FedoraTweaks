# Changelog

## 0.3.0

Improved safety, diagnostics, and reliability across FedoraTweaks.

- **Preflight:** stronger environment checks and clearer error messages for unsupported systems.
- **Dry-run:** improved visibility into planned changes before applying them.
- **Rollback:** safer handling of previous settings and clearer reporting when a change cannot be reverted automatically.
- **Services:** more accurate detection of available units and improved preservation of their original states.
- **Packages:** stricter DNF transaction validation; skip removal operations when the proposed transaction cannot be parsed safely.
- **KDE:** improved handling of existing settings and autostart entries.
- **Gaming:** clearer dependency checks and more informative reports for missing gaming components.
- **Tuning:** improved hardware and feature detection, with unsupported tweaks skipped instead of applied blindly.
- **Anti-cheat:** clearer distinction between detected system settings and requirements that cannot be verified locally.
- **Diagnostics:** more consistent reports for missing tools, unavailable hardware interfaces, and failed commands.
- **Documentation:** expanded alpha-status warnings, compatibility notes, and explanations of known limitations.

**Note:** FedoraTweaks is still in alpha. Changes and rollback behavior require validation on supported Fedora installations. Performance improvements are hardware and arorkload DEPENDENT

## 0.2.0

New tweaks. Every one is optional, labelled, explained, and reversible with `./FedoraTweaks rollback`.

- **Updates:** dnf `max_parallel_downloads=10`.
- **Services:** enable `fstrim.timer` when it is off on SSD systems; cap the journal at 500 MB.
- **Packages:** remove unused Flatpak runtimes.
- **KDE:** turn off the login splash screen; guide for disabling mouse acceleration.
- **Gaming:**
  - GameMode priority config (`renice` / `ioprio`) and `gamemode` group membership.
  - MangoHud FPS limiter toggle.
  - Lutris (Fedora RPM).
  - Full Flathub, plus ProtonPlus and Heroic Games Launcher (Flatpak).
- **Tuning:**
  - 3D V-Cache CCD preference on dual-CCD Ryzen X3D (`amd_x3d_mode=cache`).
  - Write-back limits (`vm.dirty_bytes`).
  - Lower default PipeWire latency.
  - ntsync is detected as already loaded on Fedora 44+.
- **Docs:** more "not applied" explanations (NMI watchdog, transparent hugepages, BBR, noatime, LACT).

## 0.1.0

- First release.
