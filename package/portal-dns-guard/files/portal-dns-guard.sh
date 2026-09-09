#!/bin/sh

NAME=portal-dns-guard

UBUS_BIN=${PORTAL_DNS_UBUS_BIN:-ubus}
JSONFILTER_BIN=${PORTAL_DNS_JSONFILTER_BIN:-jsonfilter}
DIG_BIN=${PORTAL_DNS_DIG_BIN:-dig}
FETCH_BIN=${PORTAL_DNS_FETCH_BIN:-uclient-fetch}
LOGGER_BIN=${PORTAL_DNS_LOGGER_BIN:-logger}
SYNC_BIN=${PORTAL_DNS_SYNC_BIN:-sync}

ENABLED=1
WAN_INTERFACE=wan
SERVERS_FILE=/tmp/hosts/portal-dns/servers
STATE_FILE=/tmp/portal-dns.state
POLL_INTERVAL=10
GRACE_PERIOD=600
SUCCESS_THRESHOLD=3
FAILURE_THRESHOLD=3
SIGNAL_COOLDOWN=30
PROBE_TIMEOUT=4
DOH_ADDRESS=127.0.0.1
DOH_PORT=5354
DOH_PROBE_NAME=www.baidu.com
CONNECTIVITY_URL=
CONNECTIVITY_HOST=
CONNECTIVITY_EXPECTED=

STATE=WAIT_WAN
VERIFY_FROM=
SUCCESSES=0
FAILURES=0
GRACE_UNTIL=0
LAST_SIGNAL=0
PENDING_SIGNAL=0
STATE_LOADED=0
WAN_UP=0
WAN_DNS=
NOW=0

log_msg() {
	local level="$1"
	shift
	if [ -n "$PORTAL_DNS_TEST" ]; then
		[ -n "$PORTAL_DNS_TEST_EVENT_LOG" ] && printf '%s:%s\n' "$level" "$*" >> "$PORTAL_DNS_TEST_EVENT_LOG"
	else
		"$LOGGER_BIN" -t "$NAME" -p "daemon.$level" -- "$*"
	fi
}

positive_integer() {
	case "$1" in
		''|*[!0-9]*|0) return 1 ;;
		*) return 0 ;;
	esac
}

nonnegative_integer() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

