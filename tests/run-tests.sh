#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() always succeeds, so `test && ok || bad` is safe
# Runs updateguard against fake Arch/CachyOS root filesystems with stubbed
# findmnt/btrfs/snapper/dkms/lsinitcpio/uname/df. Touches nothing outside a temp dir.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
UG="$HERE/../updateguard"
HOOK="$HERE/../05-updateguard-pre.hook"
export PATH="$HERE/stubs:$PATH"
KVER=6.11.1-zen1-1-zen
PASS=0 FAIL=0 OUT="" RC=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       | /'; }
has()  { [[ $OUT == *"$1"* ]] && ok "$2" || bad "$2 (expected: $1)"; }
hasnt(){ [[ $OUT != *"$1"* ]] && ok "$2" || bad "$2 (unexpected: $1)"; }
rc_is(){ [[ $RC == "$1" ]] && ok "$2" || bad "$2 (rc=$RC, want $1)"; }

run() { # [stdin-text] -- args...
  local input=$1; shift
  OUT=$(printf '%s' "$input" | env UG_ROOT="$ROOT" UG_HOOK_FILE="$HOOK" UG_CONF="$ROOT/etc/updateguard.conf" \
        UG_RUN_DIR="$ROOT/run/updateguard" "$UG" "$@" 2>&1); RC=$?
}

# make_system: an Arch box with linux-zen, separate vfat /boot, systemd-boot, nvidia-dkms
make_system() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ugtest.XXXXXX")
  mkdir -p "$ROOT"/{etc/mkinitcpio.d,boot/loader/entries,boot/EFI/systemd,run,var/lib}
  mkdir -p "$ROOT/usr/lib/modules/$KVER/build"
  printf 'linux-zen\n' >"$ROOT/usr/lib/modules/$KVER/pkgbase"
  printf 'KERNEL-%s\n' "$KVER" >"$ROOT/usr/lib/modules/$KVER/vmlinuz"
  cat >"$ROOT/etc/fstab" <<EOF
UUID=1111-2222-3333 /     btrfs rw,relatime,subvolid=256,subvol=/@ 0 0
UUID=ABCD-1234      /boot vfat  rw,relatime,fmask=0022,dmask=0022 0 2
EOF
  cat >"$ROOT/etc/mkinitcpio.d/linux-zen.preset" <<'EOF'
ALL_kver="/boot/vmlinuz-linux-zen"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux-zen.img"
fallback_image="/boot/initramfs-linux-zen-fallback.img"
fallback_options="-S autodetect"
EOF
  cp "$ROOT/usr/lib/modules/$KVER/vmlinuz" "$ROOT/boot/vmlinuz-linux-zen"
  printf 'usr/lib/modules/%s/kernel/drivers/x.ko\n' "$KVER" >"$ROOT/boot/initramfs-linux-zen.img"
  cp "$ROOT/boot/initramfs-linux-zen.img" "$ROOT/boot/initramfs-linux-zen-fallback.img"
  printf 'ucode\n' >"$ROOT/boot/amd-ucode.img"
  : >"$ROOT/boot/EFI/systemd/systemd-bootx64.efi"
  cat >"$ROOT/boot/loader/entries/arch-zen.conf" <<'EOF'
title   Arch Linux (zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=UUID=1111-2222-3333 rw rootflags=subvol=@
EOF
  printf 'nvidia/560.35.03, %s, x86_64: installed\n' "$KVER" >"$ROOT/dkms.txt"
  export T_DKMS_FILE="$ROOT/dkms.txt" T_MOUNTED="/boot" T_FSTYPE=btrfs T_SNAPPER=0
  export T_SOURCE="/dev/nvme0n1p2[/@]" T_UNAME_R=$KVER T_DF_AVAIL=400 T_BTRFS_FAIL=0
}
conf() { printf '%s\n' "$@" >"$ROOT/etc/updateguard.conf"; }

echo "== 1. healthy system, dry run (defaults)"
make_system
run "linux-zen" hook-pre;  rc_is 0 "pre exits 0"
has "[dry run]" "pre announces dry run"
has "would take a btrfs snapshot" "picks raw btrfs backend"
has "would copy" "plans a boot backup"
[[ ! -d $ROOT/.updateguard-snapshots ]] && ok "dry run took no snapshot" || bad "dry run took no snapshot"
run "linux-zen" hook-post; rc_is 0 "post exits 0"
has "vmlinuz-linux-zen matches installed kernel" "kernel image verified"
has "initramfs-linux-zen.img is current" "initramfs verified"
has "DKMS modules installed (nvidia)" "dkms verified"
has "systemd-boot (/boot/loader/entries, 1 entries)" "systemd-boot detected"
has "boot looks healthy" "healthy summary"
hasnt "[FAIL]" "no failures"
compgen -G "$ROOT/var/lib/updateguard/txn/*/report.json" >/dev/null && ok "report.json written" || bad "report.json written"

echo "== 2. firefox only: hooks stay silent"
run "firefox" hook-pre; rc_is 0 "pre exits 0"
[[ -z $OUT ]] && ok "no output for non-risky package" || bad "no output for non-risky package"
run "" simulate firefox linux-zen linux-api-headers nvidia-dkms
has "risky   linux-zen" "linux-zen risky"
has "ignored linux-api-headers" "linux-api-headers excluded"
has "risky   nvidia-dkms" "nvidia-dkms risky"
has "ignored firefox" "firefox ignored"

echo "== 3. stale kernel on /boot (e.g. /boot wasn't mounted during the update)"
make_system
printf 'OLD-KERNEL\n' >"$ROOT/boot/vmlinuz-linux-zen"
run "" check; rc_is 1 "check exits 1"
has "doesn't match installed kernel $KVER" "stale kernel detected"
has "sudo pacman -S linux-zen" "fix suggested"

echo "== 4. /boot in fstab but not mounted"
make_system; export T_MOUNTED=""
run "linux-zen" hook-pre; rc_is 0 "dry run never aborts"
has "NOT mounted" "unmounted /boot reported"
has "would be aborted" "dry run says it would abort"
conf DRY_RUN=0
run "linux-zen" hook-pre; rc_is 1 "active mode aborts the transaction"
has "ABORTING" "abort message shown"
[[ ! -e $ROOT/run/updateguard/pending ]] && ok "no pending txn left after abort" || bad "no pending txn left after abort"

