#!/bin/sh

set -eu

root="${PORTAL_DNS_UCI_MOCK_ROOT:?missing mock root}"
values="$root/values"
commits="$root/commits"
mkdir -p "$values"

[ "${1:-}" != -q ] || shift
verb="${1:-}"
[ "$#" -eq 0 ] || shift

value_path() {
	printf '%s/%s\n' "$values" "$1"
}

case "$verb" in
	get)
		path="$(value_path "$1")"
		[ -f "$path" ] || exit 1
		cat "$path"
		;;
	set)
		expression="$1"
		key="${expression%%=*}"
		value="${expression#*=}"
		printf '%s' "$value" > "$(value_path "$key")"
		;;
	delete)
		path="$(value_path "$1")"
		[ -e "$path" ] || exit 1
		rm -f "$path"
		;;
	add_list)
		expression="$1"
		key="${expression%%=*}"
		value="${expression#*=}"
		path="$(value_path "$key")"
		if [ -s "$path" ]; then
			printf '\n%s' "$value" >> "$path"
		else
			printf '%s' "$value" > "$path"
		fi
		;;
	commit)
		printf '%s\n' "$1" >> "$commits"
		;;
	*)
		printf 'unsupported mock UCI verb: %s\n' "$verb" >&2
		exit 2
		;;
esac