safe_tmp_path() {
	case "$1" in
		/tmp/*/../*|/tmp/*/..|/tmp/../*|/tmp/..) return 1 ;;
		/tmp/*) return 0 ;;
		*) return 1 ;;
	esac
}

fixture_get() {
	local key="$1"
	local fallback="$2"
	local value
	value="$(sed -n "s/^[[:space:]]*option[[:space:]][[:space:]]*$key[[:space:]][[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" "$PORTAL_DNS_TEST_UCI_FIXTURE" | head -n 1)"
	printf '%s\n' "${value:-$fallback}"
}

load_config() {
	if [ -n "$PORTAL_DNS_TEST" ]; then
		if [ -n "$PORTAL_DNS_TEST_UCI_FIXTURE" ]; then
			ENABLED="$(fixture_get enabled "$ENABLED")"
			WAN_INTERFACE="$(fixture_get interface "$WAN_INTERFACE")"
			SERVERS_FILE="${PORTAL_DNS_SERVERS_FILE:-$(fixture_get servers_file "$SERVERS_FILE")}"
			STATE_FILE="${PORTAL_DNS_STATE_FILE:-$(fixture_get state_file "$STATE_FILE")}"
			POLL_INTERVAL="$(fixture_get poll_interval "$POLL_INTERVAL")"
			GRACE_PERIOD="$(fixture_get grace_period "$GRACE_PERIOD")"
			SUCCESS_THRESHOLD="$(fixture_get success_threshold "$SUCCESS_THRESHOLD")"
			FAILURE_THRESHOLD="$(fixture_get failure_threshold "$FAILURE_THRESHOLD")"
			SIGNAL_COOLDOWN="$(fixture_get signal_cooldown "$SIGNAL_COOLDOWN")"
			PROBE_TIMEOUT="$(fixture_get probe_timeout "$PROBE_TIMEOUT")"
			DOH_ADDRESS="$(fixture_get doh_address "$DOH_ADDRESS")"
			DOH_PORT="$(fixture_get doh_port "$DOH_PORT")"
			DOH_PROBE_NAME="$(fixture_get doh_probe_name "$DOH_PROBE_NAME")"
			CONNECTIVITY_URL="$(fixture_get connectivity_url "$CONNECTIVITY_URL")"
			CONNECTIVITY_HOST="$(fixture_get connectivity_host "$CONNECTIVITY_HOST")"
			CONNECTIVITY_EXPECTED="$(fixture_get connectivity_expected "$CONNECTIVITY_EXPECTED")"
		else
			SERVERS_FILE=${PORTAL_DNS_SERVERS_FILE:-$SERVERS_FILE}
			STATE_FILE=${PORTAL_DNS_STATE_FILE:-$STATE_FILE}
		fi
	else
		. /lib/functions.sh
		config_load portal-dns-guard
		config_get_bool ENABLED main enabled "$ENABLED"
		config_get WAN_INTERFACE main interface "$WAN_INTERFACE"
		config_get SERVERS_FILE main servers_file "$SERVERS_FILE"
		config_get STATE_FILE main state_file "$STATE_FILE"
		config_get POLL_INTERVAL main poll_interval "$POLL_INTERVAL"
		config_get GRACE_PERIOD main grace_period "$GRACE_PERIOD"
		config_get SUCCESS_THRESHOLD main success_threshold "$SUCCESS_THRESHOLD"
		config_get FAILURE_THRESHOLD main failure_threshold "$FAILURE_THRESHOLD"
		config_get SIGNAL_COOLDOWN main signal_cooldown "$SIGNAL_COOLDOWN"
		config_get PROBE_TIMEOUT main probe_timeout "$PROBE_TIMEOUT"
		config_get DOH_ADDRESS main doh_address "$DOH_ADDRESS"
		config_get DOH_PORT main doh_port "$DOH_PORT"
		config_get DOH_PROBE_NAME main doh_probe_name "$DOH_PROBE_NAME"
		config_get CONNECTIVITY_URL main connectivity_url "$CONNECTIVITY_URL"
		config_get CONNECTIVITY_HOST main connectivity_host "$CONNECTIVITY_HOST"
		config_get CONNECTIVITY_EXPECTED main connectivity_expected "$CONNECTIVITY_EXPECTED"
	fi

	positive_integer "$POLL_INTERVAL" || POLL_INTERVAL=10
	positive_integer "$GRACE_PERIOD" || GRACE_PERIOD=600
	positive_integer "$SUCCESS_THRESHOLD" || SUCCESS_THRESHOLD=3
	positive_integer "$FAILURE_THRESHOLD" || FAILURE_THRESHOLD=3
	positive_integer "$SIGNAL_COOLDOWN" || SIGNAL_COOLDOWN=30
	positive_integer "$PROBE_TIMEOUT" || PROBE_TIMEOUT=4
	positive_integer "$DOH_PORT" || DOH_PORT=5354

	if [ -z "$PORTAL_DNS_TEST" ]; then
		if ! safe_tmp_path "$SERVERS_FILE"; then
			log_msg err "unsafe servers_file rejected; using /tmp/hosts/portal-dns/servers"
			SERVERS_FILE=/tmp/hosts/portal-dns/servers
		fi
		if ! safe_tmp_path "$STATE_FILE"; then
			log_msg err "unsafe state_file rejected; using /tmp/portal-dns.state"
			STATE_FILE=/tmp/portal-dns.state
		fi
	fi
}

get_now() {
	local uptime_seconds
	if nonnegative_integer "$PORTAL_DNS_TEST_NOW"; then
		printf '%s\n' "$PORTAL_DNS_TEST_NOW"
		return 0
	fi
	# Cooldowns and grace windows are elapsed-time policies.  A wall-clock NTP
	# correction during boot must not extend or collapse either window.
	if [ -r /proc/uptime ]; then
		IFS='. ' read -r uptime_seconds _ < /proc/uptime
		if nonnegative_integer "$uptime_seconds"; then
			printf '%s\n' "$uptime_seconds"
			return 0
		fi
	fi
	date +%s
}

ensure_parent_dir() {
	local path="$1"
	local dir="${path%/*}"
	[ "$dir" = "$path" ] && dir=.
	mkdir -p "$dir"
}

sync_file() {
	[ -n "$PORTAL_DNS_TEST" ] && return 0
	command -v "$SYNC_BIN" >/dev/null 2>&1 || return 0
	"$SYNC_BIN" -f "$1" >/dev/null 2>&1 || "$SYNC_BIN" "$1" >/dev/null 2>&1 || true
}

ensure_servers_file() {
	local tmp
	[ -e "$SERVERS_FILE" ] && return 0
	ensure_parent_dir "$SERVERS_FILE" || return 1
	tmp="${SERVERS_FILE}.tmp.$$"
	umask 077
	: > "$tmp" || return 1
	chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
	sync_file "$tmp"
	mv -f "$tmp" "$SERVERS_FILE" || { rm -f "$tmp"; return 1; }
}

valid_dns_address() {
	printf '%s\n' "$1" | awk '
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
			n = split($0, a, ".");
			if (n != 4) exit 1;
			for (i = 1; i <= 4; i++) if (a[i] < 0 || a[i] > 255) exit 1;
			exit 0;
		}
		/^[0-9A-Fa-f:]+(%[A-Za-z0-9_.-]+)?$/ {
			value = $0;
			sub(/%.*/, "", value);
			count = gsub(/:/, ":", value);
			if (count >= 2) exit 0;
			exit 1;
		}
		{ exit 1 }
	'
}

