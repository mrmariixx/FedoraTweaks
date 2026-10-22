
# The optimization plan

This document explains the reasoning behind each stage of `./FedoraTweaks`, the intended impact of each change, and its risk tier.

**Last reviewed: 22 October 2026.** Fedora 45 is still a pre-release at the time of writing; its current target date is 27 October 2026, subject to release validation. Fedora 45 package versions and defaults may therefore change. Do not treat beta/RC behavior as a guarantee for the final release.

## Tiers

- **SAFE**: normally appropriate on a typical gaming desktop when the stated conditions apply. “Safe” does not mean universally useful or risk-free; review the proposed action before applying it.
- **OPTIONAL**: disables or changes a feature, costs power, or has a benefit that depends on workload. Measure before and after.
- **EXPERIMENTAL / NOT APPLIED**: hardware-dependent, risky, weakly supported, or not backed by consistent measurements. FedoraTweaks explains it but does not apply it automatically.

A change is only reversible to the extent that FedoraTweaks records the previous state and has a valid undo operation. Package reinstallation, firmware settings, and external changes are not always exact rollbacks.

---

## 1. Audit (read-only)

`./FedoraTweaks audit` collects system information and saves a report under `~/.local/state/fedoratweaks/reports/`. These are examples of useful checks; some commands require optional packages or permissions.

| What | Command | What the output tells you |
|---|---|---|
| Release / kernel | `cat /etc/os-release`, `uname -r`, `rpm -q kernel-core` | Fedora release, running kernel, and installed kernel package. A package name alone does not prove the running kernel satisfies a game's anti-cheat policy. |
| CPU | `lscpu`, `cat /sys/devices/system/cpu/amd_pstate/status` | CPU topology and, where supported, AMD P-State status. The sysfs file may not exist on every CPU/kernel combination. |
| GPU / driver | `lspci -nnk \| grep -A3 -E 'VGA|3D|Display'` | GPU and kernel driver in use, such as `amdgpu`. |
| ReBAR | `journalctl -k -b \| grep -iE 'amdgpu.*BAR|BAR.*amdgpu'` | Kernel messages that may help diagnose PCI BAR configuration. Log wording and values vary; this check is not a universal pass/fail test for Resizable BAR. |
| Mesa / Vulkan | `rpm -q mesa-vulkan-drivers mesa-vulkan-drivers.i686`, `vulkaninfo --summary` | Installed Vulkan packages and available Vulkan devices. The 32-bit package query may report that a package is absent. |
| RAM | `sudo dmidecode -t memory` | Firmware-reported memory modules and configured speed. EXPO/XMP labels and reported speeds vary by firmware; compare the effective data rate correctly. |
| Storage / board | `lsblk -o NAME,SIZE,FSTYPE,MODEL`, `cat /sys/class/dmi/id/board_name` | Storage layout and motherboard model. Other DMI files can provide BIOS information. |
| Plasma / session | `plasmashell --version`, `echo "$XDG_SESSION_TYPE"` | Plasma version and session type, such as `wayland` or `x11`. |
| Packages / repos | `rpm -qa \| wc -l`, `dnf group list --installed`, `dnf repolist` | Installed RPM count, installed groups, and enabled repositories. Package count alone is not a performance metric. |
| Services | `systemctl list-unit-files --state=enabled`, `systemctl list-timers` | Enabled unit files and scheduled timers. Enabled does not necessarily mean currently running. |
| Autostart | `ls /etc/xdg/autostart ~/.config/autostart` | System and user desktop autostart entries, if the directories exist. |
| Resources | `free -m`, `ps -eo rss,comm --sort=-rss \| head` | Memory availability and processes with the largest resident memory use. |
| Boot | `systemd-analyze`, `systemd-analyze blame` | Boot timing and unit startup durations. `blame` does not show the total boot critical path by itself. |
| Security | `mokutil --sb-state`, `getenforce`, `cat /sys/kernel/security/lockdown` | Secure Boot, SELinux, and kernel lockdown state where the relevant tools and interfaces are available. |

Audit output is diagnostic evidence, not proof that every component is configured optimally. Missing commands or files should be reported as unavailable rather than silently interpreted as a failed security check.

---

## 2. Baseline and testing method

