#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
readonly CHECKER="$REPO_ROOT/sh/campus-image-config-check.sh"
readonly EMMC_SYMBOL="CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc"
readonly TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

write_common_config() {
  local path="$1"

  cat > "$path" <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_MULTI_PROFILE=y
# CONFIG_TARGET_ALL_PROFILES is not set
EOF
}

expect_failure() {
  local fixture="$1"
  local message="$2"

  if bash "$CHECKER" "$fixture" > "$TEMP_DIR/check.log" 2>&1; then
    printf 'Expected validation failure for %s\n' "$fixture" >&2
    exit 1
  fi
  grep -Fq "$message" "$TEMP_DIR/check.log" || {
    cat "$TEMP_DIR/check.log" >&2
    printf 'Expected failure message was not emitted: %s\n' "$message" >&2
    exit 1
  }
}

write_common_config "$TEMP_DIR/pass.config"
printf '%s=y\n' "$EMMC_SYMBOL" >> "$TEMP_DIR/pass.config"
bash "$CHECKER" "$TEMP_DIR/pass.config"

write_common_config "$TEMP_DIR/missing-emmc.config"
expect_failure \
  "$TEMP_DIR/missing-emmc.config" \
  "Final config does not contain ${EMMC_SYMBOL}=y"

write_common_config "$TEMP_DIR/old-single-profile.config"
printf '%s\n' \
  'CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y' \
  >> "$TEMP_DIR/old-single-profile.config"
expect_failure \
  "$TEMP_DIR/old-single-profile.config" \
  "Final config does not contain ${EMMC_SYMBOL}=y"

write_common_config "$TEMP_DIR/base-only.config"
printf '%s\n' \
  'CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m=y' \
  >> "$TEMP_DIR/base-only.config"
expect_failure \
  "$TEMP_DIR/base-only.config" \
  "Final config does not contain ${EMMC_SYMBOL}=y"

write_common_config "$TEMP_DIR/emmc-and-nand.config"
printf '%s\n' \
  "${EMMC_SYMBOL}=y" \
  'CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-nand=y' \
  >> "$TEMP_DIR/emmc-and-nand.config"
expect_failure \
  "$TEMP_DIR/emmc-and-nand.config" \
  'Final config must select only the CMCC RAX3000M eMMC profile'

grep -Fq "'${EMMC_SYMBOL}=y'" "$REPO_ROOT/sh/campus-image-build.sh"
if grep -Fq \
  "'CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y'" \
  "$REPO_ROOT/sh/campus-image-build.sh"; then
  printf 'Full-image build still injects the obsolete single-profile symbol\n' >&2
  exit 1
fi
grep -Fq "bash \"\$WORKSPACE/sh/campus-image-config-check.sh\" .config" \
  "$REPO_ROOT/sh/campus-image-build.sh"

printf 'PASS: full-image target configuration regression fixtures\n'
