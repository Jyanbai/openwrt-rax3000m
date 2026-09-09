# portal-dns-guard

`portal-dns-guard` keeps dnsmasq on a bounded, captive-portal-aware upstream
policy.  It writes only volatile files under `/tmp`; runtime state transitions
never write UCI.

## States and policy

- `WAIT_WAN`: empty servers-file; local DNS records and DHCP remain available,
  but external recursion is fail-closed.
- `PORTAL_GRACE`: use DHCP-learned WAN DNS for at most `grace_period` seconds.
- `VERIFYING`: retain the prior state's upstream policy until consecutive DoH
  successes reach `success_threshold`.
- `ONLINE_DOH`: use only dnsproxy on `127.0.0.1#5354`.
- `ONLINE_DEGRADED`: keep DoH fail-closed when DoH is unhealthy but captivity
  has not been confirmed.
- `PORTAL_RESTRICTED`: the plaintext grace expired; external DNS is closed
  until DoH recovers.

If `connectivity_url`, `connectivity_host`, and `connectivity_expected` are left
blank (the shipped default), the guard deliberately cannot confirm that an
established session has returned to a captive portal.  After an online DoH
failure it therefore stays `ONLINE_DEGRADED` and does **not** reopen plaintext
WAN DNS automatically.  Operators who need automatic session-loss recovery
must configure a campus-approved detector whose response has a stable, exact
success body; a blank or unreliable detector favors leak prevention over
automatic portal recovery.

## dnsmasq jail integration

The managed file is `/tmp/hosts/portal-dns/servers`.  OpenWrt 25.12 already
mounts `/tmp/hosts` into dnsmasq's ujail when `ignore_hosts_dir=0`.  The package
places `servers-file=/tmp/hosts/portal-dns/servers` in dnsmasq's
`extraconftext`, which is emitted into the separately mounted dnsmasq confdir.
It intentionally deletes the native UCI `serversfile` option: that option adds
a second bind mount for the individual file, and an atomic rename outside the
jail would leave that child mount pinned to the old inode.

The guard atomically replaces the file, compares content before signalling, and
coalesces SIGHUP requests within `signal_cooldown`.  A pending SIGHUP is retried
by the normal polling loop even if the desired state no longer changes.  Grace
and cooldown deadlines use `/proc/uptime`, so an NTP wall-clock correction
during boot cannot stretch or collapse them.  The first-install defaults also
disable dnsproxy's normal and optimistic caches: the guard probes dnsproxy
directly, and a cached answer must not masquerade as a healthy DoH path.

## Installation and upgrades

The UCI defaults carry `defaults_version=1` in the preserved
`/etc/config/portal-dns-guard` conffile.  First installation applies the image
policy once.  Subsequent package installs or upgrades see the preserved marker
and do not overwrite later administrator changes.  Removing or resetting that
marker explicitly opts back into the first-install defaults on the next
uci-defaults run.  A sysupgrade that preserves
`/etc/config/portal-dns-guard` also preserves the marker, so the new image's
uci-defaults copy is a no-op; a non-preserving upgrade is treated as a fresh
image and applies the defaults.

A fresh live `apk add` is not an atomic activation path.  OpenWrt's generated
package post-install runs uci-defaults and starts this service, but it does not
regenerate an already-running dnsmasq instance or reload firewall/dnsproxy as
one transaction.  Treat the package as an image-integrated component, or plan
a separately approved maintenance activation after installation; do not use a
live package install as the production canary by itself.
