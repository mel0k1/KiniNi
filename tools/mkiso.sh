#!/bin/sh
# build a bootable KiniNi live iso from a rootfs
# usage: mkiso.sh <rootdir> <output.iso>
#
# the iso boots on BIOS (isolinux) and, when the grub efi toolchain is
# present, on UEFI (standalone grub x86_64-efi on an appended FAT ESP,
# grub-mkrescue-style hybrid). both boot the same kernel/initramfs.
#
# env overrides:
#   BUSYBOX       static busybox for the initramfs
#   SYSLINUX_DIR  directory with isolinux.bin, isohdpfx.bin, ldlinux.c32
#   ISOHYBRID     isohybrid binary (optional, usb hybrid boot, bios-only iso)
#   MKISO         genisoimage/mkisofs/xorriso (auto-detected)
#   CPIO          cpio command (auto-detected)
#   ISOVOLUME     volume label (default KININI_LIVE)
#   GRUB_MKIMAGE  grub-mkimage binary (auto-detected)
#   GRUB_EFI_DIR  dir with x86_64-efi modules (default /usr/lib/grub/x86_64-efi)
#   MKFS_VFAT     mkfs.vfat binary (auto-detected)
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
            /usr/lib/syslinux/modules/bios /usr/lib/syslinux \
            /usr/share/syslinux; do
                [ -n "$d" ] && [ -f "$d/$_f" ] && { echo "$d/$_f"; return 0; }
        done
        return 1
}

ISOLINUX_BIN=$(find_syslinux_file isolinux.bin) || die "isolinux.bin not found (set SYSLINUX_DIR=...)"
LDLINUX=$(find_syslinux_file ldlinux.c32) || die "ldlinux.c32 not found (set SYSLINUX_DIR=...)"
ISOHDPFX=$(find_syslinux_file isohdpfx.bin || true)
ISOHYBRID=${ISOHYBRID:-$(command -v isohybrid 2>/dev/null || true)}

# ---------------------------------------------------------------- uefi
# UEFI boot needs: grub-mkimage + x86_64-efi modules, mkfs.vfat and
# mtools (mmd/mcopy) to populate the FAT ESP image without root.
GRUB_MKIMAGE=${GRUB_MKIMAGE:-$(command -v grub-mkimage 2>/dev/null || true)}
GRUB_EFI_DIR=${GRUB_EFI_DIR:-}
if [ -z "$GRUB_EFI_DIR" ]; then
        for d in /usr/lib/grub/x86_64-efi /usr/share/grub/x86_64-efi; do
                [ -d "$d" ] && { GRUB_EFI_DIR=$d; break; }
        done
fi
MKFS_VFAT=${MKFS_VFAT:-$(command -v mkfs.vfat 2>/dev/null || command -v mkfs.fat 2>/dev/null || true)}
UEFI=0
if [ -n "$GRUB_MKIMAGE" ] && [ -n "$GRUB_EFI_DIR" ] && [ -n "$MKFS_VFAT" ] \
        && have mmd && have mcopy; then
        UEFI=1
        echo "mkiso: UEFI boot enabled (grub x86_64-efi from $GRUB_EFI_DIR)"
else
        echo "mkiso: warning: UEFI boot disabled (need grub-mkimage," >&2
        echo "mkiso:          /usr/lib/grub/x86_64-efi, mkfs.vfat and mtools)" >&2
fi
# the disk installer re-uses the standalone EFI binary offline
if [ "$UEFI" = 1 ]; then
        if [ -x "$ROOT/usr/sbin/mkfs.vfat" ] || [ -x "$ROOT/usr/bin/mkfs.vfat" ]; then
                :
        else
                echo "mkiso: warning: dosfstools missing from the rootfs:" >&2
                echo "mkiso:          kiwi-install will not be able to format an ESP" >&2
        fi
fi

