#!/bin/sh

# Reproducible Linux proof of the bind-mount inode issue behind the jail fix.
# Run as root, or in an environment where unshare(1) permits a user+mount
# namespace.  Exit 77 means the host cannot provide an isolated mount test.

set -eu

if [ "${PORTAL_DNS_MOUNT_NS:-0}" != 1 ]; then
	command -v unshare >/dev/null 2>&1 || {
		printf 'SKIP: unshare is unavailable\n'
		exit 77
	}
	if [ "$(id -u)" -eq 0 ]; then
		exec unshare --mount --propagation private env PORTAL_DNS_MOUNT_NS=1 sh "$0"
	fi
	exec unshare --user --map-root-user --mount --propagation private \
		env PORTAL_DNS_MOUNT_NS=1 sh "$0"
fi

command -v mount >/dev/null 2>&1 || exit 77
command -v umount >/dev/null 2>&1 || exit 77

TEST_ROOT="$(mktemp -d)"
SOURCE="$TEST_ROOT/source"
FILE_VIEW="$TEST_ROOT/file-view"
DIR_VIEW="$TEST_ROOT/dir-view"
file_mounted=0
dir_mounted=0

cleanup() {
	[ "$file_mounted" -eq 0 ] || umount "$FILE_VIEW/servers" >/dev/null 2>&1 || true
	[ "$dir_mounted" -eq 0 ] || umount "$DIR_VIEW" >/dev/null 2>&1 || true
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$SOURCE" "$FILE_VIEW" "$DIR_VIEW"
printf 'old\n' > "$SOURCE/servers"
: > "$FILE_VIEW/servers"

mount --bind "$SOURCE/servers" "$FILE_VIEW/servers"
file_mounted=1
printf 'new\n' > "$SOURCE/servers.tmp"
mv -f "$SOURCE/servers.tmp" "$SOURCE/servers"
[ "$(cat "$SOURCE/servers")" = new ] || exit 1
[ "$(cat "$FILE_VIEW/servers")" = old ] || {
	printf 'FAIL: child file bind mount unexpectedly followed atomic rename\n' >&2
	exit 1
}
umount "$FILE_VIEW/servers"
file_mounted=0

printf 'old\n' > "$SOURCE/servers"
mount --bind "$SOURCE" "$DIR_VIEW"
dir_mounted=1
printf 'new\n' > "$SOURCE/servers.tmp"
mv -f "$SOURCE/servers.tmp" "$SOURCE/servers"
[ "$(cat "$DIR_VIEW/servers")" = new ] || {
	printf 'FAIL: parent directory bind mount did not expose atomic rename\n' >&2
	exit 1
}

printf 'PASS: parent bind mount follows rename; child file bind mount pins old inode\n'