echo "== 5. new kernel without headers, DKMS module missing"
make_system
rm -rf "$ROOT/usr/lib/modules/$KVER/build"
run "" check; rc_is 1 "check exits 1"
has "has no headers" "missing headers detected"
has "sudo pacman -S linux-zen-headers && sudo dkms autoinstall -k $KVER" "headers fix suggested"
make_system
printf 'nvidia/560.35.03: added\n' >"$ROOT/dkms.txt"
run "" check; has "DKMS module(s) not installed: nvidia" "unbuilt dkms module detected"
make_system
printf 'nvidia, 560.35.03, %s, x86_64: installed\n' "$KVER" >"$ROOT/dkms.txt"
run "" check; has "DKMS modules installed (nvidia)" "old dkms status format parsed"

echo "== 6. initramfs problems"
make_system
touch -d '2020-01-01' "$ROOT/boot/initramfs-linux-zen.img"
run "" check; has "older than the installed kernel" "stale initramfs detected"
make_system
printf 'usr/lib/modules/6.10.9-zen1-1-zen/kernel/x.ko\n' >"$ROOT/boot/initramfs-linux-zen.img"
run "" check; has "built for a different kernel" "wrong-kernel initramfs detected"
make_system
: >"$ROOT/boot/initramfs-linux-zen-fallback.img"
run "" check; has "fallback.img is missing or empty" "empty fallback image detected"

echo "== 7. active mode: snapshot, boot backup, rollback help, prune"
make_system; conf DRY_RUN=0 KEEP=2
export UG_NOW=20261018-080000
run "linux-zen" hook-pre; rc_is 0 "pre exits 0"
has "Took btrfs snapshot: /.updateguard-snapshots/20261018-080000" "snapshot taken"
[[ -f $ROOT/var/lib/updateguard/boot/20261018-080000/boot/vmlinuz-linux-zen ]] && ok "kernel backed up" || bad "kernel backed up"
[[ ! -f $ROOT/var/lib/updateguard/boot/20261018-080000/boot/initramfs-linux-zen-fallback.img ]] && ok "fallback skipped by default" || bad "fallback skipped by default"
run "linux-zen" hook-post; rc_is 0 "post exits 0"
run "" rollback-help
has "mount -o subvolid=5 UUID=1111-2222-3333 /mnt" "rollback mounts top-level by UUID"
has "mv /mnt/@ /mnt/@.broken-20261018-080000" "rollback renames broken root"
has "btrfs subvolume snapshot /mnt/@.broken-20261018-080000/.updateguard-snapshots/20261018-080000 /mnt/@" "rollback restores snapshot"
has "drop subvolid=" "warns about fstab subvolid"
has "mount UUID=ABCD-1234 /mnt-boot" "rollback restores boot files"
for t in 20261018-090000 20261018-100000; do UG_NOW=$t run "linux-zen" hook-pre; run "linux-zen" hook-post; done
n=$(find "$ROOT/.updateguard-snapshots" -mindepth 1 -maxdepth 1 | wc -l)
[[ $n == 2 ]] && ok "prune keeps KEEP=2 snapshots" || bad "prune keeps KEEP=2 snapshots (have $n)"
run "" status; has "OK" "status lists results"
unset UG_NOW

echo "== 8. snapper and snap-pac"
make_system; conf DRY_RUN=0; export T_SNAPPER=1
run "linux-zen" hook-pre; has "Took snapper snapshot: 42" "snapper backend used"
mkdir -p "$ROOT/usr/share/libalpm/hooks"; : >"$ROOT/usr/share/libalpm/hooks/05-snap-pac-pre.hook"
run "linux-zen" hook-pre; has "snap-pac took the pre-update snapshot (snapper #41)" "defers to snap-pac"

echo "== 9. ext4 root: verify only"
make_system; conf DRY_RUN=0; export T_FSTYPE=ext4 T_SOURCE=/dev/sda2
run "linux-zen" hook-pre; rc_is 0 "pre exits 0"
has "No snapshot backend" "explains no snapshots"
hasnt "boot files" "no boot backup without a snapshot"

echo "== 10. GRUB with btrfs subvolume paths, /boot on root"
make_system
rm -rf "$ROOT/boot/loader" "$ROOT/boot/EFI"
sed -i '/\/boot /d' "$ROOT/etc/fstab"; export T_MOUNTED=""
mkdir -p "$ROOT/boot/grub"
cat >"$ROOT/boot/grub/grub.cfg" <<'EOF'
menuentry 'Arch Linux, with Linux linux-zen' --class arch {
	linux	/@/boot/vmlinuz-linux-zen root=UUID=1111 rw rootflags=subvol=@
	initrd	/@/boot/amd-ucode.img /@/boot/initramfs-linux-zen.img
}
menuentry 'Arch Linux, with Linux linux-lts' --class arch {
	linux	/@/boot/vmlinuz-linux-lts root=UUID=1111 rw
}
EOF
run "" check
has "GRUB (/boot/grub/grub.cfg, 2 entries)" "GRUB detected"
has "/boot lives on the root filesystem" "no separate /boot handled"
has "points to /@/boot/vmlinuz-linux-lts, which doesn't exist (stale entry?)" "stale GRUB entry warned"
hasnt "No boot entry found for linux-zen" "subvolume-prefixed path resolved"
run "linux-zen" simulate linux-zen
has "the snapshot already covers them" "no boot backup needed when /boot is on root"

echo "== 11. CachyOS-style Limine on the ESP at /boot"
make_system
rm -rf "$ROOT/boot/loader" "$ROOT/boot/EFI"
mkdir -p "$ROOT/boot/abc123/linux-zen"
cp "$ROOT/boot/vmlinuz-linux-zen" "$ROOT/boot/abc123/linux-zen/vmlinuz-linux-zen"
cp "$ROOT/boot/initramfs-linux-zen.img" "$ROOT/boot/abc123/linux-zen/initramfs-linux-zen.img"
cat >"$ROOT/boot/limine.conf" <<'EOF'
timeout: 5
/+CachyOS
//linux-zen
    protocol: linux
    kernel_path: boot():/abc123/linux-zen/vmlinuz-linux-zen
    module_path: boot():/abc123/linux-zen/initramfs-linux-zen.img
    cmdline: root=UUID=1111 rw