- **Idle metrics (`baseline`)**: for comparable measurements, reboot, log in, start only a terminal, wait about two minutes, and avoid background downloads or updates. FedoraTweaks records the metrics supported by the host, such as memory use (`MemTotal − MemAvailable`), CPU busy percentage over a sampling window, process count, running services, boot timings, and available temperature/clock/power telemetry. Some sensors and boot fields will be unavailable on some systems.
- **Gaming metrics**: use MangoHud logging and repeat the same scene, settings, resolution, power profile, and cap. Aim for at least **three runs per configuration**. Close unrelated applications and let shader compilation or background updates settle. `./FedoraTweaks bench *.csv` can summarize compatible MangoHud CSV files; the exact metrics depend on the CSV format and the parser supported by the current script version.
- **FPS and frame pacing**: compare average FPS, 1% lows, 0.1% lows, frame-time variability, and high-percentile frame times only when the input data and calculation method support them. “1% low” has multiple definitions across tools; do not compare figures calculated with different methods as if they were identical.
- **Interpretation**: the difference between configurations must be larger than normal run-to-run variation to be persuasive. Keep raw CSV files and record the game version, driver/kernel, resolution, settings, and run conditions.
- **Input latency** cannot be measured reliably from ordinary FPS counters. Specialized equipment such as an LDAT or a high-speed camera is needed for meaningful end-to-end measurements. Tearing, V-Sync, VRR, and frame caps change the latency/tearing trade-off; none is universally best.
- **No invented benchmark numbers**: this project should report measured results from the user's system, not promise a fixed FPS or RAM reduction.

---

## 3. Fedora and KDE debloat

### Services (stage 4)

These actions should only be offered after checking whether the service exists and, where relevant, whether the machine appears to use the associated hardware or feature.

| Change | Tier | What you may lose / consider |
|---|---|---|
| Disable CUPS and `cups-browsed` | OPTIONAL | Local/network printing and printer discovery. |
| Mask Avahi | OPTIONAL | mDNS/`.local` discovery and some network printer/scanner discovery. |
| Mask Bluetooth | OPTIONAL | Bluetooth controllers, headphones, keyboards, and other peripherals. Keep it if you use Bluetooth. |
| Mask ModemManager | SAFE only when no modem is needed; otherwise OPTIONAL | WWAN/LTE modems and related mobile broadband features. |
| Disable `NetworkManager-wait-online` | OPTIONAL | Services that genuinely require network connectivity during early boot may behave differently. It does not guarantee a faster boot on every machine. |
| Disable `dnf-makecache.timer` | OPTIONAL | Scheduled metadata refresh; DNF can refresh metadata on demand, but the next operation may need to download it. |
| Disable `plocate-updatedb.timer` | OPTIONAL | `locate` results can become stale. |
| Disable `mdmonitor`, RAID checks, LVM monitoring, or iSCSI services | SAFE only when the feature is unused | Never disable these based only on a guess. Detection can miss unusual storage setups or remote dependencies. |
| Enable `fstrim.timer` when it is disabled and an SSD is present | SAFE in normal supported setups | Periodic TRIM can help maintain SSD performance. Confirm the filesystem/storage stack supports the operation. |
| Cap the system journal at 500 MB | OPTIONAL | Older log history may be deleted or rotated sooner. Save logs externally if they are needed for troubleshooting. |

**Kept on purpose:** core networking, D-Bus, polkit, SELinux, firewalld, systemd-oomd, PipeWire/WirePlumber, the display manager, udisks2, and other services needed by the detected setup. The exact keep-list must match the current implementation; do not assume every listed unit is present on every Fedora installation.

### Packages (stage 5)

Potential removal groups include VM guest agents (only when not needed), ABRT, DrKonqi, KDE PIM/Akonadi, LibreOffice, KDE games, extra media apps, KDE Connect, remote/chat apps, rarely used utilities, printing extras, Plasma Browser Integration, Discover, Orca, unused Flatpak runtimes, and `dnf autoremove`.

Each group should be offered only when relevant packages are installed. Review the transaction before confirming it. `dnf remove --assumeno` can preview a transaction, but its output format can vary; if FedoraTweaks cannot parse the plan confidently, it should skip the operation rather than guess.

Protected-package checks are a second safety layer, not a replacement for reading the transaction. The implementation's `FT_PROTECTED_*` rules in `lib/common.sh` should be reviewed whenever a new removal group is added.

