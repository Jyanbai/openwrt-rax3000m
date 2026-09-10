#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONFIG_PATH="${1:?usage: campus-image-config-check.sh <openwrt-config>}"
readonly EMMC_SYMBOL="CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc"
readonly OLD_SINGLE_PROFILE_SYMBOL="CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_y() {
  local symbol="$1"

  grep -Fqx "${symbol}=y" "$CONFIG_PATH" ||
    fail "Final config does not contain ${symbol}=y"
}

reject_y() {
  local symbol="$1"

  if grep -Fqx "${symbol}=y" "$CONFIG_PATH"; then
    fail "Final config unexpectedly selects ${symbol}=y"
  fi
}

[[ -f "$CONFIG_PATH" ]] || fail "OpenWrt config is missing: $CONFIG_PATH"

require_y CONFIG_TARGET_mediatek
require_y CONFIG_TARGET_mediatek_filogic
require_y CONFIG_TARGET_MULTI_PROFILE
require_y "$EMMC_SYMBOL"
reject_y CONFIG_TARGET_ALL_PROFILES
reject_y "$OLD_SINGLE_PROFILE_SYMBOL"

mapfile -t selected_devices < <(
  grep -E '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_.+=y$' \
    "$CONFIG_PATH" || true
)
if (( ${#selected_devices[@]} != 1 )) ||
  [[ "${selected_devices[0]:-}" != "${EMMC_SYMBOL}=y" ]]; then
  printf 'Selected mediatek/filogic multi-profile devices:\n' >&2
  printf '  %s\n' "${selected_devices[@]:-<none>}" >&2
  fail "Final config must select only the CMCC RAX3000M eMMC profile"
fi

printf 'PASS: %s=y\n' "$EMMC_SYMBOL"
printf 'PASS: only the CMCC RAX3000M eMMC multi-profile device is selected\n'