# ---------------------------------------------------------------- kernel
KVER=$(find "$ROOT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' 2>/dev/null | head -n 1)
[ -n "$KVER" ] || die "no kernel modules in $ROOT/usr/lib/modules"
KIMG=$ROOT/boot/vmlinuz-$KVER
[ -f "$KIMG" ] || die "kernel image not found: $KIMG"
KCFG=$ROOT/boot/config-$KVER
echo "mkiso: kernel $KVER"
echo "mkiso: toolchain $MKISO + isolinux from $(dirname "$ISOLINUX_BIN")"

# the disk installer boots the KiniNi kernel when it was staged into the
# rootfs (CI runs tools/mkkernel.sh); that kernel has every driver the
# initramfs needs built in, so the disk initramfs ships no modules at
# all - void-kernel modules would not even load (struct module size
# mismatch). only the live-kernel fallback path needs modules.
KININI_STAGED=0
if [ -f "$ROOT/usr/lib/kinini/vmlinuz-kinini" ] \
        && [ -f "$ROOT/usr/lib/kinini/kver" ]; then
        KININI_STAGED=1
fi

# the disk installer needs these at runtime
for f in "$ROOT/usr/bin/extlinux" "$ROOT/usr/lib/syslinux/mbr.bin" \
        "$ROOT/usr/lib/syslinux/ldlinux.c32"; do
        [ -f "$f" ] || die "$f missing - add 'syslinux' to the rootfs packages"
done

# ---------------------------------------------------------------- iso tree
ISOT=$WORK/iso
mkdir -p "$ISOT/boot/isolinux" "$ISOT/rootfs"

echo "mkiso: staging rootfs"
cp -a "$ROOT"/. "$ISOT/rootfs/"
rm -rf "$ISOT/rootfs/var/cache/xbps/"* 2>/dev/null || true
rm -f "$ISOT/rootfs"/boot/vmlinuz-* 2>/dev/null || true

# live-only tweaks: autologin on tty1, fastfetch on login, serial console,
# root password, /sbin/init, DHCP client on
sed -i 's/--noclear //' "$ISOT/rootfs/etc/niinit/services/getty-tty1/run" 2>/dev/null || true
sed -i 's/exec agetty/exec agetty -a root/' \
        "$ISOT/rootfs/etc/niinit/services/getty-tty1/run" 2>/dev/null || true
mkdir -p "$ISOT/rootfs/etc/niinit/services/getty-ttyS0"
printf '#!/bin/sh\nexec agetty -a root -L ttyS0 115200 vt100\n' \
        > "$ISOT/rootfs/etc/niinit/services/getty-ttyS0/run"
chmod +x "$ISOT/rootfs/etc/niinit/services/getty-ttyS0/run"
# enable DHCP on the live system (network for kipki out of the box);
# the installed system chooses during kiwi-install. a real directory
# copy, not a symlink: symlinked service dirs in the iso9660 lower
# layer of the live overlay do not survive the supervisor's spawn
# (real dirs demonstrably do - getty-ttyS0). on the installed ext4
# root kiwi-install keeps using symlinks, where they work.
if [ -d "$ISOT/rootfs/etc/niinit/services-available/dhcpcd" ]; then
        rm -rf "$ISOT/rootfs/etc/niinit/services/dhcpcd"
        cp -a "$ISOT/rootfs/etc/niinit/services-available/dhcpcd" \
                "$ISOT/rootfs/etc/niinit/services/dhcpcd"
fi
ln -sf niinit "$ISOT/rootfs/sbin/init"

# marker consumed by the grub EFI binary (search --file /.kinini-live):
# finds the right filesystem on cd, usb hybrid and installed-disk boots
: > "$ISOT/.kinini-live"

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
LIVEMODS="nls_cp437 nls_ascii \
        scsi_common scsi_mod sd_mod cdrom sr_mod \
        libata libahci ahci ata_piix \
        virtio_ring virtio virtio_blk virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci \
        usb-common usbcore xhci-hcd xhci-pci ehci-hcd ehci-pci uhci-hcd usb-storage uas \
        isofs overlay \
        agpgart drm drm_kms_helper ttm drm_ttm_helper drm_vram_helper bochs"
# disk boot: storage chain + ext4 stack + dm-crypt/LUKS2 crypto, no cd/drm
DISKMODS="scsi_common scsi_mod sd_mod \
        libata libahci ahci ata_piix \
        virtio_ring virtio virtio_blk virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci \
        usb-common usbcore xhci-hcd xhci-pci ehci-hcd ehci-pci uhci-hcd usb-storage uas \
        crc16 crc32c_generic crc32c_intel mbcache jbd2 ext4 \
        dm_mod dm_bufio gf128mul crypto_simd cryptd aesni_intel aes_x86_64 \
        xts sha256_generic sha256_ssse3 hmac dm_crypt"

copy_modules() {
        _dst=$1
        shift
        for m in "$@"; do
                f=$(find "$MODDIR/kernel" -name "$m.ko*" 2>/dev/null | head -n 1)
                [ -n "$f" ] || continue
                case "$f" in
                *.zst)
                        if [ -n "$ZSTD" ]; then
                                $ZSTD -d -c "$f" > "$_dst/$m.ko"
                        fi
                        ;;
                *)      cp "$f" "$_dst/$m.ko" ;;
                esac
        done
}

