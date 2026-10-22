
# FedoraTweaks

A staged, reversible debloat and AMD gaming setup for **Fedora KDE Plasma**.

FedoraTweaks is designed for traditional Fedora installations using DNF and RPM. It is not intended for Fedora Atomic desktops, Bazzite, or other immutable Fedora-based systems.

```bash
git clone https://github.com/mrmariixx/FedoraTweaks.git
cd FedoraTweaks
./FedoraTweaks
```

The guided setup audits your system, helps you record a performance baseline, and offers each group of changes individually.

**Nothing should change without your confirmation. Changes are journaled for rollback wherever supported by the relevant stage.**

> **Supported target:** Fedora 43–45, subject to verification against the actual release and package availability. Designed primarily for AMD Ryzen CPUs and Radeon GPUs using AMDGPU, Mesa and RADV.
>
> FedoraTweaks is intended for traditional DNF/RPM Fedora installations. It exits during preflight on unsupported distributions.

## Design principles

### Inspect, measure, then change

The audit and baseline stages collect information before system modifications. The recommended workflow establishes a baseline first so you can compare results afterward.

### One logical group at a time

Each proposed change should be classified as **SAFE**, **OPTIONAL**, or **EXPERIMENTAL** and explain:

- What it changes.
- What functionality you may lose.
- What risks or limitations apply.
- How to undo the change.

Experimental changes require explicit confirmation.

### Reversibility by design

Applied changes should be recorded in the change journal using `journal_add`. Configuration files should be backed up before modification.

Use:

```bash
./FedoraTweaks status
./FedoraTweaks rollback
```

Rollback depends on the undo operation recorded for each change. Some changes require a reboot or a new login session before the original behavior is restored. Reinstalling removed packages may not recreate every dependency or configuration exactly as it was.

### No blind package removal

Only installed packages should be considered for removal. Each package group must preview its DNF transaction before applying it.

If a transaction would remove protected components such as Plasma, KWin, Dolphin, SDDM, NetworkManager, PipeWire, systemd, the running kernel, firmware or DNF itself, the group must be rejected.

Package names must be explicit. Never pass unexpanded wildcards directly to DNF.

### Security stays enabled

FedoraTweaks is not intended to disable SELinux, firewalld, Secure Boot, TPM protections, or core system services such as D-Bus and polkit.

It does not apply `mitigations=off` or install a custom kernel.

Security-related changes must be clearly explained and opt-in. The anti-cheat readiness stage reports configuration status; it cannot guarantee compatibility with a game's anti-cheat system.

### Honest performance claims

Removing applications mainly saves disk space and may reduce background activity. It does not automatically increase gaming FPS.

Performance tuning should be evaluated with repeatable measurements. Keep changes only when they provide a useful result without unacceptable trade-offs.

### Official package sources

Packages should come from Fedora repositories and, when explicitly selected, RPM Fusion for the native Steam RPM.

FedoraTweaks does not use COPRs, `curl | bash`, or downloaded third-party binaries as part of its intended installation workflow.

Optional Flatpak applications use their configured Flatpak remotes.

## Requirements

- A traditional Fedora installation using DNF/RPM.
- Fedora KDE Plasma for the complete intended desktop experience.
- An AMD GPU for the AMD gaming optimizations.
- Bash and the utilities required by the preflight checks.
- A working terminal and `sudo` access for system-level changes.
- Internet access for updates and package installation.

Some features are optional and depend on installed utilities, available repositories, hardware support and the current Fedora release.

## Installation

Clone the repository and run the script as your normal user:

```bash
git clone https://github.com/mrmariixx/FedoraTweaks.git
cd FedoraTweaks
chmod +x FedoraTweaks
./FedoraTweaks
```

**Do not run FedoraTweaks with `sudo`.** The script should request elevated privileges only when required.

To inspect the available commands:

```bash
./FedoraTweaks --help
```

To check the version:

```bash
./FedoraTweaks --version
```

## Commands

| Command | Description |
|---|---|
| `./FedoraTweaks` | Open the welcome screen and guided setup |
| `guided` | Run the guided setup directly |
| `menu` | Open the interactive stage menu |
| `audit` | Generate a read-only system audit |
| `baseline` | Record system performance metrics |
| `compare` | Compare recorded baselines |
| `updates` | Update Fedora and check firmware availability |
| `services` | Review optional services and timers |
| `packages` | Review optional package-removal groups |
| `kde` | Apply selected KDE Plasma configuration changes |
| `gaming` | Set up the supported AMD gaming stack |
| `tuning` | Review and apply optional performance tuning |
| `anticheat` | Check system readiness against published EAC Linux v2 requirements |
| `status` | List recorded changes awaiting rollback |
| `rollback` | Review and undo recorded changes |
| `bench FILE` | Analyse a MangoHud CSV benchmark |