//Windows
    protocol: efi
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
EOF
run "" check; rc_is 0 "check passes"
has "Limine (/boot/limine.conf, 3 entries)" "Limine detected"
hasnt "No boot entry found" "limine kernel entry matched"
printf '    kernel_path: boot():/abc123/linux-zen/vmlinuz-linux-zen-old\n' >>"$ROOT/boot/limine.conf"
run "" check; has "vmlinuz-linux-zen-old, which doesn't exist" "missing limine path warned"

echo "== 12. JSON output, doctor, low ESP space, reboot notice"
make_system; export T_DF_AVAIL=20 T_UNAME_R=6.10.9-zen1-1-zen
run "" check --json
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["tool"]=="updateguard" and isinstance(d["checks"],list)'; then ok "valid JSON"; else bad "valid JSON"; fi
has '"check":"boot-space"' "low ESP space reported in JSON"
has '"check":"reboot"' "replaced running kernel reported"
run "" doctor
has "DRY RUN" "doctor shows mode"
has "raw btrfs" "doctor shows backend"
has "linux-zen $KVER (preset ok, headers)" "doctor lists kernel"
has "remove subvolid=" "doctor notes fstab subvolid"
has "Health check:" "doctor runs check"

echo "== 13. UKIs (real PE files) and pacman install date"
make_system
rm -rf "$ROOT/boot/loader"; mkdir -p "$ROOT/boot/EFI/Linux"
cat >"$ROOT/etc/mkinitcpio.d/linux-zen.preset" <<'EOP'
ALL_kver="/boot/vmlinuz-linux-zen"
PRESETS=('default')
default_uki="/boot/EFI/Linux/arch-linux-zen.efi"
EOP
mkuki() { # KERNELFILE INITRDFILE OUT
  local w; w=$(mktemp -d "${TMPDIR:-/tmp}/ugpe.XXXXXX")
  echo 'int efi_main(void){return 0;}' >"$w/s.c"
  gcc -nostdlib -static -Wl,-e,efi_main -o "$w/s.elf" "$w/s.c" && objcopy -O pei-x86-64 "$w/s.elf" "$w/s.efi" &&
  objcopy --add-section .linux="$1" --change-section-vma .linux=0x2000000 \
          --add-section .initrd="$2" --change-section-vma .initrd=0x3000000 "$w/s.efi" "$3"
  local rc=$?; rm -rf "$w"; return $rc
}
if command -v gcc >/dev/null && command -v objcopy >/dev/null; then
  mkuki "$ROOT/usr/lib/modules/$KVER/vmlinuz" "$ROOT/boot/initramfs-linux-zen.img" "$ROOT/boot/EFI/Linux/arch-linux-zen.efi"
  touch -d '2020-01-01' "$ROOT/boot/EFI/Linux/arch-linux-zen.efi"   # old mtime, right contents
  run "" check
  has "arch-linux-zen.efi contains installed kernel $KVER" "UKI verified by contents, not mtime"
  hasnt "older than the installed kernel" "no timestamp false positive"
  has "UKIs (/boot/EFI/Linux, 1 images)" "UKI detected"
  printf 'OTHER-KERNEL\n' >"$ROOT/k2"
  mkuki "$ROOT/k2" "$ROOT/boot/initramfs-linux-zen.img" "$ROOT/boot/EFI/Linux/arch-linux-zen.efi"
  run "" check; has "contains a different kernel than installed" "stale UKI kernel detected"
  printf 'usr/lib/modules/6.1.0-old/x.ko\n' >"$ROOT/i2"
  mkuki "$ROOT/usr/lib/modules/$KVER/vmlinuz" "$ROOT/i2" "$ROOT/boot/EFI/Linux/arch-linux-zen.efi"
  run "" check; has "its initramfs was built for a different one" "stale UKI initramfs detected"
else
  echo "  skip UKI tests (need gcc + objcopy)"
fi
make_system
mkdir -p "$ROOT/var/lib/pacman/local/linux-zen-6.11.1.zen1-1"
printf '%%NAME%%\nlinux-zen\n\n%%INSTALLDATE%%\n%s\n' "$(date -d '2026-10-01' +%s)" >"$ROOT/var/lib/pacman/local/linux-zen-6.11.1.zen1-1/desc"
touch -d '2026-10-02' "$ROOT/boot/initramfs-linux-zen.img" "$ROOT/boot/initramfs-linux-zen-fallback.img"
run "" check; hasnt "older than the installed kernel" "uses pacman install date, not file ctime"
touch -d '2026-09-30' "$ROOT/boot/initramfs-linux-zen.img"
run "" check; has "initramfs-linux-zen.img is older than the installed kernel" "still catches truly stale initramfs"

# make_ubuntu: Ubuntu 24.04, ext4 root, ESP at /boot/efi, GRUB, nvidia-dkms, a removed kernel's leftovers
UKVER=6.8.0-45-generic
UPKG=linux-image-$UKVER
make_ubuntu() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ugtest.XXXXXX")
  mkdir -p "$ROOT"/{etc,boot/grub,boot/efi,run,var/lib/dpkg/info} "$ROOT/usr/lib/modules/$UKVER/build"
  mkdir -p "$ROOT/usr/lib/modules/6.8.0-40-generic/updates/dkms"   # left behind by a removed kernel
  printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n' >"$ROOT/etc/os-release"
  cat >"$ROOT/etc/fstab" <<EOF
UUID=1111-2222-3333 /         ext4 errors=remount-ro 0 1
UUID=ABCD-1234      /boot/efi vfat umask=0077 0 1
EOF
  printf 'KERNEL-%s\n' "$UKVER" >"$ROOT/boot/vmlinuz-$UKVER"
  printf 'usr/lib/modules/%s/kernel/x.ko\n' "$UKVER" >"$ROOT/boot/initrd.img-$UKVER"
  cat >"$ROOT/var/lib/dpkg/status" <<EOF
Package: $UPKG
Status: install ok installed

Package: linux-image-6.8.0-40-generic
Status: deinstall ok config-files
EOF
  printf '/boot/vmlinuz-%s\n' "$UKVER" >"$ROOT/var/lib/dpkg/info/$UPKG.list"
  printf '%s  boot/vmlinuz-%s\n' "$(md5sum <"$ROOT/boot/vmlinuz-$UKVER" | cut -d' ' -f1)" "$UKVER" \
    >"$ROOT/var/lib/dpkg/info/$UPKG.md5sums"
  touch -d '2026-10-01' "$ROOT/var/lib/dpkg/info/$UPKG.list"
  touch -d '2026-10-02' "$ROOT/boot/initrd.img-$UKVER"
  cat >"$ROOT/boot/grub/grub.cfg" <<EOF
