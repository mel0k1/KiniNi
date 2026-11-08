#!/bin/sh
# test-boot.sh - boot a KiniNi iso under QEMU and verify it over the
# serial console. three phases, one qemu session each, so a failure
# always points at a single step:
#
#   test-boot.sh <iso> <bios|uefi> boot            live boot checks
#   test-boot.sh <iso> <bios|uefi> install <disk> [scenario]  run kiwi-install
#   test-boot.sh <iso> <bios|uefi> verify <disk>  [scenario]  boot installed
#
# scenarios:
#   plain    kiwi-install -D /dev/vda -y -s 256 (live desktop enabled)
#   luks     LUKS2 root (-d none), Europe/Moscow, ru_RU.UTF-8, scx_lavd
#   desktop  -d xfce -u kinini -P (password file): user out of the box,
#            sudo, dbus/lightdm services, Xfce autologin in live
#
# the install/verify phases use a raw disk image (create it with
# qemu-img). verify checks login, zram swap, tuned swappiness and a
# DHCP lease from the qemu builtin DHCP server; scenario extras are
# checked on top (passphrase unlock, locales, the attached scx
# scheduler, the ephemeral encrypted swap, the created user, sudo,
# the graphical stack).
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
        echo "       $0 <iso> <bios|uefi> install <disk> [plain|luks|desktop]" >&2
        echo "       $0 <iso> <bios|uefi> verify <disk> [plain|luks|desktop]" >&2
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
        case "$SCENARIO" in plain|luks|desktop) ;; *) usage ;; esac
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
        # pin the NIC explicitly: e1000e is builtin in the current Void
        # kernels (6.12.116+) and in the KiniNi kernel - the plain e1000
        # driver stopped being resolvable by modprobe on the live iso
        # (modules.dep shipped without it) - and the user backend
        # provides the SLIRP DHCP server the tests rely on
        # shellcheck disable=SC2086
        "$QEMU" -m 1024 -smp 2 -accel tcg -display none -monitor none \
                -serial stdio -no-reboot -nic user,model=e1000e $FIRMARGS "$@" \
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

