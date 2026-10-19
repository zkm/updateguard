# updateguard

Snapshot before risky OS updates, then verify the machine will still boot
before you reboot. v0.2.0: Arch and CachyOS (pacman), plus Debian and Ubuntu
(apt) in preview. (Name is a placeholder; check the AUR and GitHub before
publishing.)

## What it does

**Before** a transaction that touches the kernel, DKMS, NVIDIA, mkinitcpio,
the bootloader, systemd, glibc, microcode, or storage tools:

- Refuses to proceed if `/boot` (or `/efi`) is in fstab but not mounted.
  This is the classic Arch failure: the new kernel lands on the root
  filesystem and the bootloader keeps loading the old one.
- Takes a snapshot of `/`: snapper config `root` if you have one (or records
  snap-pac's snapshot if snap-pac is installed), otherwise a read-only raw
  btrfs snapshot.
- Copies kernel and initramfs off a separate boot partition. Root snapshots
  don't include them, so without this a rollback pairs a new kernel with old
  modules.

**After** every other hook has run (mkinitcpio, dkms, bootloader):

| Check | Catches |
|---|---|
| `/boot/vmlinuz-*` byte-matches `/usr/lib/modules/<kver>/vmlinuz` | stale kernel on /boot |
| initramfs exists, is newer than the kernel, contains `lib/modules/<kver>` | initramfs not regenerated, or built for the wrong kernel |
| each UKI's embedded `.linux` matches the installed kernel (needs `objcopy`) | UKI not rebuilt |
| headers present and every DKMS module `installed` for every kernel | NVIDIA/ZFS/v4l2loopback not built, so a black screen on reboot |
| systemd-boot, GRUB and Limine entries point at files that exist | broken or stale boot entries |
| boot partition free space | full ESP truncating initramfs writes |
| running kernel's modules still on disk | "reboot soon" notice |

Every failure comes with the command that fixes it. If anything fails, the
hook says **don't reboot** and points at `updateguard rollback-help`.

## Install

Arch / CachyOS:

```bash
git clone https://github.com/zkm/updateguard.git && cd updateguard
bash tests/run-tests.sh          # optional: 114 checks against fake systems
makepkg -si                      # or: ./install.sh, then sudo ./install.sh --apply
sudo updateguard doctor
```

It starts in **dry run** (`DRY_RUN=1` in `/etc/updateguard.conf`): checks
run and report, but nothing is snapshotted and pacman is never aborted.
After a kernel update or two looks right, set `DRY_RUN=0`.

Debian / Ubuntu (preview):

```bash
git clone https://github.com/zkm/updateguard.git && cd updateguard
sudo ./install.sh --apply        # binary to /usr/local/bin, hooks to /etc/apt/apt.conf.d/05updateguard
sudo updateguard doctor
```

On apt systems the checks are the same idea with Debian's layout: the kernel
in `/boot/vmlinuz-<kver>` must match dpkg's recorded md5sum, and
`/boot/initrd.img-<kver>` must be newer than the kernel package and contain its
modules (`lsinitramfs`). The pre hook runs from `DPkg::Pre-Install-Pkgs` and
can abort apt; the post hook runs from `DPkg::Post-Invoke`, after
update-initramfs, update-grub and DKMS. Uninstall with
`sudo ./install.sh --uninstall` (removing only the binary would break apt).

## Commands

```
updateguard doctor              what it detects here, then a health check
updateguard check [--json]      health check (exit 1 on failure)
updateguard simulate PKG...     what the hooks would do for PKG... (always dry run)
updateguard status              recent transactions
updateguard rollback-help [ID]  exact rollback commands for a transaction
updateguard prune               delete snapshots/boot backups beyond KEEP
```

`check --json` is the agent's report format for the future dashboard.

## Notes and limits

- Rollback is printed instructions, not automatic. Auto-rollback comes after
  the checks have proven themselves on real updates.
- If fstab pins `/` by `subvolid=`, `doctor` tells you to drop it. A restored
  snapshot gets a new subvolume ID.
- On Arch, dracut, booster and kernel-install layouts get boot-entry checks
  but not the /boot image checks yet. RHEL-family distros aren't supported yet.
- A DKMS module that deliberately excludes a kernel (`BUILD_EXCLUSIVE`) will
  show as a failure for that kernel.
- UKIs are verified by contents, not timestamps. mkinitcpio builds UKIs with
  `objcopy -p`, which gives every UKI the systemd stub's mtime, so a freshly
  built UKI can look older than the kernel inside it. Without `objcopy`,
  updateguard falls back to timestamps and may report false failures.
- Tested against simulated systems (`tests/`) and one real Arch machine
  (systemd-boot, UKI-only, `linux` + `linux-zen`). The Debian/Ubuntu backend
  has only run against simulated systems. Run `doctor` and stay in
  dry run until it matches what you know about the machine.

## Roadmap

The paid product targets small IT shops' servers, so Debian/Ubuntu comes
first, then the RHEL family. Arch stays the dogfooding platform.

1. **Debian / Ubuntu** (in progress): apt hooks, dpkg-based kernel checks,
   initramfs-tools, GRUB. Next: test on real 22.04/24.04 and Debian 12 VMs,
   a `.deb` package (its apt hook must be removed on `apt remove`, not just
   purge), and rollback for ext4 servers (LVM snapshots or timeshift), since
   most of them have no btrfs.
2. **RHEL family** (Rocky, Alma, Fedora): dnf plugin, dracut (`lsinitrd`),
   `kernel-install` and BLS entries, snapper on Fedora's btrfs.
3. **Fleet reporting**: `check --json` from every machine to a dashboard, with
   alerts when a server shouldn't be rebooted.
4. **Automatic rollback**, once the checks have proven themselves on real
   updates.

## Development

```bash
bash tests/run-tests.sh          # fake Arch and Ubuntu systems under a temp root; no sudo needed
shellcheck updateguard tests/run-tests.sh install.sh
```

## License

MIT. See [LICENSE](LICENSE).