**Rollback limitation:** reinstalling removed package names is not a byte-for-byte rollback. It may not restore exact versions, dependencies, configuration files, user data, or packages that have disappeared from enabled repositories. Flatpak runtime cleanup and `dnf autoremove` can also remove dependencies that are later needed. Keep backups and review the proposed transaction.

**Discover:** keep it if you want a graphical interface for updates and Flatpaks. Without it, use the appropriate commands for your system, such as `sudo dnf upgrade --refresh` and `flatpak update`.

### KDE Plasma (stage 6)

| Change | Tier | Notes |
|---|---|---|
| Disable Baloo | OPTIONAL | Stops background file indexing. Searches that depend on the content index may become slower or less complete; filename search behavior depends on the application. |
| Start with an empty session | OPTIONAL | Avoids restoring previously open applications and may make startup more predictable. |
| Disable animations | OPTIONAL | Changes desktop feel; it is not expected to increase in-game FPS. |
| Disable blur/contrast effects | OPTIONAL | Cosmetic. Do not assume the compositor always bypasses composition for every fullscreen game or display setup. |
| Allow tearing in fullscreen | OPTIONAL | Can reduce presentation latency in supported configurations, at the cost of visible tearing. Test with the game's V-Sync, VRR, and frame cap settings. |
| Hide selected autostart entries | OPTIONAL | May disable notifications or integrations from Discover, KDE Connect, calendar/Akonadi components, GeoClue, accessibility tools, or other desktop services. Check each entry before hiding it. |
| Disable the splash screen after login | OPTIONAL | Cosmetic; usually no meaningful gaming performance change. |

**Mouse acceleration:** configure it in Plasma's input settings if desired. Device-specific settings can vary, so FedoraTweaks should not edit undocumented per-device keys without checking the active Plasma version and preserving the original state. Verify the result with the installed libinput tools when available.

**Not changed by default:** thumbnailers, kded modules, and widgets. Many run on demand, and disabling them without evidence may remove functionality without a measurable benefit.

---

## 4. AMD gaming

The benefit of these options depends on the exact CPU, GPU, driver, game, and workload. FedoraTweaks should not promise FPS gains from installing a package or changing a system setting.

| Item | Tier | Why / caveats |
|---|---|---|
| Install normal Fedora updates (kernel, Mesa, firmware) | SAFE, with normal update precautions | Updates can fix bugs and improve hardware support, but may also introduce regressions. Keep a known-good boot entry when possible. |
| Set `max_parallel_downloads=10` for DNF | OPTIONAL | May speed up downloads on fast connections. It is not a gaming optimization. |
| 32-bit Mesa Vulkan and `vulkan-tools` | SAFE for relevant gaming setups | Commonly needed for Steam/Proton and 32-bit applications. Confirm the correct packages for the Fedora release and enabled repositories. |
| GameMode | SAFE as an optional gaming tool | Can adjust selected system settings while a game runs. Gains are workload-dependent; use `gamemoderun %command%` where supported. |
| GameMode priority configuration | OPTIONAL | Higher process/I/O priority can affect responsiveness and fairness to other tasks. Do not enable elevated priority blindly; verify the actual configuration and permissions. |
| MangoHud | SAFE as a measurement tool | Displays/logs performance data. FPS limiter availability and key bindings depend on the config and MangoHud version. |
| RPM Fusion repositories | OPTIONAL | Useful for packages such as the native Steam RPM or Freeworld codecs. Repository setup and key handling must follow current Fedora/RPM Fusion instructions and the target release's package-signature policy. |
| Steam RPM | OPTIONAL | Native RPM alternative to the Flatpak. Check the current RPM Fusion instructions and dependencies for the Fedora release in use. |
| Lutris RPM | OPTIONAL | Can manage supported game launchers and Wine-based setups; compatibility varies by game and anti-cheat policy. |
| ProtonPlus and Heroic Flatpaks | OPTIONAL | ProtonPlus manages compatibility tools; Heroic is an open-source launcher for supported Epic/GOG/Amazon libraries. This does not imply that every game or anti-cheat system works on Linux. |
| `mesa-va-drivers-freeworld` | OPTIONAL | Can provide additional video codec support in supported configurations. This is not an FPS tweak, and package availability/compatibility must be checked. |
| Power profile `performance` | OPTIONAL | May increase power use, heat, and fan noise. Measure frame pacing and temperatures rather than assuming it improves performance. |
| zram sysctls (`swappiness`, `page-cluster`) | OPTIONAL / workload-dependent | Mainly relevant under memory pressure. Keep Fedora's zram setup unless testing shows a reason to change it. Avoid treating a specific value as universally optimal. |
| `ntsync` | OPTIONAL only if supported and needed | Availability and default behavior depend on kernel/package versions and the application. Verify actual device/module availability rather than assuming a Fedora version always enables it. |
| 3D V-Cache CCD preference on supported dual-CCD X3D CPUs | OPTIONAL | Applies only to particular CPUs and supported scheduler/driver configurations. Measure the target workload and confirm the setting is appropriate for the installed CPU. |
| Write-back limits (`vm.dirty_bytes`) | OPTIONAL | May change writeback bursts and system responsiveness, but can also reduce throughput. Use conservative values and test under actual workload. |
| PipeWire quantum 256 | OPTIONAL | Can lower audio buffering latency while increasing risk of crackles/underruns. The resulting latency depends on the sample rate and graph configuration; restore defaults if audio becomes unstable. |
| Mesa shader cache size | OPTIONAL | May help workloads with large shader caches, but cache behavior differs by launcher and driver. Do not claim Steam's cache is always entirely separate from Mesa's cache. |
| sched-ext schedulers such as `scx_lavd` | EXPERIMENTAL / NOT APPLIED | Scheduler results vary by hardware and workload. Test in the foreground, keep a recovery path, and retain it only if repeated measurements show a real improvement. |

