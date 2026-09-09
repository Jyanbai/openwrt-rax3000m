#!/bin/sh

# Optional host integration test.  It never generates an external packet:
# --no-resolv plus an empty --servers-file leaves dnsmasq with no upstream.
# Exit 77 means the host lacks dnsmasq or dig.

set -eu

command -v dnsmasq >/dev/null 2>&1 || {
	printf 'SKIP: host dnsmasq is unavailable\n'
	exit 77
}
command -v dig >/dev/null 2>&1 || {
	printf 'SKIP: host dig is unavailable\n'
	exit 77
}

TEST_ROOT="$(mktemp -d)"
PORT=$((20000 + ($$ % 20000)))
EMPTY="$TEST_ROOT/servers"
HOSTS="$TEST_ROOT/hosts"
CONFIG="$TEST_ROOT/dnsmasq.conf"
OUTPUT="$TEST_ROOT/dnsmasq.out"
RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"
PID=

cleanup() {
	if [ -n "$PID" ] && kill -0 "$PID" >/dev/null 2>&1; then
		kill "$PID" >/dev/null 2>&1 || true
		wait "$PID" >/dev/null 2>&1 || true
	fi
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

: > "$EMPTY"
printf '192.0.2.1 router.fixture\n' > "$HOSTS"
{
	printf 'port=%s\n' "$PORT"
	printf 'listen-address=127.0.0.1\n'
	printf 'bind-interfaces\n'
	printf 'user=%s\n' "$RUN_USER"
	printf 'group=%s\n' "$RUN_GROUP"
	printf 'pid-file=%s\n' "$TEST_ROOT/dnsmasq.pid"
	printf 'no-resolv\n'
	printf 'servers-file=%s\n' "$EMPTY"
	printf 'no-hosts\n'
	printf 'addn-hosts=%s\n' "$HOSTS"
	printf 'log-queries\n'
} > "$CONFIG"

dnsmasq --keep-in-foreground --conf-file="$CONFIG" > "$OUTPUT" 2>&1 &
PID=$!

attempt=0
while [ "$attempt" -lt 20 ]; do
	kill -0 "$PID" >/dev/null 2>&1 || {
		cat "$OUTPUT" >&2
		exit 1
	}
	if dig @127.0.0.1 -p "$PORT" router.fixture A +time=1 +tries=1 +short 2>/dev/null |
		grep -Fxq 192.0.2.1; then
		break
	fi
	attempt=$((attempt + 1))
	sleep 0.1
done
[ "$attempt" -lt 20 ] || {
	printf 'FAIL: local hosts lookup did not remain available\n' >&2
	exit 1
}

external="$(dig @127.0.0.1 -p "$PORT" example.com A +time=1 +tries=1 +noall +comments +answer 2>/dev/null || true)"
printf '%s\n' "$external" | grep -Eq 'status: (REFUSED|SERVFAIL)' || {
	printf 'FAIL: external recursion was not fail-closed: %s\n' "$external" >&2
	exit 1
}
if printf '%s\n' "$external" | grep -Eq '[[:space:]]IN[[:space:]]+A[[:space:]]+'; then
	printf 'FAIL: empty servers-file unexpectedly resolved an external name\n' >&2
	exit 1
fi
kill -0 "$PID" >/dev/null 2>&1 || {
	printf 'FAIL: dnsmasq exited while upstream recursion was closed\n' >&2
	exit 1
}

printf 'PASS: empty servers-file keeps local DNS alive and external recursion closed\n'
