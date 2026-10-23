#!/usr/bin/env bash
# Install updateguard without building a package.
#   ./install.sh             show what would be installed (changes nothing)
#   sudo ./install.sh --apply
#   sudo ./install.sh --uninstall
# On Arch, prefer `makepkg -si` (see PKGBUILD) so pacman tracks the files.
# On Debian/Ubuntu this installs apt hooks instead of pacman hooks; on Fedora/RHEL a dnf 4
# plugin, or dnf5 actions on Fedora 41+.
set -euo pipefail
cd "$(dirname "$0")"

BIN=/usr/local/bin/updateguard
HOOKS=/etc/pacman.d/hooks
APTCONF=/etc/apt/apt.conf.d/05updateguard
CONF=/etc/updateguard.conf
DNFCONF=/etc/dnf/plugins/updateguard.conf
DNF5ACTIONS=/etc/dnf/libdnf5-plugins/actions.d/updateguard.actions
# sudo only searches secure_path, and RHEL's leaves out /usr/local/bin. /usr/bin is on every
# secure_path, and an rpm that later ships /usr/bin/updateguard just replaces the link.
LINK=/usr/bin/updateguard
OLDLINKS=(/usr/sbin/updateguard)   # where pre-release builds of this script put it
SUDOERS=/etc/sudoers
mode=${1:-plan}

if command -v apt-get >/dev/null 2>&1 && [[ -d /etc/apt/apt.conf.d ]]; then pm=apt
elif command -v pacman >/dev/null 2>&1; then pm=pacman
elif command -v dnf >/dev/null 2>&1; then
  # Fedora 41+ links dnf to dnf5; RHEL and older Fedora run the Python dnf 4
  if [[ $(readlink -f "$(command -v dnf)") == */dnf5 ]]; then pm=dnf5; else pm=dnf; fi
else echo "None of apt, pacman or dnf found; updateguard supports Arch, Debian/Ubuntu and Fedora/RHEL." >&2; exit 1
fi

dnf_plugin_dir() {   # dnf 4 loads plugins from dnf-plugins/ next to the dnf package, in dnf's own Python
  local dnfbin py
  dnfbin=$(readlink -f "$(command -v dnf)")
  py=$(sed -n '1s/^#![[:space:]]*\([^[:space:]]*\).*/\1/p' "$dnfbin")
  "${py:-python3}" -I -c 'import dnf, os; print(os.path.join(os.path.dirname(os.path.dirname(dnf.__file__)), "dnf-plugins"))'
}

sudo_secure_path() {   # -> the last secure_path set in sudoers; empty if none
  cat "$SUDOERS" "$SUDOERS".d/* 2>/dev/null |
    sed -nE 's/^[[:space:]]*Defaults[[:space:]]+secure_path[[:space:]]*=[[:space:]]*"?([^"]*)"?.*/\1/p' | tail -n1
}

is_our_link() {   # PATH: a symlink to $BIN (however it's spelled), or a dangling one
  [[ -L $1 ]] && { [[ ! -e $1 ]] || [[ $(readlink -f "$1") == "$(readlink -f "$BIN")" ]]; }
}

link_state() {   # -> create | ours | blocked | skip | unknown
  local sp
  if is_our_link "$LINK"; then echo ours; return; fi
  if [[ -r $SUDOERS ]]; then
    sp=$(sudo_secure_path)
    # no secure_path, or one with /usr/local/bin: sudo finds $BIN and something else at $LINK doesn't matter
    [[ -n $sp && :$sp: != *:/usr/local/bin:* ]] || { echo skip; return; }
  fi
  if [[ -e $LINK || -L $LINK ]]; then echo blocked
  elif [[ -r $SUDOERS ]]; then echo create
  else echo unknown; fi
}