**ReBAR / Smart Access Memory:** if the motherboard, firmware, CPU, and GPU support it, check BIOS options such as “Above 4G Decoding” and “Re-Size BAR” and verify the resulting state with suitable system diagnostics. Do not infer that a particular `BAR=` log line alone proves the feature is enabled. Memory profile names such as EXPO/XMP are firmware-specific; enable them only if the hardware is stable and you understand the warranty/stability trade-off.

**Fan control and overclocking:** FedoraTweaks does not enable GPU overdrive, custom fan curves, or overclocking automatically. These can increase heat, noise, instability, and power consumption. Any change that relies on `amdgpu.ppfeaturemask` or vendor-specific interfaces needs hardware-specific validation and a clear recovery plan.

### Not applied (and why)

- `mitigations=off`: weakens security protections for an uncertain workload-dependent gain.
- Disabling split-lock detection globally: only consider for a specific, diagnosed compatibility issue.
- Forcing `power_dpm_force_performance_level=high`: increases power/heat and is not a general frame-pacing fix.
- Custom kernels: can complicate Secure Boot, support, and future EAC Linux v2 compatibility. Do not claim every custom kernel necessarily breaks Secure Boot; the relevant point is whether the kernel and modules satisfy the required signing/trust policy.
- `iommu=pt`: not a general gaming optimization and may conflict with the intended isolation requirements for EAC Linux v2 on non-handheld systems.
- `kernel.nmi_watchdog=0` / `nowatchdog`: removes diagnostic/security monitoring for a performance effect that is usually difficult to measure in games.
- Transparent huge pages set to `always`: no consistent universal gaming gain; memory behavior and latency effects vary.
- TCP BBR / qdisc changes: may affect network throughput, but do not promise lower in-game ping.
- `noatime`: usually offers little benefit over typical Fedora filesystem defaults on SSDs.
- LACT and similar GPU tuning tools: not applied automatically because support, packaging, permissions, and overdrive behavior depend on the GPU and installation source.
- Random “gaming sysctl” bundles, disabling zram/journald/SELinux/firewalld, or turning off security features: omitted because they can reduce reliability/security without demonstrated benefit.

---

## 5. Fortnite and anti-cheat readiness

Epic's announcement, [“Awesome Gaming on Linux Without Cheating”](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2), published on 14 October 2026, says Fortnite is planned as the first pilot for EAC Linux v2. Epic describes a new Linux anti-cheat approach that uses existing platform security features and eBPF rather than an equivalent anti-cheat kernel module. The systemd service is intended to run only while a protected game is running.

### Requirements described by Epic

Epic's announcement lists the following requirements and notes that it expects to refine them:

- A signed kernel and signed kernel modules using keys on Epic's well-known list.
- TPM 2.0 enabled.
- Secure Boot enabled, using well-known keys.
- Measured boot.
- IOMMU enabled, with passthrough disabled on non-handheld systems.
- Kernel lockdown integrity mode explicitly enabled at boot.
- Kexec explicitly disabled at boot.
- BPF LSM active.