Commands can be run directly without completing the entire guided setup.

### Dry run

Use `--dry-run` or `-n` to request a dry run:

```bash
./FedoraTweaks --dry-run audit
./FedoraTweaks --dry-run gaming
./FedoraTweaks -n tuning
```

A dry run must not apply system changes. Its exact output depends on the stage and the commands that stage supports.

## What each stage does

### Stage 1 — Audit

Collects a read-only overview of the system, including:

- Fedora release and kernel.
- CPU, GPU, RAM, storage and motherboard information.
- KDE Plasma and Wayland details.
- Installed packages and relevant services.
- Autostart entries and resource usage.
- Boot timing and available temperature or frequency readings.
- Mesa, Vulkan, firmware and Resizable BAR information.
- Secure Boot and TPM status where supported.

The report is saved locally and can be used to investigate configuration problems.

Hardware and firmware readings depend on the available system interfaces and utilities. Missing readings are not necessarily evidence of a hardware fault.

### Stage 2 — Baseline and comparison

Records system metrics before and after changes, including available measurements of:

- Idle memory usage.
- CPU activity over a sampling period.
- Process and service counts.
- Boot timing.
- Temperatures, frequencies and power readings where available.
- Package and service changes.

The comparison stage helps identify what changed between measurements.

For meaningful results, keep the desktop workload, background applications, power profile and measurement conditions consistent.

### Stage 3 — Updates

Offers the normal Fedora update workflow, including:

- DNF package updates with refreshed repository metadata.
- Parallel download configuration.
- LVFS firmware availability checks through `fwupdmgr`, when supported.
- Reboot-related checks and guidance.

Firmware updates are optional and may require a reboot. FedoraTweaks should not assume that every machine supports LVFS updates.

### Stage 4 — Services and timers

Reviews optional services and timers, such as:

- CUPS printing.
- Avahi network discovery.
- Bluetooth.
- ModemManager.
- NetworkManager boot waiting.
- DNF metadata refresh timers.
- Plocate indexing.
- RAID and LVM monitoring.
- iSCSI services.
- SSD TRIM scheduling.
- Journald storage limits.

A service should only be disabled after explaining its purpose and checking its current state. Do not disable services simply because they appear in a list.

### Stage 5 — Package debloat

Offers optional removal groups covering selected applications and utilities, including:

- Virtual-machine guest tools.
- ABRT and DrKonqi reporting tools.
- KDE PIM and Akonadi components.
- LibreOffice.
- KDE games and selected media applications.
- KDE Connect.
- Selected remote-access and chat applications.
- Optional utilities and printing extras.
- Plasma Browser Integration.
- Discover and Orca.
- Unused Flatpak runtimes.
- DNF autoremove.

Every removal group must preview the transaction and check protected packages before applying changes.

Removing an application may also remove dependencies or affect workflows that rely on it. Review the transaction before confirming.

### Stage 6 — KDE Plasma

Offers optional changes involving:

- Baloo file indexing.
- Session restoration at login.
- Animation settings.
- Blur and contrast effects.
- KWin tearing configuration for fullscreen gaming.
- Per-user autostart overrides.
- Login splash settings.
- Mouse-acceleration guidance.

These changes trade desktop functionality or visual effects for a potentially simpler session. Their impact depends on the workload and hardware; they are not guaranteed FPS improvements.

### Stage 7 — Gaming stack

Sets up selected gaming components for supported AMD systems:

- 32-bit Mesa Vulkan libraries.
- GameMode and its optional priority configuration.
- MangoHud and benchmark configuration.
- Optional FPS limiting.
- `nvtop` and `lm_sensors` monitoring tools.
- RPM Fusion and the native Steam RPM, when selected.
- Optional Mesa VA-API Freeworld packages.
- Lutris.
- Optional Flathub applications such as ProtonPlus and Heroic.

Package names, repository availability and installation methods may change between Fedora releases.

**Fortnite compatibility is not guaranteed by installing these packages.** The game and its anti-cheat must explicitly support the environment in use.

### Stage 8 — Performance tuning

Offers optional settings that may affect:

- System power profiles.
- ZRAM-related memory behavior.
- NTSYNC availability.
- Mesa shader cache size.
- AMD 3D V-Cache CCD preference on supported processors.
- Write-back limits.
- PipeWire latency.

