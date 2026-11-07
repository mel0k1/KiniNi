#!/bin/sh
# test-wifi.sh - smoke test kinini-wifi with a fake wpa_cli + fake dialog.
# covers: interface detection, scan parsing (dedup + signal sort),
# encrypted connect flow (add/set/enable/select/save), duplicate network
# cleanup, hidden network entry, status output, wheel-group guard.
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$SRC/skel/usr/bin/kinini-wifi"
W=$(mktemp -d /tmp/kinini-wifi-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
FAIL=0

say() { printf '%s\n' "$*"; }
ok() { say "ok: $*"; }
bad() { say "FAIL: $*"; FAIL=1; }

# ------------------------------------------------------------- fake tree
# one wlan iface
mkdir -p "$W/sys/class/net/wlan0/wireless" "$W/sys/class/net/eth0"
# no wheel in the fake id, tests run the tool as non-root -> guarded
cat > "$W/id" <<EOF
#!/bin/sh
case "\$*" in
-Gn)    echo "\${FAKE_GROUPS:-dialout}" ;;
-u)     echo 1000 ;;
esac
EOF
chmod +x "$W/id"

# fake wpa_cli: logs every invocation, serves canned answers
cat > "$W/wpa_cli" <<'EOF'
#!/bin/sh
# drop the "-i IFACE" pair
[ "$1" = "-i" ] && shift 2
echo "$@" >> "$FAKE_LOG"
cmd=$1
case "$cmd" in
ping)           echo "PONG" ;;
status)         printf 'wpa_state=COMPLETED\nssid=FakeNet\n' ;;
scan)           echo "OK" ;;
scan_results)   if [ -s "$FAKE_RESULTS" ]; then
                        printf 'bssid / frequency / signal / flags / ssid\n'
                        cat "$FAKE_RESULTS"
                else
                        echo "No scan results yet"
                fi ;;
list_network)   printf 'network id / ssid / bssid / flags\n'
                cat "$FAKE_LIST" 2>/dev/null ;;
add_network)    echo "0" ;;
set_network)    echo "OK" ;;
enable_network) echo "OK" ;;
select_network) echo "OK" ;;
remove_network) echo "OK" ;;
save_config)    echo "OK" ;;
*)              echo "OK" ;;
esac
EOF
chmod +x "$W/wpa_cli"

# fake dialog: prints the fake choice to stderr (dialog semantics)
cat > "$W/dialog" <<'EOF'
#!/bin/sh
printf '%s\n' "$FAKE_CHOICE" >&2
exit 0
EOF
chmod +x "$W/dialog"

# fake ip: one address
cat > "$W/ip" <<'EOF'
#!/bin/sh
echo "inet 192.168.4.20/24 brd 192.168.4.255 scope global wlan0"
EOF
chmod +x "$W/ip"

FAKE_LOG="$W/calls"
FAKE_RESULTS="$W/results"
FAKE_LIST="$W/list"
export FAKE_LOG FAKE_RESULTS FAKE_LIST
: > "$FAKE_LOG"
: > "$FAKE_LIST"

export KININI_WIFI_WPA_CLI="$W/wpa_cli"
export KININI_WIFI_DIALOG="$W/dialog"
export KININI_WIFI_SYSFS="$W/sys/class/net"
export PATH="$W:$PATH"

# ---------------------------------------------------------------- tests
# 1. wheel guard: no wheel group, not root -> refused with a hint
out=$(FAKE_GROUPS=dialout sh "$TOOL" 2>&1)
case "$out" in
*wheel*)        ok "wheel guard refuses and hints" ;;
*)              bad "wheel guard: got '$out'" ;;
esac

# everything below runs with wheel
export FAKE_GROUPS="dialout wheel"

# 2. status
out=$(sh "$TOOL" status 2>&1)
case "$out" in
*wlan0*COMPLETED*FakeNet*) ok "status prints iface/state/ssid" ;;
*)                          bad "status: got '$out'" ;;
esac

