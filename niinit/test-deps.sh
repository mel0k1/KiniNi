#!/bin/sh
# smoke test for service dependencies in niinit-svdir:
# a service with a deps file stays blocked until its dependency is up
set -e
BIN=$(cd "$(dirname "$0")" && pwd)/bin
export PATH="$BIN:$PATH"      # niinit-svdir spawns niinit-sv via PATH
T=$(mktemp -d /tmp/ndtest.XXXXXX)
SVDIR=$T/services
AVAIL=$T/available
export NIINIT_SVDIR=$SVDIR NIINIT_SVAVAIL=$AVAIL

fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
        [ -n "${DIRPID:-}" ] && kill "$DIRPID" 2>/dev/null || true
        rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$SVDIR" "$AVAIL/db" "$AVAIL/web" "$AVAIL/late"
# db: plain service, starts immediately
printf '#!/bin/sh\nexec sleep 30\n' > "$AVAIL/db/run"
# web: depends on db
printf '#!/bin/sh\nexec sleep 30\n' > "$AVAIL/web/run"
printf '# web needs the database\ndb\n' > "$AVAIL/web/deps"
# late: depends on a service that will never exist
printf '#!/bin/sh\nexec sleep 30\n' > "$AVAIL/late/run"
printf 'nosuchsvc\n' > "$AVAIL/late/deps"
chmod +x "$AVAIL/db/run" "$AVAIL/web/run" "$AVAIL/late/run"

"$BIN/svctl" enable web
"$BIN/svctl" enable late
[ -L "$SVDIR/web" ] || fail "enable web failed"
"$BIN/niinit-svdir" "$SVDIR" & DIRPID=$!

# --- 1. web is blocked while db is not enabled
sleep 7
grep -q '^blocked' "$AVAIL/web/stat" \
        || fail "1: web should be blocked, got: $(cat "$AVAIL/web/stat" 2>/dev/null)"
grep -q "dep 'db'" "$AVAIL/web/stat" \
        || fail "1: blocked message should name the dep"
echo "1. blocked without dep: ok"

# --- 2. a missing dep name blocks with the "not enabled" message
grep -q "not enabled" "$AVAIL/late/stat" \
        || fail "2: late should be blocked on the missing dep"
[ -e "$AVAIL/late/pid" ] && fail "2: late must not have been spawned"
echo "2. missing dep stays blocked: ok"

# --- 3. enabling db unblocks web (transitively: db up -> web up)
"$BIN/svctl" enable db
sleep 12
grep -q '^up' "$AVAIL/db/stat" || fail "3: db did not come up"
grep -q '^up' "$AVAIL/web/stat" \
        || fail "3: web did not come up after db, got: $(cat "$AVAIL/web/stat")"
echo "3. unblock after dep is up: ok"

# --- 4. runit semantics: stopping the dep does not stop the dependent
"$BIN/svctl" -w 5 stop db
sleep 1
grep -q '^down' "$AVAIL/db/stat" || fail "4: db did not go down"
grep -q '^up' "$AVAIL/web/stat" \
        || fail "4: web was stopped together with its dep (runit keeps dependents)"
echo "4. dependent survives dep going down: ok"

# --- 5. late stays blocked the whole time
grep -q '^blocked' "$AVAIL/late/stat" \
        || fail "5: late should still be blocked"
echo "5. blocked service persists: ok"

kill "$DIRPID" 2>/dev/null || true
wait "$DIRPID" 2>/dev/null || true
DIRPID=
echo "all svdir dependency tests passed"
