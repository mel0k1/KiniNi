#!/bin/sh
set -eu

usage() {
        echo "usage: $0 <rootdir> [repository] [package...]" >&2
        exit 1
}

[ $# -ge 1 ] || usage
command -v xbps-install >/dev/null || {
        echo "mkrootfs: xbps-install not found" >&2
        exit 1
}

TARGET=$(readlink -f "$1")
REPO=${2:-https://repo-default.voidlinux.org/current}
if [ $# -ge 3 ]; then
        shift 2
        PKGS=$*
else
        PKGS=base-system
fi
SRC=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$TARGET/var/db/xbps" "$TARGET/var/cache/xbps" "$TARGET/etc" "$TARGET/etc/xbps.d"
mkdir -p "$TARGET/var/db/xbps/keys"
install -m644 "$SRC"/tools/keys/*.plist "$TARGET/var/db/xbps/keys/"

if [ -n "${IGNORE_PKGS:-}" ]; then
        for p in $IGNORE_PKGS; do
                echo "ignorepkg=$p"
        done > "$TARGET/etc/xbps.d/00-ignore.conf"
fi

# shellcheck disable=SC2086
xbps-install -y -S -C "$TARGET/etc/xbps.d" -R "$REPO" -r "$TARGET" $PKGS

cp -a "$SRC"/skel/. "$TARGET"/
cp /etc/resolv.conf "$TARGET"/etc/ 2>/dev/null || true

install -Dm755 "$SRC"/niinit/bin/niinit "$TARGET"/sbin/niinit
ln -sf niinit "$TARGET"/sbin/init
install -Dm755 "$SRC"/niinit/bin/niinit-sv "$TARGET"/sbin/niinit-sv
install -Dm755 "$SRC"/niinit/bin/niinit-svdir "$TARGET"/sbin/niinit-svdir
install -Dm755 "$SRC"/niinit/bin/svctl "$TARGET"/usr/bin/svctl
install -Dm755 "$SRC"/niinit/bin/niinit-parallel "$TARGET"/usr/bin/niinit-parallel
ln -sf svctl "$TARGET"/usr/bin/reboot
ln -sf svctl "$TARGET"/usr/bin/poweroff
ln -sf svctl "$TARGET"/usr/bin/halt
install -Dm755 "$SRC"/kipki/bin/kipki "$TARGET"/usr/bin/kipki
install -Dm644 "$SRC"/kipki/skel/kipki.conf "$TARGET"/etc/kipki/kipki.conf

if echo "root:kinini" | chroot "$TARGET" chpasswd 2>/dev/null; then
        echo "mkrootfs: root password set to 'kinini' (change it)"
fi

echo "mkrootfs: KiniNi rootfs ready at $TARGET"
echo "mkrootfs: boot with init=/sbin/niinit"