read_test_wan_fixture() {
	local fixture="$PORTAL_DNS_TEST_WAN_FIXTURE"
	WAN_UP="$(sed -n 's/.*"up"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$fixture" | head -n 1)"
	[ "$WAN_UP" = true ] && WAN_UP=1 || WAN_UP=0
	WAN_DNS="$(sed -n '/"dns-server"[[:space:]]*:/,/]/p' "$fixture" | grep -oE '[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?' | while IFS= read -r value; do valid_dns_address "$value" && printf '%s\n' "$value"; done)"
}

get_wan_status() {
	local status up dns seen value
	WAN_UP=0
	WAN_DNS=

	if [ -n "$PORTAL_DNS_TEST" ]; then
		read_test_wan_fixture
		return 0
	fi

	status="$("$UBUS_BIN" call "network.interface.$WAN_INTERFACE" status 2>/dev/null)" || return 1
	up="$(printf '%s' "$status" | "$JSONFILTER_BIN" -e '@.up')"
	[ "$up" = true ] || return 0
	WAN_UP=1

	dns="$(printf '%s' "$status" | "$JSONFILTER_BIN" -e '@["dns-server"][*]')"
	seen=' '
	for value in $dns; do
		valid_dns_address "$value" || continue
		case "$seen" in
			*" $value "*) continue ;;
		esac
		seen="$seen$value "
		WAN_DNS="${WAN_DNS}${WAN_DNS:+ }$value"
	done
}

valid_state() {
	case "$1" in
		WAIT_WAN|PORTAL_GRACE|VERIFYING|ONLINE_DOH|ONLINE_DEGRADED|PORTAL_RESTRICTED) return 0 ;;
		*) return 1 ;;
	esac
}

load_state() {
	local key value
	[ -f "$STATE_FILE" ] || return 0
	while IFS='=' read -r key value; do
		case "$key" in
			state) valid_state "$value" && STATE="$value" ;;
			verify_from) valid_state "$value" && VERIFY_FROM="$value" ;;
			successes) nonnegative_integer "$value" && SUCCESSES="$value" ;;
			failures) nonnegative_integer "$value" && FAILURES="$value" ;;
			grace_until) nonnegative_integer "$value" && GRACE_UNTIL="$value" ;;
			last_signal) nonnegative_integer "$value" && LAST_SIGNAL="$value" ;;
			pending_signal)
				if [ "$value" = 0 ] || [ "$value" = 1 ]; then
					PENDING_SIGNAL="$value"
				fi
			;;
		esac
	done < "$STATE_FILE"
	STATE_LOADED=1
}

