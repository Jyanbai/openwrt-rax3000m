#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$ROOT/package/portal-dns-guard/files/portal-dns-guard.sh"
GUARD_CONFIG="$ROOT/package/portal-dns-guard/files/portal-dns-guard.config"
DEFAULTS="$ROOT/package/portal-dns-guard/files/99-portal-dns-guard.defaults"
FIXTURES="$ROOT/tests/fixtures"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	[ ! -f "${STATE_FILE:-}" ] || { printf '%s\n' '--- state ---' >&2; cat "$STATE_FILE" >&2; }
	[ ! -f "${SIGNAL_LOG:-}" ] || { printf '%s\n' '--- signals ---' >&2; cat "$SIGNAL_LOG" >&2; }
	[ ! -f "${EVENT_LOG:-}" ] || { printf '%s\n' '--- events ---' >&2; cat "$EVENT_LOG" >&2; }
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[ "$expected" = "$actual" ] || fail "$message (expected=$expected actual=$actual)"
}

assert_file() {
	local expected="$1"
	local file="$2"
	local message="$3"
	local actual
	actual="$(cat "$file")"
	assert_eq "$expected" "$actual" "$message"
}

state_value() {
	sed -n "s/^$1=//p" "$STATE_FILE"
}

signal_count() {
	if [ -f "$SIGNAL_LOG" ]; then
		wc -l < "$SIGNAL_LOG" | tr -d ' '
	else
		printf '0\n'
	fi
}

new_case() {
	CASE_DIR="$TEST_ROOT/$1"
	mkdir -p "$CASE_DIR"
	SERVERS_FILE="$CASE_DIR/portal-dns.servers"
	STATE_FILE="$CASE_DIR/portal-dns.state"
	SIGNAL_LOG="$CASE_DIR/signals"
	EVENT_LOG="$CASE_DIR/events"
}

guard() {
	local fixture="$1"
	local doh="$2"
	local connectivity="$3"
	local now="$4"
	local action="${5:---step}"
	PORTAL_DNS_TEST=1 \
	PORTAL_DNS_TEST_UCI_FIXTURE="$FIXTURES/portal-dns-guard.uci" \
	PORTAL_DNS_SERVERS_FILE="$SERVERS_FILE" \
	PORTAL_DNS_STATE_FILE="$STATE_FILE" \
	PORTAL_DNS_TEST_WAN_FIXTURE="$FIXTURES/$fixture" \
	PORTAL_DNS_TEST_DOH="$doh" \
	PORTAL_DNS_TEST_CONNECTIVITY="$connectivity" \
	PORTAL_DNS_TEST_NOW="$now" \
	PORTAL_DNS_TEST_SIGNAL_LOG="$SIGNAL_LOG" \
	PORTAL_DNS_TEST_EVENT_LOG="$EVENT_LOG" \
	sh "$GUARD" "$action"
}

bring_online() {
	guard wan-two-dns.json fail unknown 100
	guard wan-two-dns.json success unknown 110
	guard wan-two-dns.json success unknown 120
	guard wan-two-dns.json success unknown 130
	assert_eq ONLINE_DOH "$(state_value state)" 'three DoH successes enter ONLINE_DOH'
	assert_file 'server=127.0.0.1#5354' "$SERVERS_FILE" 'ONLINE_DOH uses dnsproxy only'
}

