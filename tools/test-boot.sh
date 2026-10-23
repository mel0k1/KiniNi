#!/bin/sh
# test-boot.sh - boot a KiniNi iso under QEMU and verify it over the
# serial console. three phases, one qemu session each, so a failure
# always points at a single step:
#
#   test-boot.sh <iso> <bios|uefi> boot            live boot checks
#   test-boot.sh <iso> <bios|uefi> install <disk> [luks]  run kiwi-install
#   test-boot.sh <iso> <bios|uefi> verify <disk>  [luks]  boot installed
#
# the install/verify phases use a raw disk image (create it with
# qemu-img). verify checks login, zram swap, tuned swappiness and a
# DHCP lease from the qemu builtin DHCP server. the optional "luks"
# mode installs with LUKS2 root encryption, Europe/Moscow timezone,
# ru_RU.UTF-8 locale and the scx_lavd sched_ext scheduler, then
# verifies: passphrase unlock at boot, /etc/localtime, $LANG, the
# attached scx scheduler and the ephemeral encrypted swap.
#
# env:
#   QEMU     qemu-system-x86_64 binary (auto-detected)
#   OVMF     UEFI firmware for uefi mode: a combined OVMF.fd used with
#            -bios, or OVMF_CODE.fd (then OVMF_VARS.fd must sit next to
#            it and both are used as pflash). auto-found when unset.
#   TIMEOUT  per-phase wait timeout in seconds (default 2400; TCG is slow)
set -eu

have() {
        command -v "$1" >/dev/null 2>&1
}

usage() {
        echo "usage: $0 <iso> <bios|uefi> boot" >&2
        echo "       $0 <iso> <bios|uefi> install <disk> [luks]" >&2
        echo "       $0 <iso> <bios|uefi> verify <disk> [luks]" >&2
        exit 2
}

[ $# -ge 3 ] && [ $# -le 5 ] || usage
ISO=$(readlink -f "$1")
FW=$2
PHASE=$3
case "$FW" in
bios|uefi) ;;
*) usage ;;
esac

DISK=
SCENARIO=plain
case "$PHASE" in
install|verify)
        [ $# -ge 4 ] || usage
        DISK=$(readlink -f "$4")
        [ $# -le 5 ] || usage
        SCENARIO=${5:-plain}
        case "$SCENARIO" in plain|luks) ;; *) usage ;; esac
        if [ "$PHASE" = install ]; then
                # create the image on the fly (4 GiB sparse)
                have qemu-img || { echo "test-boot: qemu-img not found" >&2; exit 1; }
                [ -f "$DISK" ] || qemu-img create -f raw "$DISK" 4G >/dev/null
        fi
        [ -f "$DISK" ] || { echo "test-boot: $DISK not found" >&2; exit 1; }
        ;;
boot)
        ;;
*)
        usage
        ;;
esac
[ -f "$ISO" ] || { echo "test-boot: $ISO not found" >&2; exit 1; }

QEMU=${QEMU:-$(command -v qemu-system-x86_64 2>/dev/null || true)}
[ -n "$QEMU" ] || { echo "test-boot: qemu-system-x86_64 not found" >&2; exit 1; }

TMO=${TIMEOUT:-2400}

TMP=$(mktemp -d /tmp/kinini-boot.XXXXXX)
QPID=
cleanup() {
        [ -n "$QPID" ] && kill "$QPID" 2>/dev/null || true
        rm -rf "$TMP"
}
trap cleanup EXIT
LOG=$TMP/serial.log
: > "$LOG"