save_state() {
	local tmp="${STATE_FILE}.tmp.$$"
	ensure_parent_dir "$STATE_FILE" || return 1
	umask 077
	{
		printf 'state=%s\n' "$STATE"
		printf 'verify_from=%s\n' "$VERIFY_FROM"
		printf 'successes=%s\n' "$SUCCESSES"
		printf 'failures=%s\n' "$FAILURES"
		printf 'grace_until=%s\n' "$GRACE_UNTIL"
		printf 'last_signal=%s\n' "$LAST_SIGNAL"
		printf 'pending_signal=%s\n' "$PENDING_SIGNAL"
	} > "$tmp" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
}

infer_state() {
	local line
	[ "$STATE_LOADED" -eq 0 ] || return 0
	line="$(sed -n '1p' "$SERVERS_FILE")"
	if [ "$line" = "server=$DOH_ADDRESS#$DOH_PORT" ] && [ "$(wc -l < "$SERVERS_FILE")" -eq 1 ]; then
		STATE=ONLINE_DEGRADED
	elif [ "$WAN_UP" -eq 1 ] && [ -n "$WAN_DNS" ] && [ -s "$SERVERS_FILE" ]; then
		STATE=PORTAL_GRACE
		GRACE_UNTIL=$((NOW + GRACE_PERIOD))
	else
		STATE=WAIT_WAN
	fi
	STATE_LOADED=1
	log_msg notice "reconstructed state=$STATE"
}

set_state() {
	local new_state="$1"
	local reason="$2"
	[ "$STATE" = "$new_state" ] && return 0
	log_msg notice "state $STATE -> $new_state: $reason"
	STATE="$new_state"
}

enter_wait_wan() {
	set_state WAIT_WAN "$1"
	VERIFY_FROM=
	SUCCESSES=0
	FAILURES=0
	GRACE_UNTIL=0
}

enter_portal_grace() {
	set_state PORTAL_GRACE "$1"
	VERIFY_FROM=
	SUCCESSES=0
	FAILURES=0
	GRACE_UNTIL=$((NOW + GRACE_PERIOD))
}

enter_online() {
	set_state ONLINE_DOH "$1"
	VERIFY_FROM=
	SUCCESSES=0
	FAILURES=0
	GRACE_UNTIL=0
}

enter_degraded() {
	set_state ONLINE_DEGRADED "$1"
	VERIFY_FROM=
	SUCCESSES=0
	FAILURES=0
	GRACE_UNTIL=0
}

enter_restricted() {
	set_state PORTAL_RESTRICTED "$1"
	VERIFY_FROM=
	SUCCESSES=0
	FAILURES=0
}

enter_verifying() {
	VERIFY_FROM="$STATE"
	SUCCESSES=1
	FAILURES=0
	set_state VERIFYING "$1"
}

probe_doh() {
	local output
	if [ -n "$PORTAL_DNS_TEST" ]; then
		[ "$PORTAL_DNS_TEST_DOH" = success ]
		return
	fi
	output="$("$DIG_BIN" "@$DOH_ADDRESS" -p "$DOH_PORT" "$DOH_PROBE_NAME" A \
		+time="$PROBE_TIMEOUT" +tries=1 +noall +comments +answer 2>/dev/null)" || return 1
	printf '%s\n' "$output" | grep -q 'status: NOERROR' || return 1
	printf '%s\n' "$output" | grep -Eq '[[:space:]]IN[[:space:]]+A[[:space:]]+' || return 1
}

