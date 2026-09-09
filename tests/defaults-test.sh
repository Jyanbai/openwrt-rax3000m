#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFAULTS="$ROOT/package/portal-dns-guard/files/99-portal-dns-guard.defaults"
UCI_MOCK="$ROOT/tests/fixtures/uci-mock.sh"
TEST_ROOT="$(mktemp -d)"
MOCK_ROOT="$TEST_ROOT/uci"
VALUES="$MOCK_ROOT/values"
UCI_MOCK_RUN="$TEST_ROOT/uci-mock"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$VALUES"
cp "$UCI_MOCK" "$UCI_MOCK_RUN"
chmod 0755 "$UCI_MOCK_RUN"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

value_path() {
	printf '%s/%s\n' "$VALUES" "$1"
}

put_value() {
	printf '%s' "$2" > "$(value_path "$1")"
}

get_value() {
	cat "$(value_path "$1")"
}

run_defaults() {
	PORTAL_DNS_UCI_BIN="$UCI_MOCK_RUN" \
	PORTAL_DNS_UCI_MOCK_ROOT="$MOCK_ROOT" \
	sh "$DEFAULTS"
}

put_value portal-dns-guard.main.defaults_version 0
put_value 'dhcp.@dnsmasq[0].server' 203.0.113.53
put_value 'dhcp.@dnsmasq[0].serversfile' /tmp/hosts/portal-dns/servers
put_value 'dhcp.@dnsmasq[0].extraconftext' 'bogus-priv
servers-file=/tmp/hosts/portal-dns/servers
domain-needed'

run_defaults

[ "$(get_value portal-dns-guard.main.defaults_version)" = 1 ] ||
	fail 'defaults version marker was not persisted'
[ ! -e "$(value_path 'dhcp.@dnsmasq[0].server')" ] ||
	fail 'static dnsmasq server survived first-time defaults'
[ ! -e "$(value_path 'dhcp.@dnsmasq[0].serversfile')" ] ||
	fail 'native UCI serversfile survived first-time defaults'
[ "$(get_value 'dhcp.@dnsmasq[0].noresolv')" = 1 ] ||
	fail 'dnsmasq noresolv was not enabled'
[ "$(get_value 'dhcp.@dnsmasq[0].ignore_hosts_dir')" = 0 ] ||
	fail 'dnsmasq /tmp/hosts directory mount was not selected'
[ "$(get_value dnsproxy.cache.enabled)" = 0 ] ||
	fail 'dnsproxy cache must be disabled so health probes reach the DoH upstream'
[ "$(get_value dnsproxy.cache.cache_optimistic)" = 0 ] ||
	fail 'dnsproxy optimistic cache must not mask a lost DoH path'

extraconf="$(get_value 'dhcp.@dnsmasq[0].extraconftext')"
printf '%s\n' "$extraconf" | grep -Fxq bogus-priv ||
	fail 'pre-existing extraconftext was overwritten'
printf '%s\n' "$extraconf" | grep -Fxq domain-needed ||
	fail 'pre-existing extraconftext ordering content was lost'
[ "$(printf '%s\n' "$extraconf" | grep -Fxc 'servers-file=/tmp/hosts/portal-dns/servers')" -eq 1 ] ||
	fail 'managed servers-file directive was not deduplicated'
[ "$(wc -l < "$MOCK_ROOT/commits" | tr -d ' ')" -eq 5 ] ||
	fail 'unexpected first-run UCI commit count'

# A package upgrade/reinstall must not reapply first-boot defaults over a user
# change once the preserved portal-dns-guard conffile carries version 1.
put_value dnsproxy.servers.upstream https://resolver.example/dns-query
run_defaults
[ "$(get_value dnsproxy.servers.upstream)" = https://resolver.example/dns-query ] ||
	fail 'a repeated defaults run overwrote user configuration'
[ "$(wc -l < "$MOCK_ROOT/commits" | tr -d ' ')" -eq 5 ] ||
	fail 'a repeated defaults run performed commits'

put_value portal-dns-guard.main.defaults_version 2
put_value dnsproxy.servers.upstream https://future.example/dns-query
run_defaults
[ "$(get_value portal-dns-guard.main.defaults_version)" = 2 ] ||
	fail 'an older defaults script downgraded a future version marker'
[ "$(get_value dnsproxy.servers.upstream)" = https://future.example/dns-query ] ||
	fail 'an older defaults script overwrote future-version configuration'

printf 'PASS: portal-dns-guard UCI defaults tests\n'