menuentry 'Ubuntu' --class ubuntu --class gnu-linux {
	linux	/boot/vmlinuz-$UKVER root=UUID=1111-2222-3333 ro quiet splash
	initrd	/boot/initrd.img-$UKVER
}
submenu 'Advanced options for Ubuntu' {
	menuentry 'Ubuntu, with Linux 6.8.0-40-generic' --class ubuntu {
		linux	/boot/vmlinuz-6.8.0-40-generic root=UUID=1111-2222-3333 ro
		initrd	/boot/initrd.img-6.8.0-40-generic
	}
}
EOF
  printf 'nvidia/550.120, %s, x86_64: installed\n' "$UKVER" >"$ROOT/dkms.txt"
  export T_DKMS_FILE="$ROOT/dkms.txt" T_MOUNTED="/boot/efi" T_FSTYPE=ext4 T_SNAPPER=0
  export T_SOURCE=/dev/nvme0n1p2 T_UNAME_R=$UKVER T_DF_AVAIL=400 T_BTRFS_FAIL=0
}
APT_IN=$(printf 'VERSION 2\nAPT::Architecture=amd64\nDir=/\n\n%s - < 6.8.0-45.45 /var/cache/apt/archives/%s_6.8.0-45.45_amd64.deb\nfirefox 130.0 < 131.0 /var/cache/apt/archives/firefox_131.0_amd64.deb\n' "$UPKG" "$UPKG")

echo "== 14. Ubuntu: healthy system, apt hooks"
make_ubuntu
run "" check; rc_is 0 "check exits 0"
has "$UPKG: /boot/vmlinuz-$UKVER matches the packaged kernel" "kernel verified against dpkg md5sums"
has "/boot/initrd.img-$UKVER is current" "initrd verified"
has "DKMS modules installed (nvidia)" "dkms verified"
hasnt "linux-image-6.8.0-40" "removed kernel's leftover modules dir ignored"
has "GRUB (/boot/grub/grub.cfg, 2 entries)" "Ubuntu GRUB detected"
has "vmlinuz-6.8.0-40-generic, which doesn't exist (stale entry?)" "stale GRUB entry warned"
hasnt "No boot entry found" "GRUB entry matched to installed kernel"
has "/boot/efi is mounted" "ESP at /boot/efi checked"
run "$APT_IN" hook-pre --apt; rc_is 0 "apt pre exits 0"
has "1 risky package(s): $UPKG" "apt v2 package list parsed, firefox ignored"
has "No snapshot backend (root is ext4" "ext4 root: verify only"
run "" hook-post --apt; rc_is 0 "apt post exits 0"
has "boot looks healthy" "apt post verifies after dpkg"
run "/var/cache/apt/archives/${UPKG}_6.8.0-45.45_amd64.deb" hook-pre --apt
has "risky package(s): $UPKG" "apt v1 .deb list parsed"
run "$(printf 'VERSION 2\n\nfirefox 130.0 < 131.0 /x/firefox_131.0_amd64.deb\n')" hook-pre --apt
[[ -z $OUT ]] && ok "apt: no output for non-risky packages" || bad "apt: no output for non-risky packages"
run "" simulate linux-image-6.8.0-50-generic linux-libc-dev grub-efi-amd64-signed libc6 firefox
has "risky   linux-image-6.8.0-50-generic" "kernel image risky"
has "ignored linux-libc-dev" "linux-libc-dev ignored"
has "risky   grub-efi-amd64-signed" "grub risky"
has "risky   libc6" "libc6 risky"
run "" doctor
has "Ubuntu 24.04.1 LTS (debian backend)" "doctor shows distro"
has "apt hooks:" "doctor checks apt hooks"
has "$UPKG $UKVER (initrd, headers)" "doctor lists Ubuntu kernel"

echo "== 15. Ubuntu: failures and fixes"
make_ubuntu
printf 'OLD-KERNEL\n' >"$ROOT/boot/vmlinuz-$UKVER"
run "" check; rc_is 1 "check exits 1"
has "doesn't match what $UPKG installed" "stale /boot kernel detected via md5sums"
has "sudo apt install --reinstall $UPKG" "apt reinstall suggested"
make_ubuntu
touch -d '2026-09-30' "$ROOT/boot/initrd.img-$UKVER"
run "" check; has "initrd.img-$UKVER is older than the installed kernel" "stale initrd detected"
has "sudo update-initramfs -u -k $UKVER" "update-initramfs suggested"
make_ubuntu
printf 'usr/lib/modules/6.8.0-40-generic/kernel/x.ko\n' >"$ROOT/boot/initrd.img-$UKVER"
touch -d '2026-10-02' "$ROOT/boot/initrd.img-$UKVER"
run "" check; has "built for a different kernel" "wrong-kernel initrd detected"
make_ubuntu
rm "$ROOT/boot/initrd.img-$UKVER"
run "" check; has "initrd.img-$UKVER is missing or empty" "missing initrd detected"
has "sudo update-initramfs -c -k $UKVER" "create (not update) suggested for missing initrd"
make_ubuntu
rm -rf "$ROOT/usr/lib/modules/$UKVER/build"
run "" check; has "sudo apt install linux-headers-$UKVER && sudo dkms autoinstall -k $UKVER" "apt headers fix suggested"
make_ubuntu
sed -i '/vmlinuz-6.8.0-40/d; /initrd.img-6.8.0-40/d' "$ROOT/boot/grub/grub.cfg"
sed -i "s#/boot/vmlinuz-$UKVER#/boot/vmlinuz-$UKVER-gone#" "$ROOT/boot/grub/grub.cfg"
run "" check; has "doesn't exist" "missing GRUB kernel path reported"
has "sudo update-grub" "update-grub suggested"
if (( EUID != 0 )); then
  make_ubuntu; chmod 000 "$ROOT/boot/vmlinuz-$UKVER"
  run "" check; has "can't read /boot/vmlinuz-$UKVER as this user" "0600 vmlinuz handled without sudo"
  chmod 644 "$ROOT/boot/vmlinuz-$UKVER"
fi
make_ubuntu; export T_MOUNTED=""; conf DRY_RUN=0
run "$APT_IN" hook-pre --apt; rc_is 1 "unmounted /boot/efi aborts apt in active mode"
has "run apt again" "abort message names apt"

