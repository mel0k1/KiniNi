#!/bin/sh
# build a bootable KiniNi live iso from a rootfs
# usage: mkiso.sh <rootdir> <output.iso>
#
# env overrides:
#   BUSYBOX       static busybox for the initramfs
#   SYSLINUX_DIR  directory with isolinux.bin, isohdpfx.bin, ldlinux.c32
#   ISOHYBRID     isohybrid binary (optional, usb hybrid boot)
#   MKISO         genisoimage/mkisofs/xorriso (auto-detected)
#   CPIO          cpio command (auto-detected)
#   ISOVOLUME     volume label (default KININI_LIVE)
set -eu

usage() {
        echo "usage: $0 <rootdir> <output.iso>" >&2
        exit 1
}

[ $# -ge 2 ] || usage
[ "$(id -u)" = 0 ] && echo "mkiso: warning: running as root" >&2

ROOT=$(readlink -f "$1")
OUT=$(readlink -f "$2")
VOL=${ISOVOLUME:-KININI_LIVE}
WORK=$(mktemp -d /tmp/mkiso.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

die() {
        echo "mkiso: $*" >&2
        exit 1
}

have() {
        command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- toolchain
MKISO=${MKISO:-}
if [ -z "$MKISO" ]; then
        for c in genisoimage mkisofs xorriso; do
                if have "$c"; then
                        MKISO=$c
                        break
                fi
        done
fi
[ -n "$MKISO" ] || die "genisoimage/mkisofs/xorriso not found"

CPIO=${CPIO:-}
if [ -z "$CPIO" ]; then
        if have cpio; then
                CPIO="cpio -o -H newc --quiet"
        elif have busybox; then
                CPIO="busybox cpio -o -H newc"
        else
                die "cpio not found (set CPIO=...)"
        fi
fi

BUSYBOX=${BUSYBOX:-$(command -v busybox 2>/dev/null || true)}
if [ -z "$BUSYBOX" ] || [ ! -x "$BUSYBOX" ]; then
        die "static busybox not found (set BUSYBOX=...)"
fi
# the initramfs has no shared libraries: refuse a dynamic busybox
if command -v ldd >/dev/null 2>&1 && ldd "$BUSYBOX" 2>/dev/null | grep -q 'lib'; then
        die "$BUSYBOX is dynamically linked; a static busybox is required"
fi

GZIP=gzip
have gzip || GZIP="busybox gzip"

ZSTD="zstd -q"
have zstd || ZSTD=""
[ -n "$ZSTD" ] || echo "mkiso: warning: zstd not found, .ko.zst modules left as-is" >&2

find_syslinux_file() {
        _f=$1
        for d in ${SYSLINUX_DIR:-} /usr/lib/ISOLINUX /usr/lib/syslinux/bios \
            /usr/lib/syslinux /usr/share/syslinux; do
                [ -n "$d" ] && [ -f "$d/$_f" ] && { echo "$d/$_f"; return 0; }
        done
        return 1
}

ISOLINUX_BIN=$(find_syslinux_file isolinux.bin) || die "isolinux.bin not found (set SYSLINUX_DIR=...)"
LDLINUX=$(find_syslinux_file ldlinux.c32) || die "ldlinux.c32 not found (set SYSLINUX_DIR=...)"
ISOHDPFX=$(find_syslinux_file isohdpfx.bin || true)
ISOHYBRID=${ISOHYBRID:-$(command -v isohybrid 2>/dev/null || true)}

# ---------------------------------------------------------------- kernel
KVER=$(find "$ROOT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' 2>/dev/null | head -n 1)
[ -n "$KVER" ] || die "no kernel modules in $ROOT/usr/lib/modules"
KIMG=$ROOT/boot/vmlinuz-$KVER
[ -f "$KIMG" ] || die "kernel image not found: $KIMG"
KCFG=$ROOT/boot/config-$KVER
echo "mkiso: kernel $KVER"
echo "mkiso: toolchain $MKISO + isolinux from $(dirname "$ISOLINUX_BIN")"

# ---------------------------------------------------------------- iso tree
ISOT=$WORK/iso
mkdir -p "$ISOT/boot/isolinux" "$ISOT/rootfs"

echo "mkiso: staging rootfs"
cp -a "$ROOT"/. "$ISOT/rootfs/"
rm -rf "$ISOT/rootfs/var/cache/xbps/"* 2>/dev/null || true
rm -f "$ISOT/rootfs"/boot/vmlinuz-* 2>/dev/null || true

# live-only tweaks: autologin on tty1, fastfetch on login, serial console,
# root password, /sbin/init
sed -i 's/--noclear //' "$ISOT/rootfs/etc/niinit/services/getty-tty1/run" 2>/dev/null || true
sed -i 's/exec agetty/exec agetty -a root/' \
        "$ISOT/rootfs/etc/niinit/services/getty-tty1/run" 2>/dev/null || true
mkdir -p "$ISOT/rootfs/etc/niinit/services/getty-ttyS0"
printf '#!/bin/sh\nexec agetty -a root -L ttyS0 115200 vt100\n' \
        > "$ISOT/rootfs/etc/niinit/services/getty-ttyS0/run"
chmod +x "$ISOT/rootfs/etc/niinit/services/getty-ttyS0/run"
ln -sf niinit "$ISOT/rootfs/sbin/init"

# generate /etc/shadow if the install hooks did not create it
if [ ! -f "$ISOT/rootfs/etc/shadow" ]; then
        now=$(( $(date +%s) / 86400 ))
        while IFS=: read -r user _ rest; do
                printf '%s:!:%s:0:99999:7:::\n' "$user" "$now"
        done < "$ISOT/rootfs/etc/passwd" > "$ISOT/rootfs/etc/shadow"
fi

if have openssl; then
        RHASH=$(openssl passwd -6 kinini)
        sed -i "s|^root:[^:]*:|root:$RHASH:|" "$ISOT/rootfs/etc/shadow"
fi

cat > "$ISOT/rootfs/root/.bash_profile" <<'EOF'
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && command -v fastfetch >/dev/null 2>&1; then
        setfont default8x9 2>/dev/null
        fastfetch
fi
EOF

# iso9660 readdir lacks d_type; copy the pkgdb onto the writable overlay
# layer so file-type checks (fastfetch, libxbps) see regular files
sed -i '/^exit 0$/d' "$ISOT/rootfs/etc/niinit/1"
cat >> "$ISOT/rootfs/etc/niinit/1" <<'EOF'
for f in /var/db/xbps/pkgdb-*.plist; do
        [ -f "$f" ] || continue
        cp "$f" "$f.new" && mv "$f.new" "$f"
done
exit 0
EOF

cat > "$ISOT/rootfs/etc/xdg/fastfetch/config.jsonc" <<'EOF'
{
  "logo": {
    "type": "file",
    "source": "/usr/share/kinini/kiwi.txt"
  },
  "display": {
    "separator": "  "
  },
  "modules": [
    "title",
    "os",
    "host",
    "kernel",
    "packages",
    "shell",
    "terminal",
    "cpu",
    "gpu",
    "memory",
    "swap",
    "break",
    "colors"
  ]
}
EOF

# ---------------------------------------------------------------- initramfs
INITRD=$WORK/initramfs
mkdir -p "$INITRD/bin" "$INITRD/modules" "$INITRD/newroot" "$INITRD/proc" \
        "$INITRD/sys" "$INITRD/dev" "$INITRD/mnt" "$INITRD/run" "$INITRD/tmp"
cp "$BUSYBOX" "$INITRD/bin/busybox"
chmod 755 "$INITRD/bin/busybox"

echo "mkiso: copying modules for initramfs"
MODDIR=$ROOT/usr/lib/modules/$KVER
# insmod order matters: dependencies first
for m in nls_cp437 nls_ascii \
        scsi_common scsi_mod sd_mod cdrom sr_mod \
        libata libahci ahci ata_piix \
        virtio_ring virtio virtio_blk virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci \
        usb-common usbcore xhci-hcd xhci-pci ehci-hcd ehci-pci uhci-hcd usb-storage uas \
        isofs overlay \
        agpgart drm drm_kms_helper ttm drm_ttm_helper drm_vram_helper bochs; do
        f=$(find "$MODDIR/kernel" -name "$m.ko*" 2>/dev/null | head -n 1)
        [ -n "$f" ] || continue
        case "$f" in
        *.zst)
                if [ -n "$ZSTD" ]; then
                        $ZSTD -d -c "$f" > "$INITRD/modules/$m.ko"
                fi
                ;;
        *)      cp "$f" "$INITRD/modules/$m.ko" ;;
        esac
done
NMOD=$(find "$INITRD/modules" -type f 2>/dev/null | wc -l)
echo "mkiso: initramfs modules: $NMOD"

cat > "$INITRD/init" <<'EOF'
#!/bin/busybox sh
BB=/bin/busybox
$BB mkdir -p /proc /sys /dev /run /tmp /mnt /newroot
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || $BB mdev -s

for m in nls_cp437 nls_ascii \
        scsi_common scsi_mod sd_mod cdrom sr_mod \
        libata libahci ahci ata_piix \
        virtio_ring virtio virtio_blk virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci \
        usb-common usbcore xhci-hcd xhci-pci ehci-hcd ehci-pci uhci-hcd usb-storage uas \
        isofs overlay \
        agpgart drm drm_kms_helper ttm drm_ttm_helper drm_vram_helper bochs; do
        [ -f /modules/$m.ko ] && $BB insmod /modules/$m.ko 2>/dev/null
done

n=0
while [ $n -lt 20 ]; do
        [ -b /dev/sr0 ] && break
        $BB sleep 0.5
        n=$((n + 1))
done

SRCDEV=
for d in sr0 sr1; do
        if $BB mount -t iso9660 -o ro /dev/$d /mnt 2>/dev/null; then
                if [ -d /mnt/rootfs ]; then
                        SRCDEV=$d
                        break
                fi
                $BB umount /mnt
        fi
done

if [ -z "$SRCDEV" ]; then
        echo "init: no KiniNi live medium found, dropping to shell"
        exec $BB sh
fi

echo "init: live medium /dev/$SRCDEV"
$BB mount -t tmpfs -o size=768m tmpfs /run
$BB mkdir -p /run/up /run/work
$BB mount -t overlay overlay -o lowerdir=/mnt/rootfs,upperdir=/run/up,workdir=/run/work \
        /newroot

$BB mount --move /proc /newroot/proc
$BB mount --move /sys /newroot/sys
$BB mount --move /dev /newroot/dev
exec $BB switch_root /newroot /sbin/init
echo "init: switch_root failed, dropping to shell"
exec $BB sh
EOF
chmod +x "$INITRD/init"

echo "mkiso: packing initramfs"
(cd "$INITRD" && find . | LC_ALL=C sort | $CPIO | $GZIP -9) > "$ISOT/boot/initramfs.img"

# ---------------------------------------------------------------- bootloader
install -m644 "$KIMG" "$ISOT/boot/vmlinuz"
install -m644 "$ISOLINUX_BIN" "$ISOT/boot/isolinux/isolinux.bin"
install -m644 "$LDLINUX" "$ISOT/boot/isolinux/ldlinux.c32"

cat > "$ISOT/boot/isolinux/isolinux.cfg" <<'EOF'
SERIAL 0 115200
DEFAULT kinini
PROMPT 0
TIMEOUT 50

LABEL kinini
        KERNEL /boot/vmlinuz
        APPEND initrd=/boot/initramfs.img init=/sbin/niinit console=tty0 console=ttyS0,115200n8 loglevel=4

LABEL rescue
        KERNEL /boot/vmlinuz
        APPEND initrd=/boot/initramfs.img init=/bin/sh console=tty0 console=ttyS0,115200n8
EOF

# ---------------------------------------------------------------- iso image
ZOPT=""
if [ -f "$KCFG" ] && grep -q '^CONFIG_ZISOFS=y' "$KCFG" \
        && grep -q '^CONFIG_ISO9660_FS=y' "$KCFG"; then
        case "$MKISO" in
        xorriso) ZOPT="-zisofs level=9:block_size=128k:by_default=on" ;;
        *)       ZOPT="-z" ;;
        esac
        echo "mkiso: zisofs compression enabled"
fi

echo "mkiso: building $OUT"
case "$MKISO" in
xorriso)
        # shellcheck disable=SC2086
        xorriso -as mkisofs $ZOPT -R -J -joliet-long -V "$VOL" \
                -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -o "$OUT" "$ISOT"
        ;;
*)
        # shellcheck disable=SC2086
        "$MKISO" $ZOPT -R -J -joliet-long -V "$VOL" \
                -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -o "$OUT" "$ISOT"
        ;;
esac

if [ -n "$ISOHYBRID" ] && [ -n "$ISOHDPFX" ]; then
        echo "mkiso: making iso hybrid"
        "$ISOHYBRID" "$OUT" || echo "mkiso: warning: isohybrid failed (cd boot still works)" >&2
else
        echo "mkiso: isohybrid not available, el torito cd boot only"
fi

echo "mkiso: done: $OUT ($(du -h "$OUT" | cut -f1))"