new_case wan_inputs
# Reproduce a first boot where neither /tmp/hosts nor its child exists yet.
SERVERS_FILE="$CASE_DIR/missing/hosts/portal-dns/servers"
[ ! -e "$CASE_DIR/missing" ] || fail 'startup fixture unexpectedly exists'
guard wan-down.json fail unknown 1 --init
[ -f "$SERVERS_FILE" ] || fail 'init creates servers-file'
[ -d "$CASE_DIR/missing/hosts/portal-dns" ] || fail 'init creates the full servers-file parent path'
[ ! -s "$SERVERS_FILE" ] || fail 'init servers-file is fail-closed'
guard wan-no-dns.json fail unknown 10
assert_eq WAIT_WAN "$(state_value state)" 'WAN without DNS remains WAIT_WAN'
assert_eq 0 "$(signal_count)" 'WAN without DNS sends no SIGHUP'
guard wan-one-dns.json fail unknown 100
assert_eq PORTAL_GRACE "$(state_value state)" 'one WAN DNS enters PORTAL_GRACE'
assert_file 'server=192.0.2.53' "$SERVERS_FILE" 'single WAN DNS is rendered'
assert_eq 1 "$(signal_count)" 'first content change sends one SIGHUP'
guard wan-one-dns.json fail unknown 110
assert_eq 1 "$(signal_count)" 'unchanged state sends no duplicate SIGHUP'
guard wan-two-dns.json fail unknown 140
assert_file 'server=192.0.2.53
server=198.51.100.53' "$SERVERS_FILE" 'two WAN DNS addresses are rendered'
assert_eq 2 "$(signal_count)" 'changed WAN DNS sends one additional SIGHUP'

new_case success_hysteresis
guard wan-down.json fail unknown 1 --init
guard wan-two-dns.json fail unknown 100
guard wan-two-dns.json success unknown 105
assert_eq VERIFYING "$(state_value state)" 'first DoH success enters VERIFYING'
guard wan-two-dns.json success unknown 110
assert_eq VERIFYING "$(state_value state)" 'second DoH success remains VERIFYING'
guard wan-two-dns.json success unknown 115
assert_eq ONLINE_DOH "$(state_value state)" 'third DoH success enters ONLINE_DOH'
assert_eq 1 "$(signal_count)" 'cooldown defers the ONLINE_DOH SIGHUP'
assert_eq 1 "$(state_value pending_signal)" 'deferred SIGHUP is persisted'
guard wan-two-dns.json success unknown 131
assert_eq 2 "$(signal_count)" 'pending SIGHUP fires after cooldown'
assert_eq 0 "$(state_value pending_signal)" 'pending flag clears after SIGHUP'
guard wan-two-dns.json success unknown 170
assert_eq 2 "$(signal_count)" 'unchanged content never sends an extra SIGHUP'
[ ! -e "$SERVERS_FILE.tmp.$$" ] || fail 'atomic temporary file leaked'

new_case cooldown_coalesces
guard wan-down.json fail unknown 1 --init
guard wan-two-dns.json fail unknown 100
guard wan-two-dns.json success unknown 105
guard wan-two-dns.json success unknown 110
guard wan-two-dns.json success unknown 115
assert_eq 1 "$(signal_count)" 'first cooldown change is deferred'
guard wan-down.json fail unknown 120
guard wan-two-dns.json fail unknown 125
assert_eq 1 "$(signal_count)" 'multiple changes within cooldown are coalesced'
assert_eq 1 "$(state_value pending_signal)" 'coalesced change remains pending'
guard wan-two-dns.json fail unknown 131
assert_eq 2 "$(signal_count)" 'coalesced final content is eventually signalled without another change'
assert_file 'server=192.0.2.53
server=198.51.100.53' "$SERVERS_FILE" 'coalescing keeps the final desired contents'
guard wan-two-dns.json fail unknown 170
assert_eq 2 "$(signal_count)" 'stable coalesced content never signals again'

new_case online_failures
guard wan-down.json fail unknown 1 --init
bring_online
guard wan-two-dns.json fail unknown 140
assert_eq ONLINE_DOH "$(state_value state)" 'single DoH failure does not downgrade'
assert_file 'server=127.0.0.1#5354' "$SERVERS_FILE" 'single failure stays fail-closed on DoH'
guard wan-two-dns.json fail online 150
guard wan-two-dns.json fail online 160
assert_eq ONLINE_DEGRADED "$(state_value state)" 'repeated DoH failure with Internet online enters degraded'
assert_file 'server=127.0.0.1#5354' "$SERVERS_FILE" 'ONLINE_DEGRADED never uses plaintext DNS'