Hardware-specific options should only be offered when the required hardware and kernel interfaces are present.

The stage also documents performance tweaks that are deliberately not applied, particularly those that weaken security, have unclear benefits or introduce unnecessary system-wide risk.

### Stage 9 — Fortnite / EAC Linux v2 readiness

Checks available indicators related to Epic's published EAC Linux v2 requirements, including:

- Kernel and kernel-module signing.
- TPM 2.0.
- Secure Boot and trusted keys.
- Measured boot evidence.
- IOMMU configuration.
- Kernel lockdown.
- Kexec restrictions.
- BPF LSM availability.

The results are **diagnostic checks, not an official compatibility certification**. A local check cannot prove that every key, measurement or security property will be accepted by Epic's implementation.

The stage may offer selected kernel command-line changes through `grubby`. Such changes must be explained and confirmed. Review the proposed arguments before applying them, and retain a recovery path.

Never disable Secure Boot or TPM protections for performance. Avoid unsupported kernels and out-of-tree modules when preparing for anti-cheat compatibility.

## State, backups and reports

FedoraTweaks stores its local state under:

```text
~/.local/state/fedoratweaks/
├── journal.tsv
├── backups/
├── baselines/
├── reports/
├── mangohud-logs/
└── fedoratweaks.log
```

The exact files created depend on the stages you run.

Keep this directory private. The change journal is used to drive rollback, so it must not be treated as a source of commands from untrusted input.

Before major system changes, maintain a separate backup of important personal data.

## Recommended workflow

1. Install a supported Fedora KDE system and run `./FedoraTweaks`.
2. Review the audit report and address any obvious system issues.
3. Reboot if required, log in, close unnecessary applications and allow the desktop to settle.
4. Run `./FedoraTweaks baseline` and label the measurement `stock` if prompted.
5. Record MangoHud logs in the same game scene, at the same resolution and settings. Use multiple runs.
6. Apply one stage at a time, reviewing every proposal and package transaction.
7. Reboot or log out when a change requires it.
8. Record another baseline and run `./FedoraTweaks compare`.
9. Analyse gaming logs with `./FedoraTweaks bench <log.csv>`.
10. Keep useful changes and roll back the rest.

FPS, average frametime and low-percentile performance can vary between runs. Avoid attributing a change to one tweak unless the test conditions are sufficiently consistent.

## Fortnite on Linux — status as of 22 October 2026

On 14 October 2026, Epic Online Services published its announcement about **Easy Anti-Cheat Linux v2**.

Epic says it plans to pilot EAC Linux v2 in Fortnite first, then make it available to more developers after validating the implementation. The announcement does not specify a Fortnite Linux release date.

Official announcement:

[Awesome Gaming on Linux Without Cheating — Epic Online Services](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2)

Epic's published requirements cover the following areas:

- A kernel signed with a recognised key and appropriately signed kernel modules.
- TPM 2.0.
- Secure Boot with recognised signing keys.
- Measured boot.
- IOMMU enabled with passthrough disabled on applicable systems.
- Kernel lockdown in integrity mode, explicitly enabled at boot.
- Kexec disabled at boot.
- An active BPF LSM.

Epic notes that the requirements may evolve. FedoraTweaks can inspect relevant local indicators, but it cannot guarantee that a machine will pass Epic's checks or that Fortnite is available to play on Linux.

For further details, see [docs/WHATDOESITDO.md](docs/WHATDOESITDO.md#5-fortnite-and-anti-cheat-readiness).

## Contributing

Contributions are welcome. Please keep the project conservative, testable and reversible.

- Record every applied change with `journal_add`.
- Back up configuration files before modifying them.
- Use `remove_group` for package-removal groups and retain the DNF preview and protected-package checks.
- Never bypass the package safety checks with direct `dnf remove` calls.
- Classify changes honestly and document their limitations.
- Prefer measurable benefits over speculative optimizations.
- Preserve security protections and avoid unnecessary system-wide changes.
- Run syntax checks and ShellCheck on modified Bash files.
- Test risky changes in a disposable Fedora virtual machine or spare installation before using them on a daily system.

Suggested checks:

```bash
bash -n FedoraTweaks
bash -n lib/common.sh
bash -n modules/*.sh
shellcheck FedoraTweaks lib/common.sh modules/*.sh
```

Test rollback as well as application. A successful installation is not enough if the previous state cannot be restored correctly.

## License

FedoraTweaks is distributed under the MIT License. See [LICENSE](LICENSE).
