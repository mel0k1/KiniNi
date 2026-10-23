#!/bin/sh
# mkkernel.sh - build the KiniNi kernel: pure vanilla LTS tarball with the
# distro config applied over allnoconfig (kernel/kinini-x86_64.config):
# sched_ext enabled (CachyOS-style BPF CPU schedulers), BTF for the scx
# userspace, and every driver the installed system needs built in, so the
# disk initramfs ships no kernel modules at all.
#
# usage: mkkernel.sh <linux-<ver>.tar.xz> <output-dir>
#
# requires: flex bison bc perl pahole (dwarves), libelf + openssl headers.
# outputs:  <output-dir>/vmlinuz-kinini + <output-dir>/kver
set -eu

usage() {
        echo "usage: $0 <linux-<ver>.tar.xz> <output-dir>" >&2
        exit 1
}

[ $# -eq 2 ] || usage
SRCBALL=$(readlink -f "$1")
OUTDIR=$(readlink -f "$2")
[ -f "$SRCBALL" ] || { echo "mkkernel: $SRCBALL not found" >&2; exit 1; }
FRAG=$(cd "$(dirname "$0")/../kernel" && pwd)/kinini-x86_64.config
[ -f "$FRAG" ] || { echo "mkkernel: fragment $FRAG not found" >&2; exit 1; }

for t in flex bison bc pahole make gcc; do
        command -v "$t" >/dev/null 2>&1 || {
                echo "mkkernel: $t not found (install flex bison bc dwarves ...)" >&2
                exit 1
        }
done

WORK=$(mktemp -d /tmp/mkkernel.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "mkkernel: extracting $(basename "$SRCBALL")"
tar -xf "$SRCBALL" -C "$WORK"
SRCDIR=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' | head -n 1)
[ -n "$SRCDIR" ] || { echo "mkkernel: no linux-* dir in the tarball" >&2; exit 1; }
cd "$SRCDIR"

echo "mkkernel: applying KiniNi config (allnoconfig + fragment)"
make KCONFIG_ALLCONFIG="$FRAG" allnoconfig >/dev/null

# fail fast (before the long build) if a dependency did not resolve
MISSING=
for opt in 64BIT SMP PREEMPT SCHED_CLASS_EXT DEBUG_INFO_BTF DEBUG_INFO_DWARF5 \
        BPF_SYSCALL BPF_JIT CGROUPS EXT4_FS VIRTIO_MENU VIRTIO VIRTIO_PCI \
        VIRTIO_BLK VIRTIO_NET E1000 MD BLK_DEV_DM DM_CRYPT BLK_DEV_INITRD \
        RD_GZIP DEVTMPFS DEVTMPFS_MOUNT SERIAL_8250_CONSOLE PACKET VFAT_FS \
        NLS_CODEPAGE_437 EFI_PARTITION MSDOS_PARTITION SWAP ZRAM ZSMALLOC \
        IKCONFIG_PROC TCP_CONG_BBR NET_SCH_FQ IOSCHED_BFQ PCI ACPI NET_CORE \
        CRYPTO_AES_NI_INTEL CRYPTO_XTS CRYPTO_CRC32C KEYS MULTIUSER \
        BLK_DEV_SD SATA_AHCI NVME_CORE BLK_DEV_NVME EFI EFI_STUB EFIVAR_FS \
        NLS_ISO8859_1 DEBUG_FS KALLSYMS_ALL \
        PERF_EVENTS PROFILING TRACEPOINTS FTRACE FUNCTION_TRACER \
        DYNAMIC_FTRACE FTRACE_SYSCALLS KPROBES KPROBE_EVENTS BPF_EVENTS \
        CPU_FREQ CPU_FREQ_GOV_SCHEDUTIL CPU_FREQ_DEFAULT_GOV_SCHEDUTIL \
        X86_ACPI_CPUFREQ; do
        grep -q "^CONFIG_$opt=y" .config || MISSING="$MISSING $opt"
done
if [ -n "$MISSING" ]; then
        echo "mkkernel: options missing after allnoconfig:$MISSING" >&2
        echo "mkkernel: (a dependency is not met - fix the fragment)" >&2
        exit 1
fi

KVER=$(make -s kernelrelease)
echo "mkkernel: release: $KVER"
echo "mkkernel: building bzImage ($(nproc) jobs, BTF via pahole takes a while)"
make -j"$(nproc)" bzImage

[ -f arch/x86/boot/bzImage ] || { echo "mkkernel: bzImage not produced" >&2; exit 1; }
mkdir -p "$OUTDIR"
install -m644 arch/x86/boot/bzImage "$OUTDIR/vmlinuz-kinini"
printf '%s\n' "$KVER" > "$OUTDIR/kver"
echo "mkkernel: done: $OUTDIR/vmlinuz-kinini (release $KVER)"