# Return 0 for ONLINE, 1 for confirmed CAPTIVE, and 2 for UNKNOWN.
probe_connectivity() {
	local body
	if [ -n "$PORTAL_DNS_TEST" ]; then
		case "$PORTAL_DNS_TEST_CONNECTIVITY" in
			online) return 0 ;;
			captive) return 1 ;;
			*) return 2 ;;
		esac
	fi
	[ -n "$CONNECTIVITY_URL" ] && [ -n "$CONNECTIVITY_EXPECTED" ] || return 2
	if [ -n "$CONNECTIVITY_HOST" ]; then
		body="$("$FETCH_BIN" --no-proxy -q -T "$PROBE_TIMEOUT" -O - \
			--header="Host: $CONNECTIVITY_HOST" "$CONNECTIVITY_URL" 2>/dev/null)" || return 2
	else
		body="$("$FETCH_BIN" --no-proxy -q -T "$PROBE_TIMEOUT" -O - "$CONNECTIVITY_URL" 2>/dev/null)" || return 2
	fi
	[ "$body" = "$CONNECTIVITY_EXPECTED" ] && return 0
	return 1
}

desired_mode() {
	case "$STATE" in
		PORTAL_GRACE) printf '%s\n' PORTAL ;;
		VERIFYING)
			case "$VERIFY_FROM" in
				PORTAL_GRACE) printf '%s\n' PORTAL ;;
				PORTAL_RESTRICTED) printf '%s\n' CLOSED ;;
				*) printf '%s\n' DOH ;;
			esac
		;;
		ONLINE_DOH|ONLINE_DEGRADED) printf '%s\n' DOH ;;
		*) printf '%s\n' CLOSED ;;
	esac
}

write_desired_file() {
	local mode="$1"
	local target="$2"
	local dns seen
	case "$mode" in
		DOH)
			printf 'server=%s#%s\n' "$DOH_ADDRESS" "$DOH_PORT" > "$target"
			;;
		PORTAL)
			: > "$target"
			seen=' '
			for dns in $WAN_DNS; do
				valid_dns_address "$dns" || continue
				case "$seen" in
					*" $dns "*) continue ;;
				esac
				seen="$seen$dns "
				printf 'server=%s\n' "$dns" >> "$target"
			done
			;;
		CLOSED)
			: > "$target"
			;;
		*) return 1 ;;
	esac
}

request_dnsmasq_signal() {
	local elapsed
	elapsed=$((NOW - LAST_SIGNAL))
	if [ "$LAST_SIGNAL" -eq 0 ] || [ "$elapsed" -ge "$SIGNAL_COOLDOWN" ]; then
		if [ -n "$PORTAL_DNS_TEST" ]; then
			[ -n "$PORTAL_DNS_TEST_SIGNAL_LOG" ] && printf '%s\n' "$NOW" >> "$PORTAL_DNS_TEST_SIGNAL_LOG"
			LAST_SIGNAL="$NOW"
			PENDING_SIGNAL=0
			return 0
		fi
		if "$UBUS_BIN" call service signal '{"name":"dnsmasq","signal":1}' >/dev/null 2>&1; then
			LAST_SIGNAL="$NOW"
			PENDING_SIGNAL=0
			log_msg notice "sent dnsmasq SIGHUP"
			return 0
		fi
		log_msg err "dnsmasq SIGHUP request failed; retry is pending"
	fi
	PENDING_SIGNAL=1
	return 1
}

apply_servers_file() {
	local mode tmp
	mode="$(desired_mode)"
	tmp="${SERVERS_FILE}.tmp.$$"
	ensure_parent_dir "$SERVERS_FILE" || return 1
	umask 077
	write_desired_file "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
	chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
	if [ -f "$SERVERS_FILE" ] && [ "$(cat "$tmp")" = "$(cat "$SERVERS_FILE")" ]; then
		rm -f "$tmp"
		return 0
	fi
	sync_file "$tmp"
	mv -f "$tmp" "$SERVERS_FILE" || { rm -f "$tmp"; return 1; }
	log_msg notice "installed servers-file mode=$mode state=$STATE"
	request_dnsmasq_signal || true
}

process_pending_signal() {
	local elapsed
	[ "$PENDING_SIGNAL" -eq 1 ] || return 0
	elapsed=$((NOW - LAST_SIGNAL))
	[ "$LAST_SIGNAL" -eq 0 ] || [ "$elapsed" -ge "$SIGNAL_COOLDOWN" ] || return 0
	request_dnsmasq_signal || true
}

