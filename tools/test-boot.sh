#!/bin/sh
# test-boot.sh - boot a KiniNi iso under QEMU and verify it over the
# serial console; optionally run the disk installer and boot the
# installed system as well.
#
# usage: test-boot.sh <iso> <bios|uefi> [install]
#
#   install  additionally: kiwi-install onto a fresh 4 GiB virtio disk,
#            power off, then boot the installed system and check it
#            (login, DHCP lease from the qemu builtin DHCP server,
#            zram swap active, tuned swappiness).
#
# env:
#   QEMU     qemu-system-x86_64 binary (auto-detected)
#   OVMF     UEFI firmware for uefi mode: a combined OVMF.fd used with
#            -bios, or OVMF_CODE.fd (then OVMF_VARS.fd must sit next to
#            it and both are used as pflash). auto-found when unset.
#   TIMEOUT  per-phase wait timeout in seconds (default 900; TCG is slow)
set -eu

usage() {
        echo "usage: $0 <iso> <bios|uefi> [install]" >&2
        exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
ISO=$(readlink -f "$1")
FW=$2
DO_INSTALL=${3:-}
case "$FW" in
bios|uefi) ;;
*) usage ;;
esac
[ -f "$ISO" ] || { echo "test-boot: $ISO not found" >&2; exit 1; }
[ "$DO_INSTALL" = install ] || [ -z "$DO_INSTALL" ] || usage

QEMU=${QEMU:-$(command -v qemu-system-x86_64 2>/dev/null || true)}
[ -n "$QEMU" ] || { echo "test-boot: qemu-system-x86_64 not found" >&2; exit 1; }

TMO=${TIMEOUT:-2400}

TMP=$(mktemp -d /tmp/kinini-boot.XXXXXX)
trap 'rm -rf "$TMP"; [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true' EXIT
LOG=$TMP/serial.log
: > "$LOG"

fail() {
        echo "test-boot: FAIL: $*" >&2
        echo "----- last 40 lines of the console log -----" >&2
        tail -40 "$LOG" >&2 || true
        exit 1
}

# ---------------------------------------------------------------- firmware
FIRMARGS=
if [ "$FW" = uefi ]; then
        ovmf=${OVMF:-}
        if [ -z "$ovmf" ]; then
                # prefer the x86_64 combined image; do not blindly glob
                # (ia32/arm builds of OVMF.fd may sit in sibling dirs)
                for d in /usr/share/edk2/x64 /usr/share/edk2/X64 \
                        /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
                        [ -f "$d/OVMF.fd" ] && { ovmf=$d/OVMF.fd; break; }
                done
        fi
        if [ -z "$ovmf" ]; then
                ovmf=$(find /usr/share /usr/lib -iname 'OVMF*.fd' 2>/dev/null \
                        | grep -iv -e secure -e code | head -n 1 || true)
        fi
        if [ -z "$ovmf" ]; then
                ovmf=$(find /usr/share /usr/lib -iname 'OVMF_CODE*.fd' \
                        2>/dev/null | head -n 1 || true)
        fi
        [ -n "$ovmf" ] || fail "no OVMF firmware found (set OVMF=...)"
        case "$ovmf" in
        *CODE*)
                code=$ovmf
                vars=$(dirname "$code")/$(basename "$code" | sed 's/CODE/VARS/')
                [ -f "$vars" ] || fail "found $code but no VARS beside it"
                cp "$vars" "$TMP/vars.fd"
                FIRMARGS="-drive if=pflash,format=raw,readonly=on,file=$code"
                FIRMARGS="$FIRMARGS -drive if=pflash,format=raw,file=$TMP/vars.fd"
                echo "test-boot: UEFI firmware $code + vars"
                ;;
        *)
                FIRMARGS="-bios $ovmf"
                echo "test-boot: UEFI firmware $ovmf"
                ;;
        esac
fi

# ---------------------------------------------------------------- qemu
mkfifo "$TMP/in"

start_qemu() {
        # start_qemu <extra args...> : keeps the console log shared
        QARGS="$*"
        # shellcheck disable=SC2086
        "$QEMU" -m 1024 -smp 2 -accel tcg -display none -monitor none \
                -serial stdio -no-reboot $FIRMARGS $QARGS \
                < "$TMP/in" >> "$LOG" 2>&1 &
        QPID=$!
        # hold the fifo open for the whole session
        exec 3>"$TMP/in"
}

send() {
        printf '%s\n' "$1" >&3
}