fail() {
        echo "test-boot: FAIL: $*" >&2
        echo "----- last 120 lines of the console log -----" >&2
        tail -120 "$LOG" >&2 || true
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

# ---------------------------------------------------------------- session
mkfifo "$TMP/in"

start_qemu() {
        # start_qemu <extra args...>
        # pin the NIC explicitly: both kernels support e1000 (module in
        # the Void kernel, builtin in the KiniNi kernel) and the user
        # backend provides the SLIRP DHCP server the tests rely on
        # shellcheck disable=SC2086
        "$QEMU" -m 1024 -smp 2 -accel tcg -display none -monitor none \
                -serial stdio -no-reboot -nic user,model=e1000 $FIRMARGS "$@" \
                < "$TMP/in" >> "$LOG" 2>&1 &
        QPID=$!
        # hold the fifo open for this session; typed input is buffered by
        # the tty until the guest shell reads it
        exec 3>"$TMP/in"
}

# type the line in small chunks: qemu's 16550 fifo has been observed to
# re-deliver a chunk under tcg when a whole long line is written at once
# (deterministically duplicating e.g. "-l ru_RU.UTF-8" into
# "-l ru_RU.UTF-8.UTF-8"); pacing the input keeps the fifo from
# overfilling and the tty typeahead buffer absorbs the rest
send() {
        s=$1
        while [ "${#s}" -gt 32 ]; do
                printf '%s' "${s%"${s#????????????????????????????????}"}" >&3
                sleep 0.05
                s=${s#????????????????????????????????}
        done
        printf '%s\n' "$s" >&3
}

wait_for() {
        # wait_for <pattern> <what-we-were-doing>; fails loudly: every
        # timeout/death path prints the console tail before exiting
        pat=$1
        what=$2
        start=$(date +%s)
        while :; do
                # -e: the pattern may start with a dash (prompt shapes)
                if grep -qs -e "$pat" "$LOG"; then
                        return 0
                fi
                if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
                        fail "$what: qemu exited early (waiting for: $pat)"
                fi
                now=$(date +%s)
                if [ $(( now - start )) -ge "$TMO" ]; then
                        fail "$what: timed out after ${TMO}s (waiting for: $pat)"
                fi
                sleep 2
        done
}

poweroff_and_wait() {
        send poweroff
        # qemu exits on guest power-off (niinit -> reboot(2))
        n=0
        while kill -0 "$QPID" 2>/dev/null; do
                [ "$n" -ge 600 ] && fail "guest did not power off cleanly"
                sleep 2
                n=$(( n + 2 ))
        done
        wait "$QPID" 2>/dev/null || true
        QPID=
}

wait_live_shell() {
        # the autologin shell has no configured PS1 (-bash-5.3#), so sync
        # on an echoed marker instead of a prompt shape. markers are built
        # with a split string ("X""_OK") so the tty echo of the typed
        # command never contains the literal marker - wait_for must only
        # ever match the command's real output, not its echo.
        wait_for "automatic login" "waiting for live boot"
        # login flushes pending tty input when handing over to the shell:
        # typing too early races the flush - wait for the bash prompt
        # shape before typing anything
        wait_for "bash-5" "waiting for the live shell prompt"
        send 'echo "BOOT""_READY"'
        wait_for "BOOT_READY" "waiting for live shell"
        echo "test-boot: [$FW] live shell reached"
        wait_for "zram-swap" "waiting for zram-swap hook"
        echo "test-boot: [$FW] zram swap active"
}

wait_installed_shell() {
        wait_for "kinini login" "waiting for the installed system"
        send root
        wait_for "Password" "waiting for password prompt"
        sleep 1
        send kinini
        # login flushes the pending tty input when handing over to the
        # shell, so sync on the prompt shape before sending markers
        wait_for "bash-5" "waiting for the post-login shell"
        send 'echo "LOGIN""_OK"'
        wait_for "LOGIN_OK" "waiting for login"
        echo "test-boot: [$FW] installed system booted, logged in"
}

check_basic_tuning() {
        send 'uname -r | grep -q kinini && echo "KVER""_OK"'
        wait_for "KVER_OK" "waiting for the kinini kernel check"
        send 'grep -qs zram0 /proc/swaps && echo "ZRAM""_OK"'
        wait_for "ZRAM_OK" "waiting for zram check"
        send 'sysctl -n vm.swappiness | grep -qx 150 && echo "TUNE""_OK"'
        wait_for "TUNE_OK" "waiting for swappiness check"
        dhcp_check
}

# wait for a SLIRP DHCP lease (dhcpcd -M runs from the niinit service).
# bounded in the guest: after 30s without a lease the guest prints a
# diagnostics block (interfaces, packet counters, service state, dmesg)
# and the harness fails immediately after seeing its END marker.
dhcp_check() {
        # shellcheck disable=SC2016  # the whole command runs in the guest
        send 'n=0; until ip -4 addr | grep -q 10.0.2.; do n=$((n+1)); [ "$n" -gt 14 ] && break; sleep 2; done; if ip -4 addr | grep -q 10.0.2.; then echo "DHCP""_OK"; else echo "=== DHCP DIAG ==="; ip -4 addr | head -6; ip link | head -4; ls /sys/class/net; ps | grep -v grep | grep -i dhcp; echo "stat=[$(cat /etc/niinit/services/dhcpcd/stat 2>/dev/null)]"; ls -la /etc/niinit/services/dhcpcd/ 2>&1 | head -8; head -c 120 /etc/niinit/services/dhcpcd/run | od -c | head -4; (timeout 5 /etc/niinit/services/dhcpcd/run >/tmp/runout 2>&1); echo "run_rc=$?"; head -10 /tmp/runout; timeout 8 dhcpcd -B -M -d 2>&1 | head -14; ip -4 addr | grep -q 10.0.2. && echo "DHCP""_OK"; echo "DHCPD_DEBUG_DONE"; echo "=== END ""DIAG ==="; fi'
        n=0
        while [ "$n" -lt 90 ]; do
                grep -qs "DHCP_OK" "$LOG" && {
                        echo "test-boot: [$FW] DHCP lease verified"
                        return 0
                }
                grep -qs "END DIAG" "$LOG" \
                        && fail "no DHCP lease (diagnostics above in the console tail)"
                sleep 2
                n=$(( n + 1 ))
        done
        fail "DHCP check inconclusive (no marker, no diagnostics)"
}

# ---------------------------------------------------------------- phases
case "$PHASE" in
boot)
        echo "test-boot: [$FW] booting live iso (timeout ${TMO}s per phase)"
        start_qemu -cdrom "$ISO"
        wait_live_shell
        # baseline: the live system runs the Void kernel - a failed lease
        # here points at the CI environment, not at the KiniNi kernel
        dhcp_check
        poweroff_and_wait
        echo "test-boot: [$FW] live boot + poweroff OK"
        ;;
install)
        echo "test-boot: [$FW] installing to disk, scenario=$SCENARIO (this takes a while)"
        start_qemu -cdrom "$ISO" -drive file="$DISK",if=virtio,format=raw
        wait_live_shell
        if [ "$SCENARIO" = luks ]; then
                send 'printf kiwi123 > /root/lukskey'
                send 'kiwi-install -d /dev/vda -y -s 256 -e -p /root/lukskey -z Europe/Moscow -l ru_RU.UTF-8 -S scx_lavd'
        else
                send "kiwi-install -d /dev/vda -y -s 256"
        fi
        wait_for "done: KiniNi installed" "waiting for the installer"
        wait_for "timezone: " "waiting for the installer summary"
        echo "test-boot: [$FW] install finished"
        poweroff_and_wait
        echo "test-boot: [$FW] install + poweroff OK"
        ;;
verify)
        echo "test-boot: [$FW] booting installed system from disk (scenario=$SCENARIO)"
        start_qemu -drive file="$DISK",if=virtio,format=raw
        if [ "$SCENARIO" = luks ]; then
                # the initramfs must ask for the LUKS passphrase; if grub
                # cannot find its config it drops to the rescue shell -
                # interrogate it over the console and fail with the output
                n=0
                while :; do
                        grep -qs "luks passphrase" "$LOG" && break
                        if grep -qs "grub>" "$LOG"; then
                                send 'ls'
                                send 'ls (hd0,gpt1)/'
                                send 'ls (hd0,gpt1)/boot/'
                                send 'ls (hd0,gpt1)/boot/grub/'
                                sleep 4
                                fail "grub rescue instead of the LUKS prompt (grub ls output above)"
                        fi
                        if grep -qs "not found, dropping to shell" "$LOG"; then
                                send '/bin/busybox ls -la /dev/vda* 2>&1 | head -12'
                                send '/bin/busybox cat /proc/cmdline'
                                send '/usr/bin/cryptsetup luksUUID /dev/vda1; echo rc1=$?'
                                send '/usr/bin/cryptsetup luksUUID /dev/vda2; echo rc2=$?'
                                send '/usr/bin/cryptsetup luksUUID /dev/vda3; echo rc3=$?'
                                send '/bin/busybox ls /usr/bin /usr/lib 2>&1 | head -16'
                                sleep 5
                                fail "initramfs could not find the LUKS container (diag above)"
                        fi
                        if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
                                fail "qemu exited early (waiting for: luks passphrase)"
                        fi
                        [ "$n" -ge 600 ] && fail "no LUKS passphrase prompt after 10 min"
                        sleep 2
                        n=$(( n + 2 ))
                done
                send kiwi123
                echo "test-boot: [$FW] LUKS passphrase accepted"
        fi
        wait_installed_shell
        check_basic_tuning
        if [ "$SCENARIO" = luks ]; then
                send 'test -b /dev/mapper/kinini && echo "LUKSDEV""_OK"'
                wait_for "LUKSDEV_OK" "waiting for the LUKS device check"
                send 'readlink /etc/localtime | grep -q Europe/Moscow && echo "TZ""_OK"'
                wait_for "TZ_OK" "waiting for the timezone check"
                # shellcheck disable=SC2016
                send 'grep -qx "LANG=ru_RU.UTF-8" /etc/locale.conf && [ "$LANG" = ru_RU.UTF-8 ] && echo "LOC""_OK"'
                wait_for "LOC_OK" "waiting for the locale check"
                # shellcheck disable=SC2016
                send 'locale -a 2>/dev/null | grep -qi ru_RU && echo "LOCGEN""_OK"'
                n=0
                while ! grep -qs "LOCGEN_OK" "$LOG"; do
                        if [ "$n" -ge 720 ]; then
                                send 'echo "=== LOCGEN DIAG ==="; tail -8 /var/log/locale-gen.log 2>/dev/null; grep -v "^#" /etc/default/libc-locales | grep . | head -3; locale -a 2>/dev/null | head -5'
                                sleep 4
                                fail "ru_RU locale not generated (diag above)"
                        fi
                        if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
                                fail "qemu exited early (waiting for: LOCGEN_OK)"
                        fi
                        sleep 2
                        n=$(( n + 2 ))
                done
                echo "test-boot: [$FW] locale generation verified"
                send 'grep -qs "mapper/swap" /proc/swaps && echo "SWAPENC""_OK"'
                wait_for "SWAPENC_OK" "waiting for the encrypted swap check"
                # shellcheck disable=SC2016
                send 'dmesg | grep -q "sched_ext.*enabled" && echo "SCX""_OK"'
                n=0
                while ! grep -qs "SCX_OK" "$LOG"; do
                        if [ "$n" -ge 300 ]; then
                                send 'echo "=== SCX DIAG ==="; tail -8 /var/log/scx.log 2>/dev/null; dmesg | grep -i sched_ext | tail -3'
                                sleep 4
                                fail "scx scheduler did not attach (diag above)"
                        fi
                        if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
                                fail "qemu exited early (waiting for: SCX_OK)"
                        fi
                        sleep 2
                        n=$(( n + 2 ))
                done
                echo "test-boot: [$FW] scx scheduler attached"
                send 'grep -qs up /etc/niinit/services/scx/stat && echo "SCXUP""_OK"'
                wait_for "SCXUP_OK" "waiting for the scx service state check"
                echo "test-boot: [$FW] LUKS + timezone + locale + scx verified"
        fi
        poweroff_and_wait
        echo "test-boot: [$FW] installed boot + poweroff OK"
        ;;
esac

echo "test-boot: ALL OK ($FW $PHASE)"
