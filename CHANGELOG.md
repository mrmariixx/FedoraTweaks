# Changelog

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
