# FedoraTweaks

A staged, reversible debloat and AMD gaming setup for **Fedora KDE Plasma** (traditional DNF/RPM Fedora, not Atomic/Bazzite).

```bash
git clone https://github.com/mrmariixx/FedoraTweaks.git
cd FedoraTweaks
./FedoraTweaks
```

That starts the guided setup. It inspects the system, records a baseline, then walks through one group of changes at a time. **Nothing changes until you say yes, and you can undo every change.**

> Targets Fedora 43–45 (Fedora 45 ships Plasma 6.7 and kernel 7.2) on an all-AMD PC (Ryzen + Radeon, AMDGPU/Mesa/RADV).
> On any other distro it exits before touching anything.

## Design rules

- **Inspect, measure, then change.** The audit and baseline stages are read-only. The tool warns you if you try to change things before you have a baseline.
- **One logical group at a time.** Every proposal is labelled **SAFE**, **OPTIONAL** or **EXPERIMENTAL**, and says what it does, what you lose and how to undo it. EXPERIMENTAL items only go ahead if you type `yes`.
- **Everything is reversible.** Each applied change writes its exact undo command to a journal. Config files are backed up before editing. `./FedoraTweaks rollback` undoes any entry, or all of them.
- **No blind package removal.** Only installed packages are considered. For each group, dnf works out the full transaction first (`--assumeno`). The group is skipped if that would remove Plasma, KWin, Dolphin, SDDM/Plasma Login, NetworkManager, PipeWire, systemd, the kernel, firmware, dnf, etc. No wildcards are ever passed to dnf.
- **Security stays on.** It keeps SELinux, firewalld, Secure Boot, TPM, systemd-oomd, NetworkManager, systemd-resolved, D-Bus and polkit. It never sets `mitigations=off` or installs a custom kernel.
- **Honest about gains.** Removing apps saves disk space and a little idle RAM. It does not raise FPS. Use the built-in measurement tools and keep only what helps.
- **Official sources.** Packages come from Fedora's repositories, plus RPM Fusion only if you choose the native Steam RPM. There are no COPRs, no curl-to-bash, and no downloaded binaries.

## Commands

| Command | What it does |
|---|---|
| `./FedoraTweaks` | Welcome screen, then the guided setup (or `m` for the menu) |
| `audit` | Read-only audit of release, kernel, CPU/GPU/RAM/storage/board, Plasma and Wayland, packages, services/timers, autostart, RAM/CPU, boot time, Mesa/Vulkan/firmware, ReBAR, Secure Boot/TPM. Saved as a shareable text report |
| `baseline` | Measures idle RAM, idle CPU (30 s sample), process and service counts, boot phases, idle temperatures/clocks/power |
| `compare` | Before/after table between two baselines, plus removed packages and services |
| `updates` | `dnf upgrade --refresh`, LVFS firmware check, pending-reboot check |
| `services` | CUPS, Avahi, Bluetooth, ModemManager, boot network wait, dnf-makecache, plocate, mdraid/LVM/iSCSI monitors (each only if it exists and is enabled or running) |
| `packages` | VM guest tools, ABRT, DrKonqi, KDE PIM/Akonadi, LibreOffice, KDE games, extra media apps, KDE Connect, remote/chat apps, rarely used utilities, printing extras, browser integration, Discover, Orca, `dnf autoremove` |
| `kde` | Baloo indexing, empty session at login, animations, blur/contrast, tearing for fullscreen games, autostart overrides |
| `gaming` | 32-bit Mesa Vulkan, GameMode, MangoHud (+ benchmark config), nvtop/lm_sensors, RPM Fusion, native Steam RPM, freeworld VA-API |
| `tuning` | Power profile, zram sysctls, ntsync, Mesa shader cache size, plus an explained list of tweaks that are *not* applied |
| `anticheat` | Fortnite / EAC Linux v2 readiness check against Epic's published requirements, with an option to set the kernel command line |
| `status` / `rollback` | Show or undo applied changes |
| `bench <log.csv>` | Average FPS, 1% and 0.1% lows, frametime mean/stdev/p99 from MangoHud logs (works on any distro) |

Add `--dry-run` (or `-n`) to any command to print state-changing commands instead of running them.

State lives in `~/.local/state/fedoratweaks/`: `journal.tsv`, `backups/`, `baselines/`, `reports/`, `mangohud-logs/` and `fedoratweaks.log`.

## Recommended workflow

1. Fresh Fedora KDE install, then `./FedoraTweaks`. Run the audit, then reboot.
2. Log in, open only a terminal, wait 2 minutes, then `./FedoraTweaks baseline` (label: `stock`).
3. In one or two games, record MangoHud logs (Shift_L+F2) of the same scene, 3 runs each.
4. Apply one stage, reboot, then run `baseline` and `compare`. Re-record the game logs and run `bench`.
5. Keep what measurably helps and `rollback` the rest.

## Fortnite on Linux: status as of 16 Oct 2026

On 14 Oct 2026 Epic [announced EAC Linux v2](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2) and said Fortnite is coming to Linux as its pilot. **It is not available yet, and there is no release date.** The published requirements are:

- a signed kernel and signed kernel modules
- TPM 2.0
- Secure Boot with well-known keys (the *Fedora Secure Boot CA* is on the list)
- measured boot
- IOMMU enabled without passthrough
- kernel lockdown in integrity mode, set explicitly at boot
- kexec disabled at boot
- the BPF LSM active

Epic says these requirements will change over time. `./FedoraTweaks anticheat` checks each one and can add the missing kernel arguments through `grubby` if you ask it to. **Never disable Secure Boot or TPM for performance**, and avoid custom kernels and out-of-tree modules. See [docs/PLAN.md](docs/PLAN.md#5-fortnite-and-anti-cheat-readiness).

## Contributing

- Keep every change reversible: journal an undo command with `journal_add`.
- New package groups go through `remove_group`, which runs the dnf preview and the protected-package check. Never call `dnf remove` directly.
- Tier honestly. If a tweak has no measurable benefit, document it under "Not applied". Don't add it.
- Run `bash -n` and `shellcheck` on everything (CI does this). Test on a disposable Fedora VM or spare install, never on your daily machine first.

## License

MIT. See [LICENSE](LICENSE).