mkdir -p "$INITRD/modules"
# shellcheck disable=SC2086
copy_modules "$INITRD/modules" $LIVEMODS
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

# ------------------------------------------------------- disk initramfs
# a second, smaller initramfs for the disk installer: mounts root=UUID=...
DINITRD=$WORK/initramfs-disk
mkdir -p "$DINITRD/bin" "$DINITRD/modules" "$DINITRD/newroot" "$DINITRD/proc" \
        "$DINITRD/sys" "$DINITRD/dev"
cp "$BUSYBOX" "$DINITRD/bin/busybox"
chmod 755 "$DINITRD/bin/busybox"
if [ "$KININI_STAGED" = 1 ]; then
        echo "mkiso: disk initramfs: no kernel modules (KiniNi kernel has all drivers built in)"
else
        # shellcheck disable=SC2086
        copy_modules "$DINITRD/modules" $DISKMODS
        DMOD=$(find "$DINITRD/modules" -type f 2>/dev/null | wc -l)
        echo "mkiso: disk initramfs modules: $DMOD"
fi

cat > "$DINITRD/init" <<'EOF'
#!/bin/busybox sh
BB=/bin/busybox
export LD_LIBRARY_PATH=/usr/lib
$BB mkdir -p /proc /sys /dev /newroot
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || $BB mdev -s

for m in scsi_common scsi_mod sd_mod \
        libata libahci ahci ata_piix \
        virtio_ring virtio virtio_blk virtio_pci_legacy_dev virtio_pci_modern_dev virtio_pci \
        usb-common usbcore xhci-hcd xhci-pci ehci-hcd ehci-pci uhci-hcd usb-storage uas \
        crc16 crc32c_generic crc32c_intel mbcache jbd2 ext4 \
        dm_mod gf128mul crypto_simd cryptd aesni_intel aes_x86_64 \
        xts sha256_generic sha256_ssse3 hmac dm_bufio dm_crypt; do
        [ -f /modules/$m.ko ] && $BB insmod /modules/$m.ko 2>/dev/null
done