guard wan-two-dns.json fail captive 170
guard wan-two-dns.json fail captive 180
guard wan-two-dns.json fail captive 190
assert_eq PORTAL_GRACE "$(state_value state)" 'confirmed captive state enters PORTAL_GRACE'
assert_file 'server=192.0.2.53
server=198.51.100.53' "$SERVERS_FILE" 'confirmed captive state enables runtime WAN DNS'

new_case blank_detector
guard wan-down.json fail unknown 1 --init
bring_online
guard wan-two-dns.json fail unknown 140
guard wan-two-dns.json fail unknown 150
guard wan-two-dns.json fail unknown 160
assert_eq ONLINE_DEGRADED "$(state_value state)" 'blank/unknown detector cannot reopen plaintext DNS'
guard wan-two-dns.json fail unknown 170
guard wan-two-dns.json fail unknown 180
guard wan-two-dns.json fail unknown 190
assert_eq ONLINE_DEGRADED "$(state_value state)" 'blank detector remains fail-closed after repeated failures'
assert_file 'server=127.0.0.1#5354' "$SERVERS_FILE" 'blank detector retains DoH-only policy'

new_case grace_timeout
guard wan-down.json fail unknown 1 --init
guard wan-one-dns.json fail unknown 100
guard wan-one-dns.json fail unknown 161
assert_eq PORTAL_RESTRICTED "$(state_value state)" 'grace timeout enters restricted state'
[ ! -s "$SERVERS_FILE" ] || fail 'restricted state is fail-closed'

new_case restart_rebuild
guard wan-down.json fail unknown 1 --init
bring_online
rm -f "$STATE_FILE"
guard wan-two-dns.json fail unknown 200 --init
assert_file 'server=127.0.0.1#5354' "$SERVERS_FILE" 'service init preserves existing atomic servers-file'
guard wan-two-dns.json fail unknown 201
assert_eq ONLINE_DEGRADED "$(state_value state)" 'missing state reconstructs fail-closed from DoH file'

if grep -Eq '(^|[[:space:]])uci[[:space:]]+(-q[[:space:]]+)?(set|add|add_list|delete|commit|revert|batch)' "$GUARD"; then
	fail 'runtime controller contains a UCI write command'
fi

grep -Fq "option servers_file '/tmp/hosts/portal-dns/servers'" "$GUARD_CONFIG" ||
	fail 'guard config must keep the servers-file under dnsmasq jail-mounted /tmp/hosts'
grep -Fq "set 'dhcp.@dnsmasq[0].ignore_hosts_dir=0'" "$DEFAULTS" ||
	fail 'image defaults must preserve the /tmp/hosts directory jail mount'
grep -Fq "delete 'dhcp.@dnsmasq[0].server'" "$DEFAULTS" ||
	fail 'static dnsmasq servers must not bypass the runtime servers-file'
grep -Fq "delete 'dhcp.@dnsmasq[0].serversfile'" "$DEFAULTS" ||
	fail 'native UCI serversfile must be removed to avoid a stale child bind mount'
grep -Fq 'servers-file=$MANAGED_SERVERS_FILE' "$DEFAULTS" ||
	fail 'dnsmasq extraconftext does not reference the guard path'
if grep -Fq 'set dhcp.@dnsmasq[0].serversfile=' "$DEFAULTS"; then
	fail 'native UCI serversfile would add a child file mount to the dnsmasq jail'
fi
[ "$(grep -Fc "set 'dhcp.@dnsmasq[0].noresolv=1'" "$DEFAULTS")" -eq 1 ] ||
	fail 'dnsmasq defaults were duplicated'

if find "$TEST_ROOT" -type f -name '*.tmp.*' | grep -q .; then
	fail 'an atomic temporary file was left behind'
fi

printf 'PASS: portal-dns-guard state machine tests\n'