step_state_machine() {
	local connectivity_rc
	NOW="$(get_now)"
	get_wan_status || true
	[ -z "$PORTAL_DNS_TEST" ] || log_msg debug "now=$NOW wan_up=$WAN_UP wan_dns=$WAN_DNS state=$STATE"
	infer_state

	case "$STATE" in
		WAIT_WAN)
			if [ "$WAN_UP" -eq 1 ] && [ -n "$WAN_DNS" ]; then
				enter_portal_grace "WAN is up with peer DNS"
			fi
		;;
		PORTAL_GRACE)
			if [ "$WAN_UP" -ne 1 ]; then
				enter_wait_wan "WAN is down"
			elif probe_doh; then
				enter_verifying "first DoH health success"
			elif [ "$NOW" -ge "$GRACE_UNTIL" ]; then
				enter_restricted "plaintext DNS grace expired"
			fi
		;;
		VERIFYING)
			if [ "$WAN_UP" -ne 1 ]; then
				enter_wait_wan "WAN is down"
			elif probe_doh; then
				SUCCESSES=$((SUCCESSES + 1))
				if [ "$SUCCESSES" -ge "$SUCCESS_THRESHOLD" ]; then
					enter_online "$SUCCESS_THRESHOLD consecutive DoH health successes"
				fi
			else
				SUCCESSES=0
				case "$VERIFY_FROM" in
					PORTAL_GRACE)
						set_state PORTAL_GRACE "DoH verification failed"
						VERIFY_FROM=
						[ "$NOW" -lt "$GRACE_UNTIL" ] || enter_restricted "plaintext DNS grace expired"
					;;
					PORTAL_RESTRICTED) enter_restricted "DoH verification failed" ;;
					*) enter_degraded "DoH recovery verification failed" ;;
				esac
			fi
		;;
		ONLINE_DOH)
			if [ "$WAN_UP" -ne 1 ]; then
				enter_wait_wan "WAN is down"
			elif probe_doh; then
				FAILURES=0
			else
				FAILURES=$((FAILURES + 1))
				if [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
					probe_connectivity
					connectivity_rc=$?
					if [ "$connectivity_rc" -eq 1 ]; then
						enter_portal_grace "captive state confirmed after DoH failures"
					else
						enter_degraded "DoH failed without confirmed captive state"
					fi
				fi
			fi
		;;
		ONLINE_DEGRADED)
			if [ "$WAN_UP" -ne 1 ]; then
				enter_wait_wan "WAN is down"
			elif probe_doh; then
				enter_verifying "first DoH recovery success"
			else
				FAILURES=$((FAILURES + 1))
				if [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
					probe_connectivity
					connectivity_rc=$?
					if [ "$connectivity_rc" -eq 1 ]; then
						enter_portal_grace "captive state confirmed while degraded"
					else
						FAILURES=0
					fi
				fi
			fi
		;;
		PORTAL_RESTRICTED)
			if [ "$WAN_UP" -ne 1 ]; then
				enter_wait_wan "WAN is down"
			elif probe_doh; then
				enter_verifying "first DoH success while fail-closed"
			fi
		;;
		*) enter_wait_wan "invalid state" ;;
	esac

	apply_servers_file || log_msg err "failed to update $SERVERS_FILE"
	process_pending_signal
	save_state || log_msg err "failed to save $STATE_FILE"
}

run_daemon() {
	trap ':' USR1
	while true; do
		step_state_machine
		sleep "$POLL_INTERVAL" || true
	done
}

main() {
	load_config
	[ "$ENABLED" = 1 ] || exit 0
	ensure_servers_file || exit 1

	case "$1" in
		--init) exit 0 ;;
		--step)
			load_state
			step_state_machine
			;;
		--run|'')
			load_state
			run_daemon
			;;
		*)
			printf 'usage: %s [--init|--run|--step]\n' "$0" >&2
			exit 2
			;;
	esac
}

main "$@"
