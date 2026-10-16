# The optimization plan

This document explains the reasoning behind each stage of `./FedoraTweaks`. Every change it applies is listed here with its tier. Information is current as of **16 October 2026**: Fedora 45 is in final freeze with release targeted for 20 October, and it ships KDE Plasma 6.7, Linux 7.2 and enforced RPM signature checking.

**Tiers**

- **SAFE**: no functional loss on a typical gaming desktop, and fully reversible.
- **OPTIONAL**: you lose a feature, or the benefit depends on your use. Measure it.
- **EXPERIMENTAL / NOT APPLIED**: depends on your hardware, carries risk, or is a placebo. The tool explains it but does not apply it automatically.

---

## 1. Audit (read-only)

`./FedoraTweaks audit` runs these commands and saves the output to `~/.local/state/fedoratweaks/reports/`. You can also run them by hand:

| What | Command | What the output tells you |
|---|---|---|
| Release / kernel | `cat /etc/os-release`, `uname -r`, `rpm -q kernel-core` | Which release you run, whether the kernel is Fedora's signed build, and whether a reboot is pending |
| CPU | `lscpu`, `cat /sys/devices/system/cpu/amd_pstate/status` | `active` means amd-pstate-epp is in use, which is the right driver for Zen 2 and later |
| GPU / driver | `lspci -nnk \| grep -A3 VGA` | "Kernel driver in use: amdgpu" |
| ReBAR | `journalctl -k -b \| grep -i 'amdgpu.*BAR'` | Resizable BAR is on when `BAR=` is about equal to VRAM. It is off when BAR is 256M |
| Mesa / Vulkan | `rpm -q mesa-vulkan-drivers{,.i686}`, `vulkaninfo --summary` | RADV version, and whether the 32-bit driver is present |
| RAM | `sudo dmidecode -t memory` | "Configured Memory Speed" should match your EXPO rating |
| Storage / board | `lsblk -o NAME,SIZE,FSTYPE,MODEL`, `/sys/class/dmi/id/*` | Filesystems, board model, BIOS version and date |
| Plasma | `plasmashell --version`, `echo $XDG_SESSION_TYPE` | Plasma version, and that the session is `wayland` |
| Packages | `rpm -qa \| wc -l`, `dnf group list --installed`, `dnf repolist` | Installed footprint and enabled repositories |
| Services | `systemctl list-unit-files --state=enabled`, `systemctl list-timers` | What starts at boot and what runs on a schedule |
| Autostart | `ls /etc/xdg/autostart ~/.config/autostart` | Session startup apps |
| Resources | `free -m`, `ps -eo rss,comm --sort=-rss \| head` | RAM use and the heaviest processes |
| Boot | `systemd-analyze`, `systemd-analyze blame` | Firmware, loader, kernel and userspace time, and the slowest units |
| Security | `mokutil --sb-state`, `getenforce`, `cat /sys/kernel/security/lockdown` | Secure Boot, SELinux and lockdown state |

## 2. Baseline and testing method