stop_qemu() {
        exec 3>&- 2>/dev/null || true
        [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        QPID=
        # rotate: keep per-phase assertions on a fresh log
        mv "$LOG" "$TMP/previous.log"
        LOG=$TMP/serial.log
        : > "$LOG"
}

wait_for() {
        # wait_for <pattern> <timeout sec>
        pat=$1
        tmo=$2
        start=$(date +%s)
        while :; do
                if grep -qs "$pat" "$LOG"; then
                        return 0
                fi
                if [ -n "${QPID:-}" ] && ! kill -0 "$QPID" 2>/dev/null; then
                        return 1
                fi
                now=$(date +%s)
                if [ $(( now - start )) -ge "$tmo" ]; then
                        return 1
                fi
                sleep 2
        done
}

poweroff_and_wait() {
        send poweroff
        # qemu exits on guest power-off (niinit -> reboot(2))
        n=0
        while kill -0 "$QPID" 2>/dev/null; do
                [ "$n" -ge 600 ] && return 1
                sleep 2
                n=$(( n + 2 ))
        done
        return 0
}

# ---------------------------------------------------------------- run
echo "test-boot: [$FW] booting live iso (timeout ${TMO}s per phase)"
start_qemu -cdrom "$ISO"

# the autologin shell has no configured PS1 (-bash-5.3#), so sync on an
# echoed marker instead of a prompt shape; input typed before the shell
# starts is buffered by the tty and executed once bash reads it
wait_for "automatic login" "$TMO" \
        || fail "[$FW] live boot did not reach the autologin"
send 'echo BOOT_READY'
wait_for "BOOT_READY" "$TMO" \
        || fail "[$FW] no root shell on the serial console (live boot)"
echo "test-boot: [$FW] live shell reached"

wait_for "zram-swap" 60 \
        || fail "[$FW] zram-swap did not run during stage 1"
echo "test-boot: [$FW] zram swap active"

poweroff_and_wait || fail "[$FW] guest did not power off cleanly"
stop_qemu
echo "test-boot: [$FW] live boot + poweroff OK"

if [ "$DO_INSTALL" = install ]; then
        echo "test-boot: [$FW] installing to disk (this takes a while)"
        qemu-img create -f raw "$TMP/disk.raw" 4G >/dev/null
        start_qemu -cdrom "$ISO" -drive file="$TMP/disk.raw",if=virtio,format=raw

        wait_for "automatic login" "$TMO" \
                || fail "[$FW] no live shell before install"
        send 'echo BOOT_READY'
        wait_for "BOOT_READY" "$TMO" || fail "[$FW] live shell not ready"
        send "kiwi-install -d /dev/vda -y -s 256"
        wait_for "done: KiniNi installed" "$TMO" \
                || fail "[$FW] installer did not finish"
        echo "test-boot: [$FW] install finished"
        poweroff_and_wait || fail "[$FW] guest did not power off after install"
        stop_qemu

        echo "test-boot: [$FW] booting installed system from disk"
        start_qemu -drive file="$TMP/disk.raw",if=virtio,format=raw

        wait_for "kinini login" "$TMO" \
                || fail "[$FW] installed system shows no login prompt"
        send root
        wait_for "Password" 120 || fail "[$FW] no password prompt"
        sleep 1
        send kinini
        send 'echo LOGIN_OK'
        wait_for "LOGIN_OK" 120 \
                || fail "[$FW] cannot log into the installed system"
        echo "test-boot: [$FW] installed system booted, logged in"

        send 'grep -qs zram0 /proc/swaps && echo ZRAM_OK'
        wait_for "ZRAM_OK" 60 || fail "[$FW] zram swap not active on the installed system"
        send 'sysctl -n vm.swappiness | grep -qx 150 && echo TUNE_OK'
        wait_for "TUNE_OK" 60 || fail "[$FW] tuned swappiness (150) not applied"
        send 'ip -4 addr | grep -q 10.0.2. && echo DHCP_OK'
        wait_for "DHCP_OK" 90 || fail "[$FW] no DHCP lease (dhcpcd) on the installed system"
        echo "test-boot: [$FW] zram + tuning + DHCP verified"

        poweroff_and_wait || fail "[$FW] installed system did not power off cleanly"
        stop_qemu
        echo "test-boot: [$FW] installed boot + poweroff OK"
fi

echo "test-boot: ALL OK ($FW${DO_INSTALL:+, $DO_INSTALL})"
