#!/bin/sh

# Executable extraction of the mount-list behavior in the exact source tree
# used by this repository's 25.12.5 build:
# https://github.com/shiyu1314/openwrt-source/blob/0e38877debc3b65b11b4b0589268d29c6b19404f/package/network/services/dnsmasq/files/dnsmasq.init
# Source SHA-256: 610f043921f86083ef8e28f34acc2f853145469c6ae4f2994670916bb4062a7f
# Relevant lines: 196-211, 1057-1074, 1171-1184, 1277-1280.  Keep this small
# model mechanically equivalent to those lines.

append() {
	local var="$1"
	local value="$2"
	eval "current=\${$var:-}"
	if [ -n "$current" ]; then
		eval "$var=\$current\ \$value"
	else
		eval "$var=\$value"
	fi
}

openwrt_25_12_mount_list() {
	local ignore_hosts_dir="$1"
	local serversfile="$2"
	local hostfile=/tmp/hosts/dhcp.cfg01411c
	local hostfile_dir=/tmp/hosts
	local dnsmasqconfdir=/tmp/dnsmasq.cfg01411c.d
	local extra_mount=

	if [ "$ignore_hosts_dir" = 1 ]; then
		append extra_mount "$hostfile"
	else
		append extra_mount "$hostfile_dir"
	fi
	if [ -n "$serversfile" ]; then
		# dnsmasq.init intentionally uses append, not append_extramount.
		append extra_mount "$serversfile"
	fi
	append extra_mount "$dnsmasqconfdir"
	printf '%s\n' "$extra_mount"
}

openwrt_25_12_extraconfig() {
	local extraconftext="$1"
	[ -z "$extraconftext" ] || printf '%s\n' "$extraconftext"
}