# make_fedora: Fedora 41, btrfs root, ext4 /boot, ESP at /boot/efi, GRUB with blscfg, akmod-nvidia,
# and a removed kernel's leftover extra/ dir
FKVER=6.11.4-301.fc41.x86_64
FPKG=kernel-core-$FKVER
MID=0123456789abcdef0123456789abcdef
make_fedora() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ugtest.XXXXXX")
  mkdir -p "$ROOT"/{etc/dnf,boot/loader/entries,boot/grub2,boot/efi,run,var/lib,usr/src/akmods}
  mkdir -p "$ROOT/usr/lib/modules/$FKVER/build" "$ROOT/usr/lib/modules/6.10.12-200.fc40.x86_64/extra"
  printf 'NAME="Fedora Linux"\nID=fedora\nPRETTY_NAME="Fedora Linux 41 (Workstation Edition)"\n' >"$ROOT/etc/os-release"
  cat >"$ROOT/etc/fstab" <<EOF
UUID=1111-2222-3333 /         btrfs subvol=root,compress=zstd:1 0 0
UUID=4444-5555      /boot     ext4  defaults 1 2
UUID=ABCD-1234      /boot/efi vfat  umask=0077,shortname=winnt 0 2
EOF
  printf 'KERNEL-%s\n' "$FKVER" >"$ROOT/usr/lib/modules/$FKVER/vmlinuz"
  cp "$ROOT/usr/lib/modules/$FKVER/vmlinuz" "$ROOT/boot/vmlinuz-$FKVER"
  printf 'usr/lib/modules/%s/kernel/drivers/x.ko\n' "$FKVER" >"$ROOT/boot/initramfs-$FKVER.img"
  touch -d '2026-10-02' "$ROOT/boot/initramfs-$FKVER.img"
  cat >"$ROOT/boot/loader/entries/$MID-$FKVER.conf" <<EOF
title Fedora Linux ($FKVER) 41 (Workstation Edition)
version $FKVER
linux /vmlinuz-$FKVER
initrd /initramfs-$FKVER.img
options root=UUID=1111-2222-3333 ro rootflags=subvol=root rhgb quiet
grub_class fedora
EOF
  printf 'set default_kernelopts=""\nblscfg\n' >"$ROOT/boot/grub2/grub.cfg"
  : >"$ROOT/usr/src/akmods/nvidia-kmod.latest"
  printf '%s\t%s\t%s\n' "$FPKG" "$(date -d '2026-10-01' +%s)" "/usr/lib/modules/$FKVER/vmlinuz" \
    "kmod-nvidia-$FKVER-560.35.03-1.fc41.x86_64" "$(date -d '2026-10-01' +%s)" "" >"$ROOT/rpmdb.txt"
  : >"$ROOT/dkms.txt"
  export T_RPM_DB="$ROOT/rpmdb.txt" T_DKMS_FILE="$ROOT/dkms.txt" T_MOUNTED="/boot /boot/efi" T_FSTYPE=btrfs
  export T_SNAPPER=0 T_SOURCE="/dev/nvme0n1p3[/root]" T_UNAME_R=$FKVER T_DF_AVAIL=400 T_BTRFS_FAIL=0
}

echo "== 16. Fedora: healthy system, dnf 4 hooks"
make_fedora
run "" check; rc_is 0 "check exits 0"
has "$FPKG: /boot/vmlinuz-$FKVER matches installed kernel $FKVER" "kernel verified against /usr/lib/modules"
has "/boot/initramfs-$FKVER.img is current" "dracut initramfs verified"
has "BLS (/boot/loader/entries, 1 entries)" "BLS entries parsed"
has "GRUB (/boot/grub2/grub.cfg, 0 entries)" "grub2 blscfg detected"
hasnt "No boot entry found" "BLS entry matched to installed kernel"
hasnt "6.10.12-200" "removed kernel's leftover modules dir ignored"
has "akmods modules built (nvidia)" "akmods kmod verified"
run "$(printf 'kernel-core\nkernel-modules\nfirefox\n')" hook-pre; rc_is 0 "pre exits 0"
has "2 risky package(s): kernel-core kernel-modules" "dnf package list filtered"
has "would take a btrfs snapshot" "btrfs backend on Fedora"
has "would copy" "plans a backup of the separate /boot"
run "kernel-core" hook-post; rc_is 0 "post exits 0"
has "boot looks healthy" "post verifies after dnf"
run "" simulate kernel-core kernel-headers kernel-tools kernel-srpm-macros akmod-nvidia grub2-efi-x64 glibc firefox
has "risky   kernel-core" "kernel-core risky"
has "ignored kernel-headers" "kernel-headers ignored"
has "ignored kernel-tools" "kernel-tools ignored"
has "ignored kernel-srpm-macros" "kernel-srpm-macros ignored"
has "risky   akmod-nvidia" "akmod risky"
has "risky   grub2-efi-x64" "grub2 risky"
has "risky   glibc" "glibc risky"
run "" doctor
has "Fedora Linux 41 (Workstation Edition) (rhel backend)" "doctor shows distro"
has "dnf hooks:" "doctor checks dnf hooks"
has "NOT installed" "doctor notices missing dnf hooks"
has "$FPKG $FKVER (initramfs, headers)" "doctor lists Fedora kernel"
has "akmods:" "doctor lists akmods"
mkdir -p "$ROOT/usr/lib/python3.13/site-packages/dnf-plugins" "$ROOT/etc/dnf/plugins"
: >"$ROOT/usr/lib/python3.13/site-packages/dnf-plugins/updateguard.py"
printf '[main]\nenabled=1\n' >"$ROOT/etc/dnf/plugins/updateguard.conf"
run "" doctor; has "dnf4 plugin (/usr/lib/python3.13/site-packages/dnf-plugins/updateguard.py)" "doctor finds dnf4 plugin"
conf DRY_RUN=0; export UG_NOW=20261020-080000
run "kernel-core" hook-pre; has "Took btrfs snapshot" "snapshot taken in active mode"
[[ -f $ROOT/var/lib/updateguard/boot/20261020-080000/boot/loader/entries/$MID-$FKVER.conf ]] && ok "BLS entry backed up with the kernel" || bad "BLS entry backed up with the kernel"
[[ -f $ROOT/var/lib/updateguard/boot/20261020-080000/boot/initramfs-$FKVER.img ]] && ok "initramfs backed up" || bad "initramfs backed up"
unset UG_NOW

