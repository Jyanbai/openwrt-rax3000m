#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT="$ROOT/package/portal-dns-guard/files/portal-dns-guard.init"
MAKEFILE="$ROOT/package/portal-dns-guard/Makefile"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

guard_start="$(sed -n 's/^START=//p' "$INIT")"
[ "$guard_start" = 18 ] || fail 'guard must run at START=18'
[ "$guard_start" -lt 19 ] || fail 'guard no longer precedes OpenWrt 25.12 dnsmasq START=19'
[ "$guard_start" -lt 90 ] || fail 'guard no longer precedes packages-feed dnsproxy START=90'

if [ -n "${OPENWRT_SOURCE_ROOT:-}" ]; then
	BOOT_INIT="$OPENWRT_SOURCE_ROOT/package/base-files/files/etc/init.d/boot"
	DNSMASQ_INIT="$OPENWRT_SOURCE_ROOT/package/network/services/dnsmasq/files/dnsmasq.init"
	[ -f "$BOOT_INIT" ] || fail 'pinned OpenWrt source lacks boot init script'
	[ -f "$DNSMASQ_INIT" ] || fail 'pinned OpenWrt source lacks dnsmasq init script'
	[ "$(sed -n 's/^START=//p' "$BOOT_INIT")" = 10 ] ||
		fail 'pinned OpenWrt boot service is not START=10'
	[ "$(sed -n 's/^START=//p' "$DNSMASQ_INIT")" = 19 ] ||
		fail 'pinned OpenWrt dnsmasq service is not START=19'
fi

if [ -n "${OPENWRT_PACKAGES_ROOT:-}" ]; then
	DNSPROXY_INIT="$OPENWRT_PACKAGES_ROOT/net/dnsproxy/files/dnsproxy.init"
	[ -f "$DNSPROXY_INIT" ] || fail 'pinned packages feed lacks dnsproxy init script'
	[ "$(sed -n 's/^START=//p' "$DNSPROXY_INIT")" = 90 ] ||
		fail 'pinned packages-feed dnsproxy service is not START=90'
fi

init_line="$(grep -n '"\$PROG" --init' "$INIT" | cut -d: -f1)"
open_line="$(grep -n 'procd_open_instance' "$INIT" | cut -d: -f1)"
[ -n "$init_line" ] && [ -n "$open_line" ] && [ "$init_line" -lt "$open_line" ] ||
	fail 'synchronous volatile-file initialization must happen before daemon registration'

grep -Fq '+dnsmasq-full' "$MAKEFILE" || fail 'dnsmasq dependency is missing'
grep -Fq '+dnsproxy' "$MAKEFILE" || fail 'dnsproxy dependency is missing'
grep -Fq '/etc/config/portal-dns-guard' "$MAKEFILE" ||
	fail 'guard UCI configuration is not declared as a conffile'

printf 'PASS: portal-dns-guard boot ordering and conffile tests\n'
