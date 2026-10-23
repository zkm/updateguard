# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

updateguard is a single bash script (`updateguard`) that hooks into the package manager: before risky updates it snapshots the system, and afterwards it verifies the machine will still boot, printing a `fix:` command for every failure. Arch/CachyOS (pacman) is the supported backend and the dogfooding platform; Debian/Ubuntu (apt) is in preview and has only run against simulated systems; Fedora/RHEL (dnf) is in preview and has only been checked read-only on a real Rocky 8 box. The intended paid product targets small IT shops' servers, so Debian/Ubuntu and then the RHEL family are the priority (see Roadmap in README.md).

## Commands

```bash
bash tests/run-tests.sh                          # full suite (~2s, no sudo); prints "N passed, M failed", exit 1 on any failure
bash tests/run-tests.sh | grep -v '^  ok '       # only section headers and failures
shellcheck updateguard tests/run-tests.sh install.sh   # must stay clean
./updateguard doctor                             # read-only, against this machine; needs sudo to see /boot on a 0700 ESP
makepkg -si                                      # Arch: build and install the package (PKGBUILD, sources are local files)
./install.sh                                     # plan only; sudo ./install.sh --apply installs pacman, apt or dnf hooks
```

There is no per-test selector: the suite is one script of numbered sections (`echo "== N. ..."`), each building a fresh fake root. The UKI section (13) needs `gcc` and `objcopy` and is skipped without them.

## Architecture

**One script, three families.** `FAMILY` (`arch` | `debian` | `rhel`) is resolved at startup from `/etc/os-release` (`detect_family`), overridable in `/etc/updateguard.conf`. Family-specific behaviour is isolated in small dispatch points rather than separate files: `load_kernels`, `check_kernel` → `check_kernel_debian`, `pkg_install_time`, `initramfs_list`, `load_patterns`, `boot_files`, and the `fix_*` helpers that produce pacman vs apt fix commands. Snapshots (snapper / snap-pac / raw btrfs), DKMS, boot-mount, bootloader-entry (systemd-boot/BLS, GRUB, Limine, UKIs) and running-kernel checks are shared.

**Kernel identity differs per family.** `KERNELS` holds `kver<TAB>package`: on Arch the package is the pkgbase from `/usr/lib/modules/<kver>/pkgbase` and boot files are named after it (`vmlinuz-linux-zen`, presets in `/etc/mkinitcpio.d/<pkgbase>.preset`); on Debian it's `linux-image-<kver>` confirmed via `/var/lib/dpkg/status` (removed kernels leave module dirs behind), and boot files are named after the kver (`/boot/vmlinuz-<kver>`, `/boot/initrd.img-<kver>`). On RHEL it's the NVRA of the rpm owning `/usr/lib/modules/<kver>/vmlinuz` (`kernel-core-<vra>`; not always `kernel-core-<kver>`, because debug kernels' kver ends in `+debug`). Boot files are `/boot/vmlinuz-<kver>` and `/boot/initramfs-<kver>.img`, and `rpm_devel_pkg` derives the `-devel` package from the NVRA.

**Hook flow.** `hook-pre` reads package names from stdin (pacman `NeedsTargets`, or apt `DPkg::Pre-Install-Pkgs` VERSION 2 with `--apt`), filters them against risky patterns, runs `pre_flow` (boot-mount check, snapshot, boot-partition backup) and writes a pending transaction id to `/run/updateguard/pending`. Exit 1 aborts the transaction, which only happens when `DRY_RUN=0`. `hook-post` runs `run_checks`, writes `report.tsv`/`report.json` under `/var/lib/updateguard/txn/<id>/`, and prints the "Do NOT reboot" verdict. apt's `DPkg::Post-Invoke` gets no package list, so the apt post hook relies entirely on the pending id. dnf 4 uses `dnf/updateguard.py`, which pipes `install_set`+`remove_set` names to `hook-pre`/`hook-post` and turns exit 1 into `dnf.exceptions.Error`. dnf5's actions plugin can only run a command once, or once per package, so `dnf/updateguard.actions` calls `hook-note <name>` per package. `hook-note` returns near the top of the script, before the rest is parsed, and appends to `$RUN_DIR/dnf-targets`. `hook-pre --dnf5` then reads that file. The actions plugin parses a hook's stdout as commands, so `--dnf5` sends all output to stderr.

**Risky-package patterns.** On Arch the `Target =` lines of `05-updateguard-pre.hook` are the single source of truth (also used by `simulate`); keep `zzz-updateguard-post.hook` in sync with them. On Debian they come from `DEBIAN_TARGETS` in the script, and on RHEL from `RHEL_TARGETS`. Those patterns are listed per kernel flavour so `kernel-headers`, `kernel-tools` and the like don't match. `EXCLUDE` in the config removes false matches.

**Reporting.** Every check goes through `emit LEVEL check-id message [fix]`; that one call drives the console output, the FAIL/WARN counters and the `check --json` report (the format meant for a future fleet dashboard). Keep check ids stable.

**Testability.** All filesystem paths are prefixed with `$R` (`UG_ROOT`), and `UG_CONF`, `UG_RUN_DIR`, `UG_HOOK_FILE`, `UG_NOW` are test-only overrides. `tests/stubs/` shadows `findmnt`, `btrfs`, `snapper`, `dkms`, `lsinitcpio`, `lsinitramfs`, `lsinitrd`, `rpm` (fake db in `$T_RPM_DB`), `uname`, `df` and `logger`, controlled by `T_*` environment variables (see the top of each stub). Fake initramfs images are plain-text file listings. When adding a check, add a section to `tests/run-tests.sh` that builds the fake system with `make_system` (Arch), `make_ubuntu`, `make_fedora` or `make_rocky` and asserts with `has` / `hasnt` / `rc_is`.

## Non-obvious constraints

- UKIs are verified by contents (`objcopy` extracts `.linux`, compared allowing zero padding), never by mtime: mkinitcpio builds UKIs with `objcopy -p`, which copies the systemd stub's mtime onto every UKI. Timestamp checks use the package manager's install time (pacman `desc` `%INSTALLDATE%`, dpkg `.list` mtime) with 2 s slack for FAT, not the kernel file's ctime.
- RHEL makes `/boot/loader/entries` 0700 and initramfs images 0600. An unreadable entries dir gives one `permissions` WARN and suppresses the "no boot entry" warnings. Unreadable images just skip the `lsinitrd` contents check.
- The dnf 4 plugin must stay Python 3.6 compatible (RHEL 8's platform-python) and must no-op when the binary is missing, for `--installroot`, and for `tsflags=test`.
- Ubuntu installs `/boot/vmlinuz-*` mode 0600; unreadable files must produce a `permissions` WARN pointing at `sudo updateguard check`, not a FAIL.
- The apt pre hook command's first word must match the `DPkg::Tools::Options::<path>::Version "2"` key in `apt/05updateguard`, and `install.sh` rewrites both paths together. A leftover apt hook pointing at a missing binary breaks apt, so uninstall removes the hook first.
- Everything defaults to `DRY_RUN=1`: report only, never snapshot or abort. Destructive actions (snapshots, prune, aborting the transaction) are gated on `DRY_RUN=0`.
- `site/` is the static landing page and icon; it isn't packaged. `.github/workflows/pages.yml` deploys it to GitHub Pages on pushes to `master`; `ci.yml` runs shellcheck, the suite and a version-string consistency check. `master` is the primary branch.
