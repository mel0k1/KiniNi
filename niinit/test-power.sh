#!/bin/sh
# test-power.sh - smoke test kinini-power against a fake sysfs/sysctl:
# profile application (governor, EPP, usb autosuspend, writeback),
# persistence, the boot-hook 'apply' form and status output.
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$SRC/skel/usr/bin/kinini-power"
W=$(mktemp -d /tmp/kinini-power-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
FAIL=0

ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

# ------------------------------------------------------------- fake tree
# two cpus with both governors and EPP available
for c in cpu0 cpu1; do
        mkdir -p "$W/sys/devices/system/cpu/$c/cpufreq"
        printf 'performance powersave schedutil\n' \
                > "$W/sys/devices/system/cpu/$c/cpufreq/scaling_available_governors"
        echo schedutil > "$W/sys/devices/system/cpu/$c/cpufreq/scaling_governor"
        printf 'default performance balance_performance balance_power power\n' \
                > "$W/sys/devices/system/cpu/$c/cpufreq/energy_performance_available_preferences"
        echo default > "$W/sys/devices/system/cpu/$c/cpufreq/energy_performance_preference"
done
# two usb devices with autosuspend control
for u in 1-1 1-2; do
        mkdir -p "$W/sys/bus/usb/devices/$u/power"
        echo on > "$W/sys/bus/usb/devices/$u/power/control"
done
mkdir -p "$W/sys/class/net/wlan0/wireless"

cat > "$W/sysctl" <<'EOF'
#!/bin/sh
echo "$@" >> "$SYSCTL_LOG"
case "$1" in
-n)     echo 1500 ;;
esac
exit 0
EOF
cat > "$W/iw" <<'EOF'
#!/bin/sh
echo "iw $@" >> "$IW_LOG"
exit 0
EOF
chmod +x "$W/sysctl" "$W/iw"

export KININI_POWER_SYS="$W/sys"
export KININI_POWER_CONF="$W/power.conf"
export KININI_POWER_SYSCTL="$W/sysctl"
export KININI_POWER_IW="$W/iw"
SYSCTL_LOG="$W/sysctl.log"
IW_LOG="$W/iw.log"
export SYSCTL_LOG IW_LOG
: > "$SYSCTL_LOG"
: > "$IW_LOG"

# ---------------------------------------------------------------- tests
# 1. battery profile: governor, EPP, usb autosuspend, writeback, persist
out=$(sh "$TOOL" battery 2>&1)
if echo "$out" | grep -q 'governor: powersave'; then
        ok "battery sets powersave governor"
else
        bad "governor: $(echo "$out" | head -3)"
fi
for c in cpu0 cpu1; do
        if [ "$(cat "$W/sys/devices/system/cpu/$c/cpufreq/scaling_governor")" = powersave ]; then
                ok "$c governor file updated"
        else
                bad "$c governor file"
        fi
done
if echo "$out" | grep -q 'EPP: balance_power'; then
        ok "battery sets balance_power EPP"
else
        bad "epp: $out"
fi
if grep -q '^auto$' "$W/sys/bus/usb/devices/1-1/power/control"          && grep -q '^auto$' "$W/sys/bus/usb/devices/1-2/power/control"; then
        ok "usb autosuspend=auto on both devices"
else
        bad "usb autosuspend not applied"
fi
if grep -q 'vm.dirty_writeback_centisecs=1500' "$SYSCTL_LOG"; then
        ok "battery writeback 1500cs"
else
        bad "writeback: $(cat "$SYSCTL_LOG")"
fi
if grep -q 'power_save on' "$IW_LOG"; then
        ok "wifi power_save on"
else
        bad "iw: $(cat "$IW_LOG")"
fi
if grep -q '^KININI_POWER_PROFILE=battery$' "$KININI_POWER_CONF"; then
        ok "profile persisted"
else
        bad "persist: $(cat "$KININI_POWER_CONF" 2>/dev/null)"
fi

# 2. perf profile flips everything back
: > "$SYSCTL_LOG"
: > "$IW_LOG"
out=$(sh "$TOOL" perf 2>&1)
if echo "$out" | grep -q 'governor: performance'; then
        ok "perf sets performance governor"
else
        bad "perf governor: $out"
fi
if grep -q '^on$' "$W/sys/bus/usb/devices/1-1/power/control"; then
        ok "usb autosuspend back to on"
else
        bad "usb on: $(cat "$W/sys/bus/usb/devices/1-1/power/control")"
fi
if grep -q 'vm.dirty_writeback_centisecs=500' "$SYSCTL_LOG"; then
        ok "perf writeback 500cs"
else
        bad "perf writeback: $(cat "$SYSCTL_LOG")"
fi
if grep -q 'power_save off' "$IW_LOG"; then
        ok "wifi power_save off"
else
        bad "perf iw: $(cat "$IW_LOG")"
fi
if grep -q '^KININI_POWER_PROFILE=perf$' "$KININI_POWER_CONF"; then
        ok "perf profile persisted"
else
        bad "perf persist: $(cat "$KININI_POWER_CONF")"
fi

# 3. apply battery: hardware only, no scx call, no persist rewrite
printf '# written by kinini-power (applied at boot by 1.d/85-power)\nKININI_POWER_PROFILE=perf\n' \
        > "$KININI_POWER_CONF"
out=$(sh "$TOOL" apply battery 2>&1)
if echo "$out" | grep -q 'power profile: battery' \
        && ! echo "$out" | grep -q 'persisted'; then
        ok "apply touches hardware without persisting"
else
        bad "apply: $out"
fi
if grep -q '^KININI_POWER_PROFILE=perf$' "$KININI_POWER_CONF"; then
        ok "apply left the persisted profile alone"
else
        bad "apply overwrote persistence"
fi

# 4. status reflects the config + hardware
out=$(sh "$TOOL" status 2>&1)
if echo "$out" | grep -q 'profile:    perf'          && echo "$out" | grep -q 'governor:   powersave'; then
        ok "status shows persisted profile and live governor"
else
        bad "status: $out"
fi

# 5. unknown profile refused (usage + exit 2)
if sh "$TOOL" turbo >/dev/null 2>&1; then
        bad "unknown profile accepted"
else
        ok "unknown profile refused"
fi

if [ "$FAIL" = 0 ]; then
        printf '%s\n' "test-power: ALL OK"
else
        printf '%s\n' "test-power: FAILURES"
        exit 1
fi
