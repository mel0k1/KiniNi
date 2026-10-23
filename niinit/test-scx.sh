#!/bin/sh
# functional test for kinini-scx (skel/usr/bin/kinini-scx) against a
# fake scheduler environment and a real niinit-sv supervisor
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCX=$ROOT/skel/usr/bin/kinini-scx
NIBIN=$ROOT/niinit/bin
T=$(mktemp -d /tmp/nsctest.XXXXXX)
trap 'kill ${SVPID:-0} 2>/dev/null || true; rm -rf $T' EXIT

mkdir -p "$T/bin" "$T/svdir/scx" "$T/avail/scx"
printf '#!/bin/sh\nexec scx_lavd\n' > "$T/avail/scx/run"
chmod +x "$T/avail/scx/run"
printf '#!/bin/sh\nexec scx_flash\n' > "$T/svdir/scx/run"
chmod +x "$T/svdir/scx/run"
touch "$T/log"
cat > "$T/scx.conf" << 'CONFEOF'
# test config
SCX_SCHEDULER=scx_lavd
SCX_FLAGS=
CONFEOF
# fake schedulers: they must stay alive so the supervisor has a live
# pid (a plain child sleep keeps the script process running)
for s in scx_lavd scx_bpfland scx_flash; do
        printf '#!/bin/sh\nsleep 30\n' > "$T/bin/$s"
        chmod +x "$T/bin/$s"
done
export PATH="$NIBIN:$T/bin:$PATH"
export KININI_SCX_CONF="$T/scx.conf" KININI_SCX_LOG="$T/log"
export KININI_SCX_BIN="$T/bin" NIINIT_SVDIR="$T/svdir"
export NIINIT_SVAVAIL="$T/avail"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- list marks the configured scheduler
out=$("$SCX" list)
echo "$out" | grep -q '(configured)' || fail "list: no configured mark"
echo "$out" | grep -q scx_bpfland || fail "list: scx_bpfland missing"
echo "list: ok"

# --- status on an unsupervised service
out=$("$SCX" status) || fail "status rc"
echo "$out" | grep -q 'configured:  scx_lavd' \
        || fail "status: configured wrong: $out"
echo "$out" | grep -q 'not supervised' \
        || fail "status: supervision line missing"
echo "status (down): ok"

# --- use validates the name and rewrites only its own line
"$SCX" use scx_bpfland 2>&1 | grep -q 'set to scx_bpfland' \
        || fail "use: no message"
grep -q '^SCX_SCHEDULER=scx_bpfland$' "$T/scx.conf" \
        || fail "use: conf not rewritten"
grep -q '^SCX_FLAGS=$' "$T/scx.conf" || fail "use: clobbered other lines"
"$SCX" use nosuchsched >/dev/null 2>&1 && fail "use: accepted unknown"
"$SCX" use 'bad;name' >/dev/null 2>&1 && fail "use: accepted invalid name"
echo "use validation + rewrite: ok"

# --- use --now restarts the supervised service; status shows it running
"$NIBIN/niinit-sv" "$T/svdir/scx" & SVPID=$!
sleep 1
"$SCX" use scx_flash --now 2>&1 | grep -q 'restarted with scx_flash' \
        || fail "use --now: restart did not happen"
sleep 2   # svctl restart is asynchronous: let the supervisor settle
"$SCX" status | grep -q 'scheduler:.*scx_flash' \
        || fail "status: running scheduler not shown"
echo "use --now + status: ok"

# --- on/off
"$SCX" off | grep -q 'disabled' || fail "off: message"
"$SCX" status | grep -q 'down' || fail "off: service should be down"
"$SCX" on | grep -q 'enabled' || fail "on: message"
echo "on/off: ok"

# --- log
printf 'boot log line\n' > "$T/log"
"$SCX" log 1 | grep -q 'boot log line' || fail "log: tail failed"
echo "log: ok"

# --- help
"$SCX" help > /dev/null || fail "help rc"
echo "help: ok"

echo "ALL KININI-SCX TESTS PASSED"