case $mode in
  plan)
    echo "Would install:"
    echo "  updateguard                -> $BIN"
    if [[ $pm == apt ]]; then
      echo "  apt/05updateguard          -> $APTCONF   (commands -> $BIN)"
    elif [[ $pm == dnf ]]; then
      echo "  dnf/updateguard.py         -> $(dnf_plugin_dir)/updateguard.py   (BIN -> $BIN)"
      echo "  dnf/updateguard.conf       -> $DNFCONF"
    elif [[ $pm == dnf5 ]]; then
      echo "  dnf/updateguard.actions    -> $DNF5ACTIONS   (commands -> $BIN)"
      [[ -e /etc/dnf/libdnf5-plugins/actions.conf ]] ||
        echo "  note: the actions plugin isn't installed; first run: sudo dnf install libdnf5-plugin-actions"
    else
      echo "  05-updateguard-pre.hook    -> $HOOKS/05-updateguard-pre.hook   (Exec -> $BIN)"
      echo "  zzz-updateguard-post.hook  -> $HOOKS/zzz-updateguard-post.hook (Exec -> $BIN)"
    fi
    case $(link_state) in
      create) echo "  symlink $LINK -> $BIN   (sudo's secure_path leaves out /usr/local/bin)" ;;
      ours) echo "  symlink $LINK -> $BIN   (exists, kept)" ;;
      blocked) if [[ -r $SUDOERS ]]; then echo "  $LINK exists and isn't updateguard's link: left alone, run sudo $BIN instead"
        else echo "  $LINK exists and isn't updateguard's link: left alone. If sudo's secure_path leaves out /usr/local/bin, run sudo $BIN"; fi ;;
      unknown) echo "  symlink $LINK -> $BIN   if sudo's secure_path leaves out /usr/local/bin (can't read $SUDOERS without sudo)" ;;
    esac
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
    elif [[ $pm == dnf ]]; then
      plugdir=$(dnf_plugin_dir)
      install -d "$plugdir"
      sed "s#^BIN = '/usr/bin/updateguard'#BIN = '$BIN'#" dnf/updateguard.py >"$plugdir/updateguard.py"
      chmod 644 "$plugdir/updateguard.py"
      install -Dm644 dnf/updateguard.conf "$DNFCONF"
    elif [[ $pm == dnf5 ]]; then
      [[ -e /etc/dnf/libdnf5-plugins/actions.conf ]] ||
        { echo "Install the dnf5 actions plugin first: sudo dnf install libdnf5-plugin-actions" >&2; exit 1; }
      install -d "${DNF5ACTIONS%/*}"
      sed "s#/usr/bin/updateguard#$BIN#g" dnf/updateguard.actions >"$DNF5ACTIONS"
      chmod 644 "$DNF5ACTIONS"
    else
      install -d "$HOOKS"
      for h in 05-updateguard-pre.hook zzz-updateguard-post.hook; do
        sed "s#^Exec = /usr/bin/updateguard#Exec = $BIN#" "$h" >"$HOOKS/$h"
        chmod 644 "$HOOKS/$h"
      done
    fi
    run=updateguard
    case $(link_state) in
      create | ours) ln -sfn "$BIN" "$LINK" ;;
      # never replace a file or link that isn't ours, e.g. one an rpm put there
      blocked) echo "note: $LINK exists and isn't updateguard's link; left alone." >&2; run=$BIN ;;
    esac
    [[ -e $CONF ]] || install -Dm644 updateguard.conf "$CONF"
    echo "Installed. Next: sudo $run doctor"
    ;;
  --uninstall)
    [[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
    # the apt hook calls the binary directly, so it must go first or apt breaks
    plugdir=""
    if command -v dnf >/dev/null 2>&1; then plugdir=$(dnf_plugin_dir 2>/dev/null) || plugdir=""; fi
    rm -f "$APTCONF" "$HOOKS/05-updateguard-pre.hook" "$HOOKS/zzz-updateguard-post.hook" "$DNF5ACTIONS" "$DNFCONF"
    # where --apply put the dnf 4 plugin, plus the places updateguard doctor looks
    for d in ${plugdir:+"$plugdir"} /usr{,/local}/lib{,64}/python3*/site-packages/dnf-plugins; do
      rm -f "$d/updateguard.py" "$d"/__pycache__/updateguard.*.pyc
    done
    # before the binary goes, while the links still resolve to it
    for l in "$LINK" "${OLDLINKS[@]}"; do
      if is_our_link "$l"; then rm -f "$l"; fi
    done
    rm -f "$BIN"
    echo "Removed binary and hooks. Left $CONF, /var/lib/updateguard and any snapshots in place."
    ;;
  *)
    echo "usage: $0 [--apply|--uninstall]" >&2; exit 2 ;;
esac