ROOT=
LUKSUUID=
for o in $($BB cat /proc/cmdline); do
        case "$o" in
        root=*)         ROOT=${o#root=} ;;
        rd.luks.uuid=*) LUKSUUID=${o#rd.luks.uuid=} ;;
        esac
done

[ -n "$ROOT" ] || {
        echo "init: no root= on the command line, dropping to shell"
        exec $BB sh
}

# LUKS root: find the container by its UUID and unlock it with a
# passphrase typed on the console (three attempts, then a rescue shell)
if [ -n "$LUKSUUID" ]; then
        [ -x /usr/bin/cryptsetup ] || {
                echo "init: rd.luks.uuid= given but cryptsetup is not in the initramfs"
                exec $BB sh
        }
        LUDEV=
        n=0
        while [ $n -lt 40 ]; do
                # busybox blkid reads the LUKS1 uuid offset, which is garbage
                # for LUKS2 headers - so also resolve the container by asking
                # cryptsetup for the uuid of every partition
                LUDEV=$($BB blkid -U "$LUKSUUID" 2>/dev/null)
                if [ -z "$LUDEV" ]; then
                        for d in $($BB sh -c 'echo /dev/vd*[0-9] /dev/sd*[0-9] \
                                /dev/nvme*n*p*[0-9]' 2>/dev/null); do
                                [ -b "$d" ] || continue
                                u=$(/usr/bin/cryptsetup luksUUID "$d" 2>/dev/null) \
                                        || continue
                                if [ "$u" = "$LUKSUUID" ]; then
                                        LUDEV=$d
                                        break
                                fi
                        done
                fi
                [ -n "$LUDEV" ] && break
                $BB sleep 0.5
                n=$(( n + 1 ))
        done
        [ -n "$LUDEV" ] || {
                echo "init: LUKS device $LUKSUUID not found, dropping to shell"
                exec $BB sh
        }
        echo "init: LUKS container $LUDEV"
        try=1
        while [ $try -le 3 ]; do
                printf 'luks passphrase (%s/3): ' "$try"
                $BB stty -echo 2>/dev/null
                read -r PW
                $BB stty echo 2>/dev/null
                echo
                if $BB [ -n "$PW" ] && printf '%s' "$PW" \
                        | /usr/bin/cryptsetup open "$LUDEV" kinini; then
                        break
                fi
                echo "init: unlock failed (wrong passphrase?)"
                try=$(( try + 1 ))
        done
        $BB [ $try -le 3 ] || exec $BB sh
        [ -b /dev/mapper/kinini ] || {
                echo "init: /dev/mapper/kinini did not appear, dropping to shell"
                exec $BB sh
        }
        ROOT=/dev/mapper/kinini
fi

ROOTDEV=
if [ "${ROOT#UUID=}" != "$ROOT" ]; then
        want=${ROOT#UUID=}
        n=0
        while [ $n -lt 30 ]; do
                # blkid applet may be absent (stripped busybox builds):
                # fall back to probe-mounting candidate devices
                ROOTDEV=$($BB blkid -U "$want" 2>/dev/null)
                [ -n "$ROOTDEV" ] && break
                for d in $($BB sh -c 'echo /dev/sd*[0-9] /dev/vd*[0-9] \
                        /dev/hd*[0-9] /dev/nvme*n*p*[0-9]' 2>/dev/null); do
                        [ -b "$d" ] || continue
                        if $BB mount -t ext4 -o ro "$d" /newroot \
                                2>/dev/null; then
                                if [ -x /newroot/sbin/init ]; then
                                        ROOTDEV=$d
                                        $BB umount /newroot
                                        break
                                fi
                                $BB umount /newroot
                        fi
                done
                [ -n "$ROOTDEV" ] && break
                $BB sleep 0.5
                n=$((n + 1))
        done
else
        ROOTDEV=$ROOT
fi

[ -n "$ROOTDEV" ] && [ -b "$ROOTDEV" ] || {
        echo "init: root device $ROOT not found, dropping to shell"
        exec $BB sh
}

echo "init: mounting root $ROOTDEV"
$BB mount -o rw "$ROOTDEV" /newroot || {
        echo "init: mount root failed, dropping to shell"
        exec $BB sh
}

$BB mount --move /proc /newroot/proc
$BB mount --move /sys /newroot/sys
$BB mount --move /dev /newroot/dev
exec $BB switch_root /newroot /sbin/init
echo "init: switch_root failed, dropping to shell"
exec $BB sh
EOF
chmod +x "$DINITRD/init"

# cryptsetup + shared library closure for LUKS unlocking in the disk
# initramfs. the closure is resolved by running the rootfs' own dynamic
# loader with LD_LIBRARY_PATH, so this works on any build host.
CRYPTBIN=$ROOT/usr/bin/cryptsetup
if [ -f "$CRYPTBIN" ] && [ -f "$ROOT/usr/lib/ld-linux-x86-64.so.2" ]; then
        echo "mkiso: adding cryptsetup to the disk initramfs"
        mkdir -p "$DINITRD/usr/bin" "$DINITRD/usr/lib"
        cp "$CRYPTBIN" "$DINITRD/usr/bin/cryptsetup"
        chmod 755 "$DINITRD/usr/bin/cryptsetup"
        LIBS=$(LD_LIBRARY_PATH="$ROOT/usr/lib" \
                "$ROOT/usr/lib/ld-linux-x86-64.so.2" --inhibit-cache --list "$CRYPTBIN" 2>/dev/null \
                | sed -n 's/.*=> \([^ ]*\).*/\1/p')
        # shellcheck disable=SC2086
        for lib in $LIBS "$ROOT/usr/lib/ld-linux-x86-64.so.2"; do
                case "$lib" in
                "$ROOT"/*)      ;;
                *)      die "cryptsetup lib outside the rootfs: $lib" ;;
                esac
                cp -L "$lib" "$DINITRD/usr/lib/$(basename "$lib")"
        done
        # void binaries carry PT_INTERP=/lib64/ld-linux-x86-64.so.2:
        # the loader must exist at that exact path too, or the kernel's
        # execve of cryptsetup fails with ENOENT (silently eaten by the
        # init's 2>/dev/null)
        mkdir -p "$DINITRD/lib64"
        cp -L "$ROOT/usr/lib/ld-linux-x86-64.so.2" \
                "$DINITRD/lib64/ld-linux-x86-64.so.2"
        # verify the closure by executing cryptsetup the way the guest
        # kernel would (through PT_INTERP inside the chroot); fall back
        # to an explicit-loader check when chroot is unavailable
        if [ "$(id -u)" = 0 ] && command -v chroot >/dev/null 2>&1; then
                if ! COUT=$(chroot "$DINITRD" /usr/bin/cryptsetup --version 2>&1); then
                        echo "mkiso: cryptsetup exec check output: $COUT" >&2
                        die "cryptsetup cannot exec inside the initramfs"
                fi
        elif ! LD_LIBRARY_PATH="$DINITRD/usr/lib" \
                "$DINITRD/usr/lib/ld-linux-x86-64.so.2" --list \
                "$DINITRD/usr/bin/cryptsetup" >/dev/null 2>&1; then
                die "cryptsetup closure incomplete in the disk initramfs"
        fi
        CRYPTLIBS=$(find "$DINITRD/usr/lib" -type f | wc -l)
        echo "mkiso: disk initramfs: cryptsetup + $CRYPTLIBS libs"
else
        echo "mkiso: warning: cryptsetup missing from the rootfs," >&2
        echo "mkiso:          the disk initramfs will not support LUKS" >&2
fi

echo "mkiso: packing disk initramfs"
(cd "$DINITRD" && find . | LC_ALL=C sort | $CPIO | $GZIP -9) \
        > "$WORK/initramfs-disk.img"

# ---------------------------------------------------------------- uefi image
# a standalone grub x86_64-efi: the early config locates the filesystem
# holding /.kinini-live (cd iso9660, usb hybrid, installed ext4 root or
# the ESP of a LUKS install) and chains /boot/grub/grub.cfg from it.
# embedded in the ESP image for el torito (-e) and appended-partition
# (USB) boots, and shipped inside the live rootfs for the offline UEFI
# path of kiwi-install.
if [ "$UEFI" = 1 ]; then
        echo "mkiso: building grub x86_64-efi standalone image"
        # the embedded early config runs in grub's minimal command
        # context: no if/else, no comments - only simple commands.
        # the /.kinini-live marker therefore must exist on whatever
        # filesystem grub can read: on the live iso itself, on the
        # installed ext4 root (plain), and on the ESP (LUKS installs,
        # where kiwi-install mirrors the /boot layout onto the ESP).
        cat > "$WORK/early.cfg" <<'EOF'
echo KININI-EFI: searching for the boot marker
search --file --set=root /.kinini-live
echo KININI-EFI: root=$root
set prefix=($root)/boot/grub
echo KININI-EFI: loading ($prefix)/grub.cfg
normal
EOF
        if ! "$GRUB_MKIMAGE" -O x86_64-efi -d "$GRUB_EFI_DIR" \
                -o "$WORK/BOOTX64.EFI" -c "$WORK/early.cfg" \
                -p '(memdisk)/boot/grub' \
                boot configfile echo ext2 fat iso9660 gzio linux ls normal \
                part_gpt part_msdos search search_fs_file search_fs_uuid \
                search_label sleep test efi_gop; then
                echo "mkiso: warning: grub-mkimage failed, building BIOS-only" >&2
                UEFI=0
        fi
fi

if [ "$UEFI" = 1 ]; then
        echo "mkiso: building efiboot.img (ESP)"
        rm -f "$WORK/efiboot.img"
        if ! "$MKFS_VFAT" -C -n KININI_EFI "$WORK/efiboot.img" 16384 \
                >/dev/null 2>&1; then
                echo "mkiso: warning: mkfs.vfat failed, building BIOS-only" >&2
                UEFI=0
        fi
fi

if [ "$UEFI" = 1 ]; then
        if mmd -i "$WORK/efiboot.img" ::/EFI ::/EFI/BOOT \
                && mcopy -i "$WORK/efiboot.img" "$WORK/BOOTX64.EFI" \
                        ::/EFI/BOOT/BOOTX64.EFI; then
                mkdir -p "$ISOT/boot/grub"
                cat > "$ISOT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "KiniNi Linux live" {
        linux /boot/vmlinuz init=/sbin/niinit console=tty0 console=ttyS0,115200n8 loglevel=4
        initrd /boot/initramfs.img
}

menuentry "KiniNi Linux live (rescue shell)" {
        linux /boot/vmlinuz init=/bin/sh console=tty0 console=ttyS0,115200n8
        initrd /boot/initramfs.img
}
EOF
        else
                echo "mkiso: warning: cannot populate efiboot.img, building BIOS-only" >&2
                UEFI=0
        fi
fi

# ---------------------------------------------------------------- bootloader
install -m644 "$KIMG" "$ISOT/boot/vmlinuz"
install -m644 "$ISOLINUX_BIN" "$ISOT/boot/isolinux/isolinux.bin"
install -m644 "$LDLINUX" "$ISOT/boot/isolinux/ldlinux.c32"

# ship the installer artifacts inside the live rootfs
# (the kernel is kept for the disk installer: rootfs /boot is pruned)
mkdir -p "$ISOT/rootfs/usr/lib/kinini" "$ISOT/rootfs/usr/sbin"
install -m644 "$KIMG" "$ISOT/rootfs/usr/lib/kinini/vmlinuz"
# the disk installer prefers the KiniNi kernel (vanilla LTS, sched_ext
# enabled, all drivers built in) when it was staged into the rootfs
# before the iso build (CI runs tools/mkkernel.sh)
if [ -f "$ROOT/usr/lib/kinini/vmlinuz-kinini" ] \
        && [ -f "$ROOT/usr/lib/kinini/kver" ]; then
        KININI_KVER=$(cat "$ROOT/usr/lib/kinini/kver")
        [ -n "$KININI_KVER" ] || die "empty /usr/lib/kinini/kver"
        echo "mkiso: disk kernel: KiniNi $KININI_KVER (sched_ext)"
        install -m644 "$ROOT/usr/lib/kinini/vmlinuz-kinini" \
                "$ISOT/rootfs/usr/lib/kinini/vmlinuz"
else
        echo "mkiso: no kinini kernel staged, the installer will use the live kernel"
fi
install -m644 "$WORK/initramfs-disk.img" \
        "$ISOT/rootfs/usr/lib/kinini/initramfs-disk.img"
[ "$UEFI" = 1 ] && install -m755 "$WORK/BOOTX64.EFI" \
        "$ISOT/rootfs/usr/lib/kinini/BOOTX64.EFI"
INSTALLER=$(dirname "$0")/kiwi-install
[ -f "$INSTALLER" ] || die "kiwi-install not found next to mkiso.sh"
install -m755 "$INSTALLER" "$ISOT/rootfs/usr/sbin/kiwi-install"

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
if [ "$UEFI" = 1 ]; then
        # grub-mkrescue-style BIOS+UEFI hybrid: isolinux el torito for the
        # BIOS, the appended FAT ESP as the second el torito entry for UEFI
        # and as GPT partition 2 for USB boots; isohdpfx MBR covers BIOS USB.
        [ "$MKISO" = "xorriso" ] \
                || die "UEFI boot requires xorriso (set MKISO=xorriso)"
        [ -n "$ISOHDPFX" ] \
                || die "isohdpfx.bin not found (needed for the hybrid BIOS+UEFI layout)"
        # shellcheck disable=SC2086
        xorriso -as mkisofs $ZOPT -R -J -joliet-long -V "$VOL" \
                -isohybrid-mbr "$ISOHDPFX" \
                -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -eltorito-alt-boot \
                -e '--interval:appended_partition_2:::' -no-emul-boot \
                -append_partition 2 0xef "$WORK/efiboot.img" \
                -o "$OUT" "$ISOT"
else
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
fi

echo "mkiso: done: $OUT ($(du -h "$OUT" | cut -f1))"