check_live_desktop() {
        # the live desktop: user 'kiwi', dbus service up, the tty1 shell
        # autologins kiwi and execs startxfce4 (xinit brings X up on the
        # fly - no display manager in the live image), the XDG autostart
        # starts the PipeWire stack in that session.
        # everything is slow under TCG: bounded poll loops with a diag
        # dump before failing.
        send 'id kiwi >/dev/null 2>&1 && echo "KIWI""_OK"'
        wait_for "KIWI_OK" "waiting for the live user check"
        send 'test -x /usr/bin/startxfce4 -a -x /usr/bin/labwc -a -x /usr/bin/lightdm && echo "DESKPKGS""_OK"'
        wait_for "DESKPKGS_OK" "waiting for the desktop packages check"
        # shellcheck disable=SC2016
        send 'grep -qs up /etc/niinit/services/dbus/stat && echo "DBUS""_OK"'
        wait_for "DBUS_OK" "waiting for the dbus service check"
        echo "test-boot: [$FW] dbus service up"
        # Xorg + xfce4-session + pipewire: tty1 autologin -> startxfce4
        # shellcheck disable=SC2016
        send 'for i in $(seq 1 240); do pgrep -x Xorg >/dev/null && pgrep -x xfce4-session >/dev/null && break; sleep 2; done; pgrep -x Xorg >/dev/null && echo "XORG""_OK"; pgrep -x xfce4-session >/dev/null && echo "XFCE""_OK"'
        n=0
        while :; do
                x=0; xf=0
                grep -qs "XORG_OK" "$LOG" && x=1
                grep -qs "XFCE_OK" "$LOG" && xf=1
                [ "$x" = 1 ] && [ "$xf" = 1 ] && break
                if [ "$n" -ge 500 ]; then
                        # shellcheck disable=SC2016
                        send 'echo "=== DESKTOP DIAG ==="; for s in dbus; do echo "$s: stat=$(cat /etc/niinit/services/$s/stat 2>/dev/null) pid=$(cat /etc/niinit/services/$s/pid 2>/dev/null)"; done; echo "-- userspace procs:"; ps -eo pid,ppid,user,comm | grep -vE " \\[[a-z]" | tail -30; echo "-- dbus-launch:"; command -v dbus-launch; echo "-- xsessions:"; ls /usr/share/xsessions 2>&1; echo "-- mem:"; free | head -2; echo "-- dri:"; ls /dev/dri 2>&1; echo "-- X11 sockets:"; ls /tmp/.X11-unix 2>&1; echo "-- X alive probe:"; ls /tmp/.X11-unix/X0 2>&1; echo "-- signal masks:"; for p in $(pgrep -x Xorg | head -1) $(pgrep -x xinit | head -1); do [ -n "$p" ] && { echo "pid $p $(cat /proc/$p/comm 2>/dev/null)"; grep -E "SigBlk|SigIgn|SigCgt|State" /proc/$p/status; cat /proc/$p/wchan 2>/dev/null; echo; }; done; echo "-- xinit USR1 probe:"; XP=$(pgrep -x xinit | head -1); [ -n "$XP" ] && kill -USR1 "$XP"; sleep 3; pgrep -x xfce4-session >/dev/null && echo "XFCE""_AFTER""_USR1" || echo "no session after USR1"; echo "-- lightdm.log (outer):"; tail -30 /var/log/lightdm.log 2>/dev/null; echo "-- lightdm.log (inner, tail 90):"; tail -90 /var/log/lightdm/lightdm.log 2>/dev/null; echo "-- x logs:"; for f in /var/log/lightdm/x-*.log /var/log/Xorg.0.log; do [ -f "$f" ] && { echo "== $f"; tail -25 "$f"; }; done; echo "-- session log:"; tail -30 /home/kiwi/.xsession-errors 2>/dev/null; echo "-- dmesg tail:"; dmesg | tail -6; echo "=== DESKDIAG""_DONE ==="'
                        sleep 30
                        fail "Xfce session did not start (diag above)"
                fi
                sleep 2
                n=$(( n + 2 ))
        done
        echo "test-boot: [$FW] Xorg + Xfce session running (autologin)"
        # shellcheck disable=SC2016
        # shellcheck disable=SC2016
        send 'for i in $(seq 1 60); do pgrep -x pipewire >/dev/null && break; sleep 2; done; pgrep -x pipewire >/dev/null && echo "PW""_OK"'
        n=0
        while ! grep -qs "PW_OK" "$LOG"; do
                if [ "$n" -ge 60 ]; then
                        # shellcheck disable=SC2016
                        send 'echo "=== AUDIO DIAG ==="; pgrep -a pipewire | head -3; pgrep -a wireplumber | head -2; echo "=== AUDIODIAG""_DONE ==="'
                        sleep 4
                        fail "pipewire did not start in the live session (diag above)"
                fi
                sleep 2
                n=$(( n + 2 ))
        done
        echo "test-boot: [$FW] PipeWire audio stack running in the user session"
}

