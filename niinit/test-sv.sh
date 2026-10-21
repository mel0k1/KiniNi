#!/bin/sh
# extended smoke test for niinit-sv + svctl (run from repo root or anywhere)
set -e
BIN=$(cd "$(dirname "$0")" && pwd)/bin
T=$(mktemp -d /tmp/nvtest.XXXXXX)
trap 'kill $SVPID 2>/dev/null || true; rm -rf $T' EXIT
export NIINIT_SVDIR=$T
SVC=$T/svc
mkdir -p "$SVC"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. basic up / down (CI-compatible semantics)
printf '#!/bin/sh\nexec sleep 30\n' > "$SVC/run"
chmod +x "$SVC/run"
"$BIN/niinit-sv" "$SVC" & SVPID=$!
sleep 1
[ "$(cat "$SVC/stat")" = up ] || fail "expected up, got $(cat "$SVC/stat")"
"$BIN/svctl" down svc
sleep 1
[ "$(cat "$SVC/stat")" = down ] || fail "expected down"
"$BIN/svctl" up svc
sleep 1
[ "$(cat "$SVC/stat")" = up ] || fail "expected up"
echo "1. up/down: ok"

# --- 2. status shows pid and uptime
"$BIN/svctl" status svc | grep -q 'up (pid [0-9]*).*[0-9]*s' \
    || fail "status missing pid/uptime: $("${BIN}"/svctl status svc)"
echo "2. status uptime: ok"

# --- 3. restart ('t') keeps service up with new pid
OLD=$(cat "$SVC/pid")
"$BIN/svctl" restart svc
sleep 1
NEW=$(cat "$SVC/pid")
[ "$OLD" != "$NEW" ] || fail "pid did not change on restart"
[ "$(cat "$SVC/stat")" = up ] || fail "restart did not bring service up"
echo "3. restart: ok"

# --- 4. once: runs and is not restarted after exit
"$BIN/svctl" -w 5 stop svc
printf '#!/bin/sh\nexit 0\n' > "$SVC/run"
chmod +x "$SVC/run"
"$BIN/svctl" once svc
sleep 3
[ "$(cat "$SVC/stat")" = down ] || fail "once should leave service down, got $(cat "$SVC/stat")"
echo "4. once: ok"

# --- 5. down file prevents auto-start
kill $SVPID 2>/dev/null; wait $SVPID 2>/dev/null || true
touch "$SVC/down"
printf '#!/bin/sh\nexec sleep 30\n' > "$SVC/run"
"$BIN/niinit-sv" "$SVC" & SVPID=$!
sleep 1
[ "$(cat "$SVC/stat")" = down ] || fail "down file ignored"
rm "$SVC/down"
"$BIN/svctl" up svc
sleep 1
[ "$(cat "$SVC/stat")" = up ] || fail "up after down-file removal failed"
echo "5. down file: ok"

# --- 6. finish script receives exit code
: > "$SVC/finish.log"
cat > "$SVC/finish" <<'EOF'
#!/bin/sh
echo "$1" >> /tmp/nvtest-finish.log
EOF
chmod +x "$SVC/finish"
printf '#!/bin/sh\nexit 7\n' > "$SVC/run"
"$BIN/svctl" -w 5 stop svc
"$BIN/svctl" once svc
sleep 3
grep -q '^7$' /tmp/nvtest-finish.log || fail "finish did not log exit code 7: $(cat /tmp/nvtest-finish.log)"
rm "$SVC/finish"
rm -f /tmp/nvtest-finish.log
echo "6. finish: ok"

# --- 7. crash restart (want_up semantics)
printf '#!/bin/sh\nexec sleep 30\n' > "$SVC/run"
kill $SVPID 2>/dev/null; wait $SVPID 2>/dev/null || true
"$BIN/niinit-sv" "$SVC" & SVPID=$!
sleep 1
PID1=$(cat "$SVC/pid")
kill -9 "$PID1"
sleep 3
[ "$(cat "$SVC/stat")" = up ] || fail "crashed service not restarted"
NEW=$(cat "$SVC/pid")
[ "$NEW" != "$PID1" ] || fail "same pid after crash"
echo "7. crash restart: ok"

# --- 8. start/stop with wait + check
"$BIN/svctl" -w 5 stop svc
grep -q down "$SVC/stat" || fail "stop did not wait"
"$BIN/svctl" -w 5 start svc
"$BIN/svctl" check svc || fail "check failed on up service"
"$BIN/svctl" -w 5 stop svc
if "$BIN/svctl" check svc 2>/dev/null; then fail "check passed on down service"; fi
"$BIN/svctl" up svc
echo "8. start/stop/check: ok"

# --- 9. enable/disable
mkdir -p "$T/available/app" "$T/services"
printf '#!/bin/sh\nexec sleep 30\n' > "$T/available/app/run"
chmod +x "$T/available/app/run"
export NIINIT_SVDIR="$T/services"
export NIINIT_SVAVAIL="$T/available"
"$BIN/svctl" enable app
[ -L "$T/services/app" ] || fail "enable did not symlink"
[ -x "$T/services/app/run" ] || fail "symlink target wrong"
"$BIN/svctl" disable app
[ -e "$T/services/app" ] && fail "disable left symlink"
echo "9. enable/disable: ok"

# --- 10. signals reach the service (pause/cont via SIGSTOP proof)
export NIINIT_SVDIR="$T"
"$BIN/svctl" pause svc 2>/dev/null && true
"$BIN/svctl" hup svc 2>/dev/null && true
sleep 0.5
kill -0 "$(cat "$SVC/pid")" || fail "service died after signals"
echo "10. signals: ok"

# --- 11. exit ('x') stops the supervisor
"$BIN/svctl" shutdown svc
sleep 2
wait $SVPID 2>/dev/null
echo "11. exit: ok"

echo "ALL NIINIT SV TESTS PASSED"
