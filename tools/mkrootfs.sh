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

# the live user 'kiwi' (uid 1000): autologin target of the graphical
# session (mkiso.sh configures LightDM), groups for direct rendering,
# audio and seatd. kiwi-install creates the real user at install time
# and strips the live-only bits (autologin, NOPASSWD sudo) from the
# target. skipped when the rootfs has no useradd (bare base-system).
if chroot "$TARGET" sh -c 'command -v useradd >/dev/null 2>&1'; then
        # the loop vars expand inside the chroot shell, not here
        # shellcheck disable=SC2016
        chroot "$TARGET" sh -c '
                for g in wheel video audio input; do
                        grep -q "^$g:" /etc/group || groupadd -r "$g"
                done
                id -u kiwi >/dev/null 2>&1 || useradd -m -s /bin/bash \
                        -G wheel,video,audio,input kiwi
        ' || echo "mkrootfs: warning: could not create the live user"
        if chroot "$TARGET" id -u kiwi >/dev/null 2>&1; then
                if echo "kiwi:kinini" | chroot "$TARGET" chpasswd 2>/dev/null; then
                        echo "mkrootfs: live user 'kiwi' password set to 'kinini'"
                fi
                if [ -f "$TARGET/usr/bin/sudo" ]; then
                        mkdir -p "$TARGET/etc/sudoers.d"
                        printf 'kiwi ALL=(ALL:ALL) NOPASSWD: ALL\n' \
                                > "$TARGET/etc/sudoers.d/kinini-live"
                        chmod 440 "$TARGET/etc/sudoers.d/kinini-live"
                fi
        fi
fi

echo "mkrootfs: KiniNi rootfs ready at $TARGET"
echo "mkrootfs: boot with init=/sbin/niinit"