wait_installed_shell() {
        # wait_installed_shell [USER] [PASSWORD] - root/kinini by default;
        # the desktop scenario logs in as the user created by the installer
        _user=${1:-root}
        _pass=${2:-kinini}
        wait_for "kinini login" "waiting for the installed system"
        send "$_user"
        wait_for "Password" "waiting for password prompt"
        sleep 1
        send "$_pass"
        # login flushes the pending tty input when handing over to the
        # shell, so sync on the prompt shape before sending markers
        wait_for "bash-5" "waiting for the post-login shell"
        send 'echo "LOGIN""_OK"'
        wait_for "LOGIN_OK" "waiting for login"
        echo "test-boot: [$FW] installed system booted, logged in as $_user"
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

check_desktop_install() {
        # the installed desktop: user, groups, sudo, services, X session
        send 'id | grep -q "wheel" && id | grep -q "video" && id | grep -q "audio" && id | grep -q "input" && echo "GRP""_OK"'
        wait_for "GRP_OK" "waiting for the user groups check"
        send 'echo user123 | sudo -S -p "" true && echo "SUDO""_OK"'
        wait_for "SUDO_OK" "waiting for the sudo check"
        send 'grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers.d/wheel && ! test -f /etc/sudoers.d/kinini-live && echo "WHEELCFG""_OK"'
        wait_for "WHEELCFG_OK" "waiting for the sudoers config check"
        send 'test -f /etc/lightdm/lightdm.conf && ! grep -q "^autologin-user" /etc/lightdm/lightdm.conf && echo "NOAUTO""_OK"'
        wait_for "NOAUTO_OK" "waiting for the autologin strip check"
        # shellcheck disable=SC2016
        send 'for s in dbus lightdm dhcpcd; do grep -qs up /etc/niinit/services/$s/stat || echo "DOWN$s"; done; grep -qs up /etc/niinit/services/lightdm/stat && echo "LDM""_OK"'
        n=0
        while ! grep -qs "LDM_OK" "$LOG"; do
                if [ "$n" -ge 120 ]; then
                        # shellcheck disable=SC2016
                        send 'echo "=== SVCDIAG ==="; for s in dbus lightdm dhcpcd; do echo "$s: $(cat /etc/niinit/services/$s/stat 2>/dev/null)"; done; tail -12 /var/log/lightdm.log 2>/dev/null; echo "=== SVCDIAG""_DONE ==="'
                        sleep 4
                        fail "installed desktop services not up (diag above)"
                fi
                sleep 2
                n=$(( n + 2 ))
        done
        echo "test-boot: [$FW] dbus/lightdm/dhcpcd services verified"
        # shellcheck disable=SC2016
        send 'for i in $(seq 1 240); do pgrep -x Xorg >/dev/null && break; sleep 2; done; pgrep -x Xorg >/dev/null && echo "XORG""_OK"'
        n=0
        while ! grep -qs "XORG_OK" "$LOG"; do
                if [ "$n" -ge 500 ]; then
                        # shellcheck disable=SC2016
                        send 'echo "=== XDIAG ==="; ps | grep -E "Xorg|lightdm" | grep -v grep | head -6; echo "-- lightdm.log (inner):"; tail -40 /var/log/lightdm/lightdm.log 2>/dev/null; echo "-- lightdm.log (outer):"; tail -25 /var/log/lightdm.log 2>/dev/null; for f in /var/log/lightdm/x-*.log /var/log/Xorg.0.log; do [ -f "$f" ] && { echo "== $f"; tail -20 "$f"; }; done; ls /dev/dri 2>&1; echo "=== XDIAG""_DONE ==="'
                        sleep 30
                        fail "Xorg did not start on the installed system (diag above)"
                fi
                sleep 2
                n=$(( n + 2 ))
        done
        echo "test-boot: [$FW] Xorg verified on the installed system"
}

# wait for a SLIRP DHCP lease (dhcpcd -M runs from the niinit service).
# bounded in the guest: after 30s without a lease the guest prints a
# diagnostics block (interfaces, packet counters, service state, dmesg)
# and the harness fails immediately after seeing its END marker.
dhcp_check() {
        # shellcheck disable=SC2016  # the whole command runs in the guest
        send 'n=0; until ip -4 addr | grep -q 10.0.2.; do n=$((n+1)); [ "$n" -gt 14 ] && break; sleep 2; done; if ip -4 addr | grep -q 10.0.2.; then echo "DHCP""_OK"; else echo "=== DHCP DIAG ==="; ip -4 addr | head -6; ip link | head -4; ls /sys/class/net; ps | grep -v grep | grep -i dhcp; echo "stat=[$(cat /etc/niinit/services/dhcpcd/stat 2>/dev/null)]"; ls -la /etc/niinit/services/dhcpcd/ 2>&1 | head -8; head -c 120 /etc/niinit/services/dhcpcd/run | od -c | head -4; echo "-- modprobe e1000:"; modprobe -v e1000; echo "modprobe_rc=$?"; echo "-- dmesg:"; dmesg | grep -iE "e1000|net eth|virtio_net" | tail -8; echo "-- dep:"; grep -c e1000 /lib/modules/6.12.116_1/modules.dep 2>&1; ls /lib/modules/6.12.116_1/kernel/drivers/net/ethernet/intel/e1000 2>&1 | head -3; echo "-- udev:"; ls /run/udev 2>&1 | head -3; ls /run/udev/data 2>/dev/null | head -6; udevadm settle --timeout=3 2>&1; ls /sys/class/net; (timeout 5 /etc/niinit/services/dhcpcd/run >/tmp/runout 2>&1); echo "run_rc=$?"; head -10 /tmp/runout; timeout 8 dhcpcd -B -M -d 2>&1 | head -14; ip -4 addr | grep -q 10.0.2. && echo "DHCP""_OK"; echo "DHCPD_DEBUG_DONE"; echo "=== END ""DIAG ==="; fi'
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
        check_live_desktop
        poweroff_and_wait
        echo "test-boot: [$FW] live boot + desktop + poweroff OK"
        ;;
install)
        echo "test-boot: [$FW] installing to disk, scenario=$SCENARIO (this takes a while)"
        start_qemu -cdrom "$ISO" -drive file="$DISK",if=virtio,format=raw
        wait_live_shell
        if [ "$SCENARIO" = luks ]; then
                send 'printf kiwi123 > /root/lukskey'
                send 'kiwi-install -D /dev/vda -y -s 256 -e -p /root/lukskey -z Europe/Moscow -l ru_RU.UTF-8 -S scx_lavd -d none'
        elif [ "$SCENARIO" = desktop ]; then
                send 'printf user123 > /root/upass'
                send 'kiwi-install -D /dev/vda -y -s 256 -d xfce -u kinini -P /root/upass'
        else
                send "kiwi-install -D /dev/vda -y -s 256"
        fi
        wait_for "done: KiniNi installed" "waiting for the installer"
        wait_for "desktop: " "waiting for the installer summary"
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
        if [ "$SCENARIO" = desktop ]; then
                wait_installed_shell kinini user123
        else
                wait_installed_shell
        fi
        check_basic_tuning
        if [ "$SCENARIO" = desktop ]; then
                check_desktop_install
                echo "test-boot: [$FW] desktop install verified (user + sudo + services + X)"
        fi
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
                # /proc/swaps prints the RESOLVED device path: swapon()
                # follows the /dev/mapper/swap symlink, so the kernel
                # reports /dev/dm-N. check the cryptsetup mapping and
                # the active dm swap instead of the symlink name
                send 'cryptsetup status swap >/dev/null 2>&1 && grep -qs "^/dev/dm-" /proc/swaps && echo "SWAPENC""_OK"'
                n=0
                while ! grep -qs "SWAPENC_OK" "$LOG"; do
                        if [ "$n" -ge 120 ]; then
                                # shellcheck disable=SC2016
                                send 'echo "=== SWAP DIAG ==="; cat /etc/crypttab; echo "-- by-partuuid:"; ls /dev/disk/by-partuuid/ 2>&1; echo "-- swaps:"; cat /proc/swaps; echo "-- manual open:"; cryptsetup open --type plain --key-file=/dev/urandom --cipher aes-xts-plain64 /dev/vda2 swapdiag 2>&1 | head -3; cryptsetup close swapdiag 2>/dev/null; echo "-- scx log:"; tail -6 /var/log/scx.log 2>/dev/null; echo "-- sched_ext dmesg:"; dmesg | grep -i sched_ext | tail -3; echo "=== SWAPDIAG""_DONE ==="'
                                sleep 6
                                fail "encrypted swap did not come up (diag above)"
                        fi
                        if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
                                fail "qemu exited early (waiting for: SWAPENC_OK)"
                        fi
                        sleep 2
                        n=$(( n + 2 ))
                done
                echo "test-boot: [$FW] encrypted swap verified"
                # shellcheck disable=SC2016
                send 'dmesg | grep -q "sched_ext.*enabled" && echo "SCX""_OK"'
                n=0
                while ! grep -qs "SCX_OK" "$LOG"; do
                        if [ "$n" -ge 300 ]; then
                                # shellcheck disable=SC2016
                                send 'echo "=== SCX DIAG ==="; tail -60 /var/log/scx.log 2>/dev/null; echo "-- btf:"; ls -la /sys/kernel/btf/vmlinux 2>&1; grep -ac sched_ext_ops /sys/kernel/btf/vmlinux 2>/dev/null; echo "-- dmesg:"; dmesg | grep -i -e sched_ext -e bpf | tail -8; echo "=== SCXDIAG""_DONE ==="'
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
        if [ "$SCENARIO" = desktop ]; then
                # a regular user cannot call the PID1 argv0 helpers directly:
                # sudo with the wheel sudoers (password on stdin)
                send 'echo user123 | sudo -S poweroff'
        else
                send poweroff
        fi
        # qemu exits on guest power-off (niinit -> reboot(2))
        n=0
        while kill -0 "$QPID" 2>/dev/null; do
                [ "$n" -ge 600 ] && fail "guest did not power off cleanly"
                sleep 2
                n=$(( n + 2 ))
        done
        wait "$QPID" 2>/dev/null || true
        QPID=
        echo "test-boot: [$FW] installed boot + poweroff OK"
        ;;
esac

echo "test-boot: ALL OK ($FW $PHASE)"