Epic's announcement lists the Fedora Secure Boot CA among well-known keys. It also warns that enrolled MOKs matter: a locally generated module-signing key is not automatically acceptable merely because it is enrolled. Consult Epic's current requirements and key list before changing Secure Boot or enrolling keys.

### Confirmed versus not yet confirmed

**Confirmed by Epic:** Fortnite is intended to pilot EAC Linux v2; the new solution does not use an equivalent anti-cheat kernel module; the documented requirements above are part of the initial proposal; Steam Deck is not supported by this solution yet; starting a protected game without meeting requirements should produce an error rather than an account ban.

**Not confirmed:** a public release date, whether Fortnite's eventual Linux path will be a native Linux build or Windows build through Proton, the final long-term requirements, and the exact verification mechanism for every setting. Epic explicitly says the requirements may evolve.

### What the readiness check can and cannot do

`./FedoraTweaks anticheat` should be presented as a **diagnostic/readiness aid**, not an official Epic validator and not a guarantee that Fortnite will launch. It can inspect local signals such as Secure Boot, TPM availability, IOMMU, lockdown, kernel command line, kexec configuration, and BPF LSM status. Some checks may be inconclusive because firmware, bootloader, kernel, and distribution versions differ.

If the tool offers to modify the kernel command line, it must show the exact proposed change, preserve existing arguments, explain the effect, and require explicit confirmation. In particular:

- `lockdown=integrity` should be added only after explaining that lockdown restricts certain kernel interfaces and may block unsigned modules or tools that write CPU MSRs.
- Disabling kexec at boot must be described as an interpretation of Epic's requirement and verified after reboot. Do not imply that a runtime sysctl change proves it was disabled from boot.
- The `lsm=` list is order- and distribution-sensitive. Do not replace it blindly or omit SELinux-related modules. If the tool cannot safely add BPF LSM without disrupting the existing list, it should report the issue and provide a manual review path instead.
- A command-line update may partially succeed or require a reboot. Report the actual outcome, provide recovery instructions, and rerun the diagnostic after reboot.
- Keep a separate, known-good boot entry where practical, and do not change Secure Boot keys or enroll a locally generated MOK casually.

### Suggested user workflow

1. Check the motherboard firmware for TPM 2.0/fTPM, Secure Boot, and IOMMU options. Names and defaults vary by vendor.
2. Update Fedora through its supported update path and keep the standard signed Fedora kernel unless there is a clear reason not to.
3. Run `./FedoraTweaks anticheat` and read every result; treat unknown/unavailable checks as inconclusive, not as proof of compliance.
4. Review any proposed boot-argument change before accepting it.
5. Reboot if changes were made, then run the diagnostic again.
6. Recheck Epic's official article and current game status before relying on the result.

Kernel lockdown can restrict unsigned module loading, access to physical memory, and CPU MSR writes. Some hardware monitoring, undervolting, hibernation, or tuning workflows may be affected. Verify which specific features are blocked on the current system instead of promising that all monitoring or gaming tools are unaffected.

---

## 6. Maintenance and contribution checklist

Before merging changes to FedoraTweaks:

- Check syntax with `bash -n FedoraTweaks lib/common.sh modules/*.sh`.
- Run ShellCheck on the entry point, common library, and modules.
- Test dry-run behavior and ensure it does not modify system state.
- Test cancellation, missing optional tools, unavailable sysfs files, non-KDE sessions, and missing services/packages.
- Confirm each mutating operation records enough prior state for its undo action.
- Confirm rollback handles files that did not exist before the change, as well as services that were already disabled or masked.
- Ensure DNF transaction parsing fails closed: uncertain output should stop the operation.
- Do not claim a setting improves FPS without repeatable measurements.
- Re-check Fedora version-specific package names, RPM Fusion instructions, and Epic's anti-cheat requirements before publishing.
- Update this document whenever the actual script's behavior changes. The documentation must describe what the code really does, not what it is intended to do.

## References

- Epic Online Services, [Awesome Gaming on Linux Without Cheating](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2), 14 October 2026.
- Fedora Project, [Fedora Linux 45 Beta announcement](https://fedoramagazine.org/announcing-fedora-linux-45-beta/).
- Fedora Project release information and current release validation announcements. Check the latest status before treating the target date as final.