echo "== 17. Fedora: dnf5 actions"
make_fedora
run "" hook-note kernel-core; run "" hook-note firefox; run "" hook-note kernel-core
[[ $(sort -u "$ROOT/run/updateguard/dnf-targets" | wc -l) == 2 ]] && ok "hook-note records package names" || bad "hook-note records package names"
OUT=$(env UG_ROOT="$ROOT" UG_CONF="$ROOT/etc/updateguard.conf" UG_RUN_DIR="$ROOT/run/updateguard" "$UG" hook-pre --dnf5 2>/dev/null)
[[ -z $OUT ]] && ok "dnf5 hooks keep stdout clean for the actions plugin" || bad "dnf5 hooks keep stdout clean for the actions plugin"
run "" hook-note kernel-core; run "" hook-note firefox
run "" hook-pre --dnf5; rc_is 0 "dnf5 pre exits 0"
has "1 risky package(s): kernel-core" "dnf5 collected list filtered"
[[ ! -e $ROOT/run/updateguard/dnf-targets ]] && ok "collected list consumed" || bad "collected list consumed"
run "" hook-post --dnf5; rc_is 0 "dnf5 post exits 0"
has "boot looks healthy" "dnf5 post verifies via the pending id"
run "" hook-note firefox; run "" hook-pre --dnf5
[[ -z $OUT ]] && ok "dnf5: no output for non-risky packages" || bad "dnf5: no output for non-risky packages"
export T_MOUNTED="/boot/efi"; conf DRY_RUN=0
run "" hook-note kernel-core; run "" hook-pre --dnf5; rc_is 1 "unmounted /boot aborts dnf in active mode"
has "run dnf again" "abort message names dnf"
run "" hook-note kernel-core
OUT=$(env UG_ROOT="$ROOT" UG_CONF="$ROOT/etc/updateguard.conf" UG_RUN_DIR="$ROOT/run/updateguard" "$UG" hook-pre --dnf5 2>/dev/null)
[[ $OUT == "stop=updateguard stopped the transaction"* && $OUT != *$'\n'* ]] && ok "dnf5 abort is a single stop= line on stdout" || bad "dnf5 abort is a single stop= line on stdout"
grep -q 'raise_error=' "$HERE/../dnf/updateguard.actions" && bad "dnf5 actions don't use raise_error (a missing binary would break dnf)" || ok "dnf5 actions don't use raise_error (a missing binary would break dnf)"

echo "== 18. Fedora: failures and fixes"
make_fedora
printf '%s\t%s\t%s\n' "kmod-other-1-1.fc41.x86_64" 0 "" >"$ROOT/rpmdb.tmp"
grep -v '^kmod-nvidia' "$ROOT/rpmdb.txt" >>"$ROOT/rpmdb.tmp"; mv "$ROOT/rpmdb.tmp" "$ROOT/rpmdb.txt"
run "" check; has "kmod-nvidia not built for $FKVER yet" "missing akmods kmod warned"
has "sudo akmods --force --kernels $FKVER" "akmods rebuild suggested"
T_PGREP=akmods run "" check; has "akmods is building kmod-nvidia for $FKVER in the background" "akmods build in progress is INFO"
hasnt "not built for" "no akmods warning while it's still building"
make_fedora
OKVER=6.10.12-200.fc40.x86_64
printf 'KERNEL-%s\n' "$OKVER" >"$ROOT/usr/lib/modules/$OKVER/vmlinuz"; cp "$ROOT/usr/lib/modules/$OKVER/vmlinuz" "$ROOT/boot/vmlinuz-$OKVER"
printf 'usr/lib/modules/%s/x.ko\n' "$OKVER" >"$ROOT/boot/initramfs-$OKVER.img"
printf '%s\t%s\t%s\n' "kernel-core-$OKVER" "$(date -d '2026-09-01' +%s)" "/usr/lib/modules/$OKVER/vmlinuz" >>"$ROOT/rpmdb.txt"
export T_RPM_LOG="$ROOT/rpm.log"
run "" check; hasnt "kmod-nvidia not built for $OKVER" "akmods only checks the newest kernel"
has "No boot entry found for kernel-core-$OKVER ($OKVER)" "kernel without a BLS entry warned"
has "sudo kernel-install add $OKVER /usr/lib/modules/$OKVER/vmlinuz" "missing BLS entry: kernel-install add, not remove"
[[ $(grep -c '^rpm -qf ' "$ROOT/rpm.log") == 1 ]] && ok "one rpm -qf call for all kernels" || bad "one rpm -qf call for all kernels ($(grep -c '^rpm -qf ' "$ROOT/rpm.log"))"
unset T_RPM_LOG
make_fedora
DKVER=6.11.4-301.fc41.x86_64+debug
mkdir -p "$ROOT/usr/lib/modules/$DKVER"; printf 'DEBUG\n' >"$ROOT/usr/lib/modules/$DKVER/vmlinuz"
printf '%s\t%s\t%s\n' "kernel-debug-core-$FKVER" 0 "/usr/lib/modules/$DKVER/vmlinuz" >>"$ROOT/rpmdb.txt"
printf 'nvidia/560.35.03, %s, x86_64: installed\n' "$FKVER" >"$ROOT/dkms.txt"
run "" check
has "sudo dnf install kernel-debug-devel-$FKVER && sudo dkms autoinstall -k $DKVER" "devel package derived from the debug kernel's NVRA"
has "kernel-debug-core-$FKVER: /boot/vmlinuz-$DKVER is missing" "missing /boot kernel detected"
has "sudo kernel-install add $DKVER /usr/lib/modules/$DKVER/vmlinuz" "kernel-install suggested"
has "sudo dracut -f --kver $DKVER" "dracut suggested for missing initramfs"
mkdir -p "$ROOT/boot/efi/EFI/Linux"; printf 'UKI\n' >"$ROOT/boot/efi/EFI/Linux/$MID-$DKVER.efi"
mv "$ROOT/boot/loader/entries/$MID-$FKVER.conf" "$ROOT/boot/$MID-$FKVER.conf.off"
run "" check; has "No boot entry found for $FPKG ($FKVER)" "a +debug UKI doesn't cover the plain kernel"
hasnt "No boot entry found for kernel-debug-core" "the +debug UKI covers the debug kernel"

