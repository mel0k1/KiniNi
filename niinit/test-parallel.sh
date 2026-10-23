#!/bin/sh
# smoke test for niinit-parallel: ordering, parallelism, failure
# cascades, dependency cycles and missing dependencies
set -e
BIN=$(cd "$(dirname "$0")" && pwd)/bin
T=$(mktemp -d /tmp/nptest.XXXXXX)
trap 'rm -rf $T' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
task() { # task <name> [deps...]
        name=$1; shift
        printf '#!/bin/sh\n: > "%s/%s.ran"\n' "$T" "$name" > "$T/d/$name"
        chmod +x "$T/d/$name"
        if [ $# -gt 0 ]; then : > "$T/d/$name.deps"; for d in "$@"; do
                echo "$d" >> "$T/d/$name.deps"; done; fi
}
epochof() { stat -c %Y "$1"; }

# --- 1. ordering + parallelism: a(1s) <- b, c(1s) independent
mkdir -p "$T/d"
printf '#!/bin/sh\nsleep 1\n: > "%s/a.end"\n' "$T" > "$T/d/10-a"
printf '#!/bin/sh\n: > "%s/b.start"\n' "$T" > "$T/d/20-b"
echo 10-a > "$T/d/20-b.deps"
printf '#!/bin/sh\n: > "%s/c.start"\nsleep 1\n: > "%s/c.end"\n' "$T" "$T" \
        > "$T/d/30-c"
chmod +x "$T/d/10-a" "$T/d/20-b" "$T/d/30-c"
t0=$(date +%s)
out=$("$BIN/niinit-parallel" "$T/d") || fail "1: expected rc=0: $out"
t1=$(date +%s)
for f in a.end b.start c.start; do
        [ -f "$T/$f" ] || fail "1: $f missing - not all tasks ran"
done
[ "$(epochof "$T/b.start")" -ge "$(epochof "$T/a.end")" ] \
        || fail "1: b started before its dependency a finished"
[ "$(epochof "$T/c.start")" -le "$((t0 + 1))" ] \
        || fail "1: independent task c did not start immediately"
[ $((t1 - t0)) -le 3 ] \
        || fail "1: tasks did not overlap (took $((t1 - t0))s)"
echo "1. ordering + parallelism: ok"

# --- 2. failure cascades: h fails, g (dep h) is skipped
task 10-h
task 20-g 10-h
printf '#!/bin/sh\n: > "%s/10-h.ran"\nexit 3\n' "$T" > "$T/d/10-h"
chmod +x "$T/d/10-h"
"$BIN/niinit-parallel" "$T/d" >/dev/null 2>&1 && fail "2: expected rc=1"
[ -e "$T/20-g.ran" ] && fail "2: dependent g ran despite failed dep h"
[ -e "$T/10-h.ran" ] || fail "2: h itself did not run"
echo "2. failure cascade: ok"

# --- 3. dependency cycle: e <-> f never run, rc=1
task 30-e 40-f
task 40-f 30-e
"$BIN/niinit-parallel" "$T/d" >/dev/null 2>&1 && fail "3: expected rc=1"
if [ -e "$T/30-e.ran" ] || [ -e "$T/40-f.ran" ]; then
        fail "3: cycle members ran"
fi
echo "3. cycle detection: ok"

# --- 4. missing dependency
task 50-m
printf '#!/bin/sh\n: > "%s/50-m.ran"\nno-such-task\n' "$T" \
        > "$T/d/50-m.deps"
"$BIN/niinit-parallel" "$T/d" >/dev/null 2>&1 && fail "4: expected rc=1"
[ -e "$T/50-m.ran" ] && fail "4: task with missing dep ran"
echo "4. missing dependency: ok"

# --- 5. multiple deps: z waits for both a-style deps (fresh dir:
# the broken tasks from tests 2-4 must not fail this run)
rm -rf "$T/d"; mkdir -p "$T/d"
task 60-p1
task 60-p2
task 70-z 60-p1 60-p2
"$BIN/niinit-parallel" "$T/d" >/dev/null 2>&1 || fail "5: expected rc=0"
[ -e "$T/70-z.ran" ] || fail "5: z did not run"
echo "5. multiple deps: ok"

# --- 6. comments and blanks in .deps files
rm -rf "$T/d"; mkdir -p "$T/d"
task 80-k
printf '# main dep below\n\n80-j   # not present: missing dep expected\n' \
        > "$T/d/80-k.deps"
"$BIN/niinit-parallel" "$T/d" >/dev/null 2>&1 && fail "6: expected rc=1"
echo "6. deps file comments: ok"

echo "all parallel tests passed"