# 3. encrypted connect flow through the menu (choice 1)
printf 'aa:bb:cc:dd:ee:ff\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tHomeNet\n' > "$FAKE_RESULTS"
export FAKE_CHOICE=1
out=$(sh "$TOOL" 2>&1)
case "$out" in
*done:\ connected\ to\ HomeNet*) ok "menu connect flow completed" ;;
*)                              bad "connect: got '$out'" ;;
esac
if grep -q 'add_network' "$FAKE_LOG" \
        && grep -q 'set_network 0 ssid "HomeNet"' "$FAKE_LOG" \
        && grep -q 'set_network 0 psk' "$FAKE_LOG" \
        && grep -q 'enable_network 0' "$FAKE_LOG" \
        && grep -q 'select_network 0' "$FAKE_LOG" \
        && grep -q 'save_config' "$FAKE_LOG"; then
        ok "wpa_cli call sequence"
else
        bad "wpa_cli call sequence: $(tr '\n' ';' < "$FAKE_LOG")"
fi

# 4. open network: key_mgmt NONE, no psk
: > "$FAKE_LOG"
printf 'aa:bb:cc:dd:ee:10\t2437\t-60\t[ESS]\tCafeFree\n' > "$FAKE_RESULTS"
export FAKE_CHOICE=1
out=$(sh "$TOOL" 2>&1)
if grep -q 'set_network 0 key_mgmt NONE' "$FAKE_LOG" \
        && ! grep -q 'psk' "$FAKE_LOG"; then
        ok "open network uses key_mgmt NONE, no psk"
else
        bad "open network flow: $(tr '\n' ';' < "$FAKE_LOG")"
fi

# 5. duplicate cleanup: list_network shows the same ssid -> removed
: > "$FAKE_LOG"
printf '0\tHomeNet\tany\t\n' > "$FAKE_LIST"
printf 'aa:bb:cc:dd:ee:ff\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tHomeNet\n' > "$FAKE_RESULTS"
export FAKE_CHOICE=1
sh "$TOOL" >/dev/null 2>&1
if grep -q 'remove_network 0' "$FAKE_LOG"; then
        ok "existing network with same ssid removed first"
else
        bad "duplicate cleanup missing: $(tr '\n' ';' < "$FAKE_LOG")"
fi

# 6. dedup + signal sort in the menu items (strongest first)
: > "$FAKE_LOG"
: > "$FAKE_LIST"
printf 'aa:bb:cc:dd:ee:01\t2412\t-80\t[WPA2-PSK-CCMP][ESS]\tDup\n' > "$FAKE_RESULTS"
printf 'aa:bb:cc:dd:ee:02\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tDup\n' >> "$FAKE_RESULTS"
printf 'aa:bb:cc:dd:ee:03\t2462\t-50\t[ESS]\tSolo\n' >> "$FAKE_RESULTS"
export FAKE_CHOICE=1
out=$(sh "$TOOL" 2>&1)
case "$out" in
*done:\ connected\ to\ Dup*) ok "dedup folded Dup to one entry (strongest)" ;;
*)                          bad "dedup: got '$out'" ;;
esac
# entry 2 is Solo: Dup folded, sorted by signal
: > "$FAKE_LOG"
export FAKE_CHOICE=2
out=$(sh "$TOOL" 2>&1)
case "$out" in
*done:\ connected\ to\ Solo*) ok "signal sort: Solo is entry 2" ;;
*)                          bad "signal sort: got '$out'" ;;
esac

# 7. hidden network entry (tag h)
: > "$FAKE_LOG"
export FAKE_CHOICE=h
out=$(sh "$TOOL" 2>&1 </dev/null)
# the fake dialog answers the ssid and the password prompts with the
# same canned value: reaching "connected to h" proves the hidden entry
# routed into the ssid+password flow instead of the scan menu
case "$out" in
*done:\ connected\ to\ h*) ok "hidden entry routed to the ssid prompt" ;;
*)              bad "hidden flow: got '$out'" ;;
esac

# 8. rescan prints the network list
out=$(sh "$TOOL" rescan 2>&1)
case "$out" in
*Solo*) ok "rescan prints networks" ;;
*)      bad "rescan: got '$out'" ;;
esac

# 9. no wireless interface -> clear error
rm -rf "$W/sys/class/net/wlan0"
out=$(sh "$TOOL" status 2>&1)
case "$out" in
*no\ wireless\ interface*) ok "missing iface reported clearly" ;;
*)                          bad "missing iface: got '$out'" ;;
esac

if [ "$FAIL" = 0 ]; then
        say "test-wifi: ALL OK"
else
        say "test-wifi: FAILURES"
        exit 1
fi