echo "== 19. Fedora: kernel-install layout=bls and layout=uki"
make_fedora   # systemd-boot on the ESP at /boot/efi, kernel-install layout=bls
rm "$ROOT/boot/vmlinuz-$FKVER" "$ROOT/boot/initramfs-$FKVER.img" "$ROOT/boot/loader/entries/$MID-$FKVER.conf"
rm -rf "$ROOT/boot/loader" "$ROOT/boot/grub2"
mkdir -p "$ROOT/boot/efi/$MID/$FKVER" "$ROOT/boot/efi/loader/entries" "$ROOT/boot/efi/EFI/systemd"
: >"$ROOT/boot/efi/EFI/systemd/systemd-bootx64.efi"
cp "$ROOT/usr/lib/modules/$FKVER/vmlinuz" "$ROOT/boot/efi/$MID/$FKVER/linux"
printf 'usr/lib/modules/%s/kernel/drivers/x.ko\n' "$FKVER" >"$ROOT/boot/efi/$MID/$FKVER/initrd"
touch -d '2026-10-02' "$ROOT/boot/efi/$MID/$FKVER/initrd"
printf 'title Fedora Linux\nversion %s\nlinux /%s/%s/linux\ninitrd /%s/%s/initrd\n' "$FKVER" "$MID" "$FKVER" "$MID" "$FKVER" \
  >"$ROOT/boot/efi/loader/entries/$MID-$FKVER.conf"
run "" check; rc_is 0 "layout=bls system is healthy"
has "$FPKG: /boot/efi/$MID/$FKVER/linux matches installed kernel $FKVER" "kernel found in the BLS layout dir"
has "/boot/efi/$MID/$FKVER/initrd is current" "initrd found in the BLS layout dir"
hasnt "No boot entry found" "BLS layout entry covers the kernel"
rm "$ROOT/boot/efi/$MID/$FKVER/initrd"
run "" check; has "(kernel $FPKG is installed)" "missing BLS-layout initrd is a FAIL tied to the kernel"
has "sudo kernel-install add $FKVER" "kernel-install fixes the BLS-layout entry"
make_fedora   # layout=uki: one UKI on the ESP, no /boot/vmlinuz
rm "$ROOT/boot/vmlinuz-$FKVER" "$ROOT/boot/initramfs-$FKVER.img" "$ROOT/boot/loader/entries/$MID-$FKVER.conf"
mkdir -p "$ROOT/boot/efi/EFI/Linux"; printf 'UKI\n' >"$ROOT/boot/efi/EFI/Linux/$MID-$FKVER+3-0.efi"
touch -d '2026-10-02' "$ROOT/boot/efi/EFI/Linux/$MID-$FKVER+3-0.efi"
run "" check; rc_is 0 "layout=uki system is healthy"
hasnt "is missing" "no missing /boot/vmlinuz FAIL with UKIs"
hasnt "No boot entry found" "UKI with boot counting covers the kernel"
run "" doctor; has "$FPKG $FKVER (UKI $MID-$FKVER+3-0.efi, headers)" "doctor shows the kernel's UKI"
touch -d '2026-09-01' "$ROOT/boot/efi/EFI/Linux/$MID-$FKVER+3-0.efi"
run "" check; has "older than the installed kernel" "stale UKI detected"
has "sudo kernel-install add $FKVER" "kernel-install regenerates the UKI, not mkinitcpio"
hasnt "mkinitcpio" "no Arch fix on Fedora"

# make_rocky: Rocky 8, xfs root, /boot on the root fs, ESP at /boot/efi, RHEL-style BLS, DKMS
RKVER=4.18.0-553.176.1.el8_10.x86_64
RPKG=kernel-core-$RKVER
make_rocky() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ugtest.XXXXXX")
  mkdir -p "$ROOT"/{etc/dnf,boot/loader/entries,boot/efi,run,var/lib} "$ROOT/usr/lib/modules/$RKVER/build"
  mkdir -p "$ROOT/usr/lib/modules/4.18.0-553.el8_10.x86_64/extra"
  printf 'NAME="Rocky Linux"\nID="rocky"\nID_LIKE="rhel centos fedora"\nPRETTY_NAME="Rocky Linux 8.10 (Green Obsidian)"\n' >"$ROOT/etc/os-release"
  cat >"$ROOT/etc/fstab" <<EOF
UUID=1111-2222-3333 /         xfs  defaults 0 0
UUID=ABCD-1234      /boot/efi vfat umask=077,shortname=winnt 0 2
EOF
  printf 'KERNEL-%s\n' "$RKVER" >"$ROOT/usr/lib/modules/$RKVER/vmlinuz"
  cp "$ROOT/usr/lib/modules/$RKVER/vmlinuz" "$ROOT/boot/vmlinuz-$RKVER"
  printf 'usr/lib/modules/%s/kernel/x.ko\n' "$RKVER" >"$ROOT/boot/initramfs-$RKVER.img"
  touch -d '2026-10-02' "$ROOT/boot/initramfs-$RKVER.img"
  printf 'RESCUE\n' >"$ROOT/boot/vmlinuz-0-rescue-$MID"; printf 'x\n' >"$ROOT/boot/initramfs-0-rescue-$MID.img"
  cat >"$ROOT/boot/loader/entries/$MID-$RKVER.conf" <<EOF
title Rocky Linux ($RKVER) 8.10 (Green Obsidian)
version $RKVER
linux /vmlinuz-$RKVER
initrd /initramfs-$RKVER.img \$tuned_initrd
options \$kernelopts \$tuned_params
id rocky-20261022-$RKVER
grub_users \$grub_users
grub_arg --unrestricted
grub_class kernel
EOF
  cat >"$ROOT/boot/loader/entries/$MID-0-rescue.conf" <<EOF
title Rocky Linux (0-rescue-$MID) 8.10 (Green Obsidian)
linux /vmlinuz-0-rescue-$MID
initrd /initramfs-0-rescue-$MID.img
EOF
  printf '%s\t%s\t%s\n' "$RPKG" "$(date -d '2026-10-01' +%s)" "/usr/lib/modules/$RKVER/vmlinuz" >"$ROOT/rpmdb.txt"
  printf 'nvidia/560.35.03, %s, x86_64: installed\n' "$RKVER" >"$ROOT/dkms.txt"
  export T_RPM_DB="$ROOT/rpmdb.txt" T_DKMS_FILE="$ROOT/dkms.txt" T_MOUNTED="/boot/efi" T_FSTYPE=xfs
  export T_SNAPPER=0 T_SOURCE=/dev/nvme0n1p3 T_UNAME_R=$RKVER T_DF_AVAIL=400 T_BTRFS_FAIL=0
}

