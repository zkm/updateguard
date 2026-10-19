#!/usr/bin/env bash
# Install updateguard without building a package.
#   ./install.sh             show what would be installed (changes nothing)
#   sudo ./install.sh --apply
#   sudo ./install.sh --uninstall
# On Arch, prefer `makepkg -si` (see PKGBUILD) so pacman tracks the files.
# On Debian/Ubuntu this installs apt hooks instead of pacman hooks.
set -euo pipefail
cd "$(dirname "$0")"

BIN=/usr/local/bin/updateguard
HOOKS=/etc/pacman.d/hooks
APTCONF=/etc/apt/apt.conf.d/05updateguard
CONF=/etc/updateguard.conf
mode=${1:-plan}

if command -v apt-get >/dev/null 2>&1 && [[ -d /etc/apt/apt.conf.d ]]; then pm=apt
elif command -v pacman >/dev/null 2>&1; then pm=pacman
else echo "Neither pacman nor apt found; updateguard supports Arch and Debian/Ubuntu." >&2; exit 1
fi

case $mode in
  plan)
    echo "Would install:"
    echo "  updateguard                -> $BIN"
    if [[ $pm == apt ]]; then
      echo "  apt/05updateguard          -> $APTCONF   (commands -> $BIN)"
    else
      echo "  05-updateguard-pre.hook    -> $HOOKS/05-updateguard-pre.hook   (Exec -> $BIN)"
      echo "  zzz-updateguard-post.hook  -> $HOOKS/zzz-updateguard-post.hook (Exec -> $BIN)"
    fi
    echo "  updateguard.conf           -> $CONF  $( [[ -e $CONF ]] && echo "(exists, left alone)" || echo "(DRY_RUN=1)" )"
    echo
    echo "Nothing changed. Run: sudo ./install.sh --apply"
    ;;
  --apply)
    [[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
    install -Dm755 updateguard "$BIN"
    if [[ $pm == apt ]]; then
      sed "s#/usr/bin/updateguard#$BIN#g" apt/05updateguard >"$APTCONF"
      chmod 644 "$APTCONF"
    else
      install -d "$HOOKS"
      for h in 05-updateguard-pre.hook zzz-updateguard-post.hook; do
        sed "s#^Exec = /usr/bin/updateguard#Exec = $BIN#" "$h" >"$HOOKS/$h"
        chmod 644 "$HOOKS/$h"
      done
    fi
    [[ -e $CONF ]] || install -Dm644 updateguard.conf "$CONF"
    echo "Installed. Next: sudo updateguard doctor"
    ;;
  --uninstall)
    [[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
    # the apt hook calls the binary directly, so it must go first or apt breaks
    rm -f "$APTCONF" "$HOOKS/05-updateguard-pre.hook" "$HOOKS/zzz-updateguard-post.hook" "$BIN"
    echo "Removed binary and hooks. Left $CONF, /var/lib/updateguard and any snapshots in place."
    ;;
  *)
    echo "usage: $0 [--apply|--uninstall]" >&2; exit 2 ;;
esac
