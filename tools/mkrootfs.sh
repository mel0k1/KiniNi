#!/bin/sh
set -eu

usage() {
	echo "usage: $0 <rootdir> [repository]" >&2
	exit 1
}

[ $# -ge 1 ] || usage
command -v xbps-install >/dev/null || {
	echo "mkrootfs: xbps-install not found" >&2
	exit 1
}

TARGET=$(readlink -f "$1")
REPO=${2:-https://repo-default.voidlinux.org/current}
SRC=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$TARGET/var/db/xbps" "$TARGET/var/cache/xbps" "$TARGET/etc"

xbps-install -y -S -R "$REPO" -r "$TARGET" base-system

cp -a "$SRC"/skel/. "$TARGET"/
cp /etc/resolv.conf "$TARGET"/etc/ 2>/dev/null || true

install -Dm755 "$SRC"/niinit/bin/niinit "$TARGET"/sbin/niinit
install -Dm755 "$SRC"/niinit/bin/niinit-sv "$TARGET"/sbin/niinit-sv
install -Dm755 "$SRC"/niinit/bin/niinit-svdir "$TARGET"/sbin/niinit-svdir
install -Dm755 "$SRC"/niinit/bin/svctl "$TARGET"/usr/bin/svctl
ln -sf svctl "$TARGET"/usr/bin/reboot
ln -sf svctl "$TARGET"/usr/bin/poweroff
ln -sf svctl "$TARGET"/usr/bin/halt
install -Dm755 "$SRC"/kipki/bin/kipki "$TARGET"/usr/bin/kipki
install -Dm644 "$SRC"/kipki/skel/kipki.conf "$TARGET"/etc/kipki/kipki.conf

if command -v chroot >/dev/null && [ -x "$TARGET/usr/sbin/chpasswd" ]; then
	echo "root:kinini" | chroot "$TARGET" chpasswd 2>/dev/null \
		&& echo "mkrootfs: root password set to 'kinini' (change it)" \
		|| true
fi

echo "mkrootfs: KiniNi rootfs ready at $TARGET"
echo "mkrootfs: boot with init=/sbin/niinit"