echo "== 20. Rocky 8: healthy system, then failures"
make_rocky
run "" check; rc_is 0 "check exits 0"
has "$RPKG: /boot/vmlinuz-$RKVER matches installed kernel" "Rocky kernel verified"
has "BLS (/boot/loader/entries, 2 entries)" "RHEL BLS entries parsed"
hasnt "tuned_initrd" "GRUB variables in BLS entries skipped"
hasnt "doesn't exist" "rescue entry and kernel entry resolve"
hasnt "4.18.0-553.el8_10" "removed kernel's leftover extra/ ignored"
has "DKMS modules installed (nvidia)" "dkms verified"
run "kernel-core" hook-pre
has "No snapshot backend (root is xfs" "xfs root: verify only"
make_rocky
printf 'OLD-KERNEL\n' >"$ROOT/boot/vmlinuz-$RKVER"
run "" check; rc_is 1 "check exits 1"
has "/boot/vmlinuz-$RKVER doesn't match installed kernel $RKVER" "stale /boot kernel detected"
has "sudo kernel-install add $RKVER /usr/lib/modules/$RKVER/vmlinuz" "kernel-install fix suggested"
make_rocky
touch -d '2026-09-30' "$ROOT/boot/initramfs-$RKVER.img"
run "" check; has "initramfs-$RKVER.img is older than the installed kernel" "stale initramfs detected via rpm INSTALLTIME"
has "sudo dracut -f --kver $RKVER" "dracut fix suggested"
make_rocky
printf 'usr/lib/modules/4.18.0-553.el8_10.x86_64/kernel/x.ko\n' >"$ROOT/boot/initramfs-$RKVER.img"
touch -d '2026-10-02' "$ROOT/boot/initramfs-$RKVER.img"
run "" check; has "built for a different kernel" "wrong-kernel initramfs detected via lsinitrd"
make_rocky
rm -rf "$ROOT/usr/lib/modules/$RKVER/build"
run "" check; has "sudo dnf install kernel-devel-$RKVER && sudo dkms autoinstall -k $RKVER" "kernel-devel fix suggested"
make_rocky
sed -i "s#^linux /vmlinuz-$RKVER#linux /vmlinuz-$RKVER-gone#" "$ROOT/boot/loader/entries/$MID-$RKVER.conf"
run "" check; has "vmlinuz-$RKVER-gone, which doesn't exist (stale entry?)" "stale BLS entry warned"
has "sudo kernel-install remove" "kernel-install remove suggested for stale entry"
make_rocky
rm "$ROOT/boot/initramfs-$RKVER.img"
run "" check; has "points to /initramfs-$RKVER.img, which doesn't exist (kernel $RPKG is installed)" "BLS entry with missing initramfs fails"
if (( EUID != 0 )); then
  make_rocky; chmod 000 "$ROOT/boot/loader/entries"
  run "" check; has "Can't read /boot/loader/entries as this user" "0700 BLS dir handled without sudo"
  hasnt "No boot entry found" "no false missing-entry warnings when entries are unreadable"
  hasnt "0 file references checked" "no OK verdict for boot entries it couldn't read"
  chmod 755 "$ROOT/boot/loader/entries"
fi

echo "== 21. dnf 4 plugin (fake dnf module)"
if command -v python3 >/dev/null; then
  W=$(mktemp -d "${TMPDIR:-/tmp}/ugdnf.XXXXXX")
  # shellcheck disable=SC2016  # the fake binary expands these itself
  printf '#!/usr/bin/env bash\n{ echo "ARGS $*"; cat; } >>"%s/log"\n[[ $1 == hook-pre ]] && exit "${T_PRE_RC:-0}"\nexit 0\n' "$W" >"$W/bin"
  chmod +x "$W/bin"
  OUT=$(python3 -I - "$HERE/../dnf/updateguard.py" "$W/bin" "$W/log" <<'EOF' 2>&1
import importlib.util, os, sys, types
from types import SimpleNamespace as NS
dnf = types.ModuleType('dnf'); exc = types.ModuleType('dnf.exceptions')
class Error(Exception): pass
class Plugin:
    def __init__(self, base, cli): self.base = base
exc.Error = Error; dnf.exceptions = exc; dnf.Plugin = Plugin
sys.modules['dnf'] = dnf; sys.modules['dnf.exceptions'] = exc
spec = importlib.util.spec_from_file_location('ugplugin', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.BIN, log = sys.argv[2], sys.argv[3]
def base(root='/', flags=()):
    t = NS(install_set=[NS(name='kernel-core'), NS(name='firefox')], remove_set=[NS(name='kernel-core')])
    return NS(conf=NS(installroot=root, tsflags=list(flags)), transaction=t)
def logged():
    if not os.path.exists(log): return ''
    s = open(log).read(); os.remove(log); return s
p = m.UpdateGuard(base(), None); p.pre_transaction()
print('pre-call:', repr(logged()))
p.transaction(); print('post-call:', repr(logged()))
os.environ['T_PRE_RC'] = '1'
try: p.pre_transaction(); print('rc1: no exception')
except Error as e: print('rc1: raised', e)
logged(); del os.environ['T_PRE_RC']
m.UpdateGuard(base('/mnt/sysimage'), None).pre_transaction(); print('installroot:', repr(logged()))
m.UpdateGuard(base(flags=['test']), None).pre_transaction(); print('test-flag:', repr(logged()))
m.BIN = '/nonexistent/updateguard'; m.UpdateGuard(base(), None).pre_transaction(); print('missing-bin: ok')
EOF
)
  has "pre-call: 'ARGS hook-pre\\nfirefox\\nkernel-core\\n'" "plugin passes sorted unique names to hook-pre"
  has "post-call: 'ARGS hook-post\\nfirefox\\nkernel-core\\n'" "plugin runs hook-post after the transaction"
  has "rc1: raised updateguard stopped the transaction" "hook-pre exit 1 aborts dnf"
  has "installroot: ''" "plugin ignores --installroot transactions"
  has "test-flag: ''" "plugin ignores test transactions"
  has "missing-bin: ok" "missing binary doesn't break dnf"
  rm -rf "$W"
else
  echo "  skip dnf plugin tests (need python3)"
fi

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