- **Idle metrics** (`baseline`): reboot, log in, start only a terminal and wait 2 minutes. The tool records RAM used (MemTotal − MemAvailable), CPU busy % over 30 s, userspace process count, running services, boot phases (from systemd's monotonic timestamps), and idle temperatures, clocks and power.
- **Gaming metrics**: use MangoHud logging (Shift_L+F2, 60 s). Run the same scene, settings and resolution, with no other apps open, **3+ runs per configuration**. `./FedoraTweaks bench *.csv` reports average FPS, 1% and 0.1% lows (the mean of the slowest 1% / 0.1% of frames), frametime stdev and the 99th percentile frame time. A difference smaller than the spread between runs is noise.
- **Input latency** cannot be measured reliably in software. If it matters to you, use an LDAT or a high-speed camera. The settings that actually reduce latency are covered in stage 6 (tearing) and the FPS-cap advice below.
- This project includes **no invented benchmark numbers**. Your measurements are the only evidence.

## 3. Fedora and KDE debloat

### Services (stage 4)

| Change | Tier | What you lose |
|---|---|---|
| Disable CUPS and cups-browsed | OPTIONAL | Printing |
| Mask Avahi | OPTIONAL | Network printer/scanner discovery and `.local` names |
| Mask Bluetooth | OPTIONAL | BT controllers and headsets (keep it if you use them) |
| Mask ModemManager | SAFE if no modem, otherwise OPTIONAL | WWAN/LTE modems |
| Disable NetworkManager-wait-online | OPTIONAL | Very early network mounts. Boot time improves measurably |
| Disable dnf-makecache.timer | OPTIONAL | Nothing. dnf refreshes metadata on demand |
| Disable plocate-updatedb.timer | OPTIONAL | `locate` results go stale |
| mdmonitor / raid-check / lvm2-monitor / iSCSI | SAFE when unused | Nothing (they are only offered when no RAID, LVM or iSCSI is detected) |
| Enable `fstrim.timer` (if it is off and you have an SSD) | SAFE | Nothing. Weekly TRIM keeps SSD write speed steady |
| Cap the system journal at 500 MB | OPTIONAL | Log history beyond 500 MB |

**Kept on purpose:** NetworkManager, systemd-resolved, D-Bus, polkit, SELinux, firewalld, systemd-oomd, PipeWire/WirePlumber, chronyd, fwupd, tuned-ppd, smartd, the display manager, udisks2, switcheroo-control and sssd.

### Packages (stage 5)

The tool offers these groups, but only if they are installed: VM guest agents (SAFE on bare metal), ABRT, DrKonqi, KDE PIM/Akonadi, LibreOffice, KDE games, extra media apps, KDE Connect, remote/chat apps, rarely used utilities, printing extras, Plasma Browser Integration, Discover, Orca, unused Flatpak runtimes (`flatpak uninstall --unused`, SAFE) and `dnf autoremove`.

Safety mechanism: `dnf remove --assumeno` previews the transaction first. The group is skipped if dnf's plan can't be parsed with certainty, or if it includes a protected package (see `FT_PROTECTED_*` in `lib/common.sh`). Rollback reinstalls exactly the packages that were removed.

**Discover**: keep it if you like a GUI for updates and Flatpaks. Without it, update with `sudo dnf upgrade --refresh` and `flatpak update`.

### KDE Plasma (stage 6)

| Change | Tier | Notes |
|---|---|---|
| Disable Baloo | OPTIONAL | Stops background file indexing, which is heavy after large game installs. Filename search still works |
| Empty session at login | OPTIONAL | Gives predictable idle RAM |
| Animations off | OPTIONAL | Snappier desktop. No effect in games |
| Blur/contrast off | OPTIONAL | Cosmetic. KWin bypasses compositing for fullscreen games anyway |
| Allow tearing in fullscreen | OPTIONAL | **Real latency reduction** when the game's V-Sync is off. Pair it with VRR and an FPS cap a few FPS below the refresh rate |
| Hide autostart entries | OPTIONAL | Discover notifier, KDE Connect, kalendarac (starts Akonadi), GeoClue agent, ABRT applet, kaccess, gmenudbusmenuproxy |
| No splash screen after login | OPTIONAL | The desktop appears as soon as it is ready |

**Mouse acceleration:** set it by hand in System Settings › Mouse & Touchpad (profile "None"/flat). It isn't scripted, because Plasma stores it per device under undocumented keys. Check the result with `sudo libinput list-devices`.

**Not changed:** thumbnailers, kded modules and widgets. They run only on demand, and changing them gives no measurable benefit.

## 4. AMD gaming

| Item | Tier | Why |
|---|---|---|
| Updates (kernel, Mesa, linux-firmware) | SAFE | The biggest real gains for new GPUs come from newer RADV and amdgpu, and Fedora ships them quickly |
| `max_parallel_downloads=10` for dnf | OPTIONAL | Faster updates on fast connections. Not a gaming change |
| 32-bit Mesa Vulkan + vulkan-tools | SAFE | Required by Steam, Proton and 32-bit games |
| GameMode | SAFE | Small, situational gain. Use `gamemoderun %command%` |
| GameMode config (`renice=10`, `ioprio=0`) + `gamemode` group | OPTIONAL | Higher CPU/I/O priority for the game only while it runs. GPU tuning stays off |
| MangoHud | SAFE | Measurement tool. Use `mangohud %command%`. The config includes an FPS limiter (Shift_L+F1) for VRR caps |
| RPM Fusion free + nonfree | OPTIONAL | Only needed for the native Steam RPM and freeworld codecs. Keys come from Fedora's `distribution-gpg-keys`, because Fedora 45 enforces RPM signatures |
| Steam (RPM Fusion nonfree) | OPTIONAL | Native RPM, as requested. Flathub's Flatpak is the alternative |
| Lutris (Fedora RPM) | OPTIONAL | Battle.net, EA app, Ubisoft Connect, emulators |
| Full Flathub + ProtonPlus + Heroic (Flatpak) | OPTIONAL | Proton-GE builds and an open-source Epic/GOG launcher |
| mesa-va-drivers-freeworld | OPTIONAL | H.264/HEVC hardware video for OBS and Remote Play. Not an FPS change |
| Power profile `performance` | OPTIONAL | Costs idle power. The gain is usually small; measure 1% lows |
| zram sysctls (swappiness 180, page-cluster 0) | OPTIONAL | Only matters under memory pressure. Keep Fedora's zram |
| ntsync | OPTIONAL | Proton uses it if present. Fedora 44+ loads it by default, so it is only offered when missing |
| 3D V-Cache mode `cache` (dual-CCD X3D CPUs only) | OPTIONAL | Scheduler prefers the cache CCD. The gain is workload-dependent (Phoronix); measure |
| Write-back limits (`vm.dirty_bytes` 256 MB) | OPTIONAL | Avoids multi-GB flush bursts (downloads, installs) that can hitch a running game |
| PipeWire default quantum 256 (≈5 ms) | OPTIONAL | Lower audio latency. Roll back or use 512 if it crackles |
| Mesa shader cache 10 GB | OPTIONAL | For non-Steam launchers. Steam manages its own shader cache |
| sched-ext (scx_lavd and others) | EXPERIMENTAL | Try it in the foreground with `sudo scx_lavd`, and press Ctrl+C to revert. Keep it only if 1% lows improve across runs |

**ReBAR / Smart Access Memory:** turn on "Above 4G Decoding" and "Re-Size BAR" in the BIOS, then confirm with the audit. On a Ryzen + Radeon system it is usually worth it. **EXPO** should also be enabled. Linux tweaks can't replace either of these firmware settings.

**Fan control:** the default firmware fan curve is fine. Custom curves and overclocking need `amdgpu.ppfeaturemask` (overdrive). That is not applied, because it can destabilize the system and flag the kernel as out-of-spec/tainted.

### Not applied (and why)

- `mitigations=off`: you lose security for little gain on Zen.
- Disabling split-lock detection: only for specific games that trigger split locks, and then only by hand.
- Forcing `power_dpm_force_performance_level=high`: more heat and power, and no gain in frame pacing.
- Custom kernels (CachyOS, Zen, XanMod): they break Secure Boot and EAC Linux v2. Fedora's kernel is already current.
- `iommu=pt`: conflicts with EAC Linux v2, and no gaming benefit.
- `kernel.nmi_watchdog=0` / `nowatchdog`: frees one performance counter. The effect on games is below measurement noise.
- Transparent hugepages `always`: no consistent gaming gain, and compaction can add latency spikes. Fedora's `madvise` lets programs opt in.
- TCP BBR / qdisc changes: these affect bulk downloads, not in-game ping.
- `noatime`: negligible on Fedora's relatime + Btrfs + SSD defaults.
- LACT (GPU fan curves and overclocking): it is only available from an unofficial COPR or as a Flatpak, and it needs overdrive. Install it yourself if you want it.
- Random "gaming sysctl" bundles, I/O scheduler changes, disabling zram/journald/SELinux/firewalld: placebo or harmful.

## 5. Fortnite and anti-cheat readiness

**Confirmed** in Epic's [EAC Linux v2 announcement](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2) of 14 Oct 2026:

- Fortnite is coming to Linux and will pilot EAC Linux v2.
- EAC Linux v2 uses no kernel module. It runs a systemd service only while a protected game runs, and uses eBPF.
- Requirements: a signed kernel and signed modules using well-known keys, TPM 2.0, Secure Boot, measured boot, IOMMU on with passthrough off, `lockdown=integrity` set explicitly at boot, kexec disabled at boot, and the BPF LSM active.
- The *Fedora Secure Boot CA* is on the well-known key list. Every enrolled MOK must also be well-known, so a locally generated akmods key fails.
- You may keep a separate boot entry for protected games. Starting a game without meeting the requirements shows an error; it does not get you banned.
- Steam Deck is not supported yet.

**Not confirmed:** a release date, the final requirements (Epic says it will iterate on them), whether Fortnite will run natively or through Proton, and exactly how each requirement is verified (for example, how "kexec disabled" is detected). The tool sets kexec through the kernel parameter `sysctl.kernel.kexec_load_disabled=1`. That is our reading of the requirement, not Epic's specification.

**Related:** Epic's launcher page lists a native Linux launcher (AppImage) that supports Fedora 43 and newer: https://launcher.epicgames.com/

**On an all-AMD Fedora system** most requirements are already met by default: Fedora's signed kernel, no out-of-tree drivers, and shim/GRUB measured boot. What you usually need to do yourself:

1. In the BIOS, enable Secure Boot (default keys), fTPM and IOMMU.
2. Run `./FedoraTweaks anticheat`, and let it add `lockdown=integrity` and `sysctl.kernel.kexec_load_disabled=1` (plus `bpf` to `lsm=` if it is missing).
3. Reboot and run the check again.

Lockdown blocks unsigned modules, hibernation, `/dev/mem` and MSR writes (ryzenadj, some undervolting tools). Gaming, Steam/Proton, MangoHud and amdgpu sysfs monitoring are unaffected.
