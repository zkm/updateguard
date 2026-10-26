# Maintainer: Zach Schneider <zachschneider@gmail.com>
pkgname=updateguard
pkgver=0.3.1
pkgrel=1
pkgdesc="Snapshot before risky pacman updates and verify the system will still boot afterwards"
arch=('any')
url="https://github.com/zkm/updateguard"
license=('MIT')
depends=('bash' 'coreutils' 'util-linux' 'grep' 'gawk' 'sed')
optdepends=('btrfs-progs: raw btrfs snapshots'
            'binutils: verify kernel inside UKIs (objcopy)'
            'snapper: snapper snapshots'
            'snap-pac: let snap-pac take the snapshots'
            'dkms: DKMS module checks'
            'mkinitcpio: initramfs content checks via lsinitcpio')
backup=('etc/updateguard.conf')
source=('updateguard' 'updateguard.conf' '05-updateguard-pre.hook' 'zzz-updateguard-post.hook' 'LICENSE')
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {
  install -Dm755 updateguard "$pkgdir/usr/bin/updateguard"
  install -Dm644 updateguard.conf "$pkgdir/etc/updateguard.conf"
  install -Dm644 05-updateguard-pre.hook "$pkgdir/usr/share/libalpm/hooks/05-updateguard-pre.hook"
  install -Dm644 zzz-updateguard-post.hook "$pkgdir/usr/share/libalpm/hooks/zzz-updateguard-post.hook"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
