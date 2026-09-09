#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFAULTS="$ROOT/package/portal-dns-guard/files/99-portal-dns-guard.defaults"
MODEL="$ROOT/tests/fixtures/openwrt-25.12-dnsmasq-mount-model.sh"
MANAGED=/tmp/hosts/portal-dns/servers

. "$MODEL"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

contains_mount() {
	local mounts="$1"
	local expected="$2"
	local mount
	for mount in $mounts; do
		[ "$mount" != "$expected" ] || return 0
	done
	return 1
}

legacy_mounts="$(openwrt_25_12_mount_list 0 "$MANAGED")"
contains_mount "$legacy_mounts" /tmp/hosts ||
	fail 'native UCI serversfile model lost the parent mount'
contains_mount "$legacy_mounts" "$MANAGED" ||
	fail 'native UCI serversfile did not reproduce the child mount'

fixed_mounts="$(openwrt_25_12_mount_list 0 '')"
contains_mount "$fixed_mounts" /tmp/hosts ||
	fail 'fixed design lost the parent /tmp/hosts mount'
if contains_mount "$fixed_mounts" "$MANAGED"; then
	fail 'fixed design still emits the child file mount'
fi

generated="$(openwrt_25_12_extraconfig "servers-file=$MANAGED")"
[ "$generated" = "servers-file=$MANAGED" ] ||
	fail 'extraconftext did not generate the dnsmasq servers-file directive'

# When an exact OpenWrt source checkout is available, tie the executable model
# back to the real file rather than trusting only the vendored extraction.
if [ -n "${OPENWRT_SOURCE_ROOT:-}" ]; then
	DNSMASQ_INIT="$OPENWRT_SOURCE_ROOT/package/network/services/dnsmasq/files/dnsmasq.init"
	[ -f "$DNSMASQ_INIT" ] || fail 'OPENWRT_SOURCE_ROOT lacks dnsmasq.init'
	[ "$(sha256sum "$DNSMASQ_INIT" | awk '{print $1}')" = \
		610f043921f86083ef8e28f34acc2f853145469c6ae4f2994670916bb4062a7f ] ||
		fail 'dnsmasq.init is not the pinned 25.12.5 source'
	grep -Fq 'append EXTRA_MOUNT "$HOSTFILE_DIR"' "$DNSMASQ_INIT" ||
		fail 'pinned source no longer mounts the hosts parent directory'
	grep -Fq 'append EXTRA_MOUNT "$serversfile"' "$DNSMASQ_INIT" ||
		fail 'pinned source no longer reproduces the native child mount'
	grep -Fq 'config_get extraconftext "$cfg" extraconftext' "$DNSMASQ_INIT" ||
		fail 'pinned source no longer emits extraconftext'
	grep -Fq 'procd_add_jail_mount $dnsmasqconffile $dnsmasqconfdir' "$DNSMASQ_INIT" ||
		fail 'pinned source no longer mounts dnsmasq confdir'
fi

grep -Fq "delete 'dhcp.@dnsmasq[0].serversfile'" "$DEFAULTS" ||
	fail 'defaults do not remove the native child-mount option'
grep -Fq 'extraconftext=' "$DEFAULTS" ||
	fail 'defaults do not use the mounted dnsmasq confdir'

printf 'PASS: OpenWrt 25.12 dnsmasq jail mount model tests\n'
