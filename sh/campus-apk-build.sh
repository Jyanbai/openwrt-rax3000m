#!/usr/bin/env bash

set -Eeuo pipefail

readonly OPENWRT_REPO="https://github.com/shiyu1314/openwrt-source.git"
readonly OPENWRT_TAG="v25.12.5"
readonly OPENWRT_COMMIT="0e38877debc3b65b11b4b0589268d29c6b19404f"
readonly UA2F_REPO="https://github.com/Zxilly/UA2F.git"
readonly UA2F_TAG="v5.2.0"
readonly UA2F_COMMIT="1e7a3fceb42092da9278831d627cff8f25947e29"
readonly RKP_IPID_REPO="https://github.com/EOYOHOO/rkp-ipid.git"
readonly RKP_IPID_COMMIT="073e389703853aeaced6cf1299ca8fbe60635614"
readonly PACKAGES_FEED_COMMIT="5caa62e0bc9f7fb9b0c12a23267bceb7724214dd"
readonly EXPECTED_ARCH="aarch64_cortex-a53"
readonly EXPECTED_LINUX="6.12.94"

KERNEL_CONFIG=""
KERNEL_LINUX_DIR=""
KERNEL_LINUX_VERSION=""
KERNEL_VERMAGIC=""
KERNEL_RELEASE=""
GATE_BLOCKED=0

fail() {
  echo "::error::$*" >&2
  exit 1
}

run_make() {
  local target="$1"
  echo "Building OpenWrt target: ${target}"
  make -j"$(nproc)" "$target" || make -j1 "$target" V=s
}

run_make_verbose_logged() {
  local target="$1"
  local log_file="$2"
  echo "Building OpenWrt target with verbose logging: ${target}"
  {
    make -j"$(nproc)" "$target" V=s || make -j1 "$target" V=s
  } 2>&1 | tee "$log_file"
}

validate_portal_dns_guard_apk() {
  local apk_tool="$1"
  local state_dir="$2"
  local artifact_dir="$3"
  local extract_dir="${state_dir}/portal-dns-guard-apk"
  local metadata="${state_dir}/portal-dns-guard-apk-metadata.json"
  local manifest="${state_dir}/portal-dns-guard-apk-manifest.txt"
  local modes="${state_dir}/portal-dns-guard-apk-modes.txt"
  local scripts="${state_dir}/portal-dns-guard-apk-scripts.txt"
  local conffiles
  local -a candidates expected_files

  mapfile -t candidates < <(find bin -type f -name 'portal-dns-guard-*.apk' -print | sort)
  (( ${#candidates[@]} == 1 )) || {
    printf 'portal-dns-guard APK candidates:\n%s\n' "${candidates[*]:-none}" >&2
    fail "Expected exactly one portal-dns-guard APK"
  }

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  "$apk_tool" adbdump --format json "${candidates[0]}" > "$metadata"
  # Individual package payloads are intentionally unsigned; trust is supplied
  # by the signed packages.adb index.  Extraction is a local content audit, so
  # allow that expected state explicitly instead of depending on host keyrings.
  "$apk_tool" --allow-untrusted extract \
    --destination "$extract_dir" --no-chown "${candidates[0]}"

  python3 - "$metadata" "$scripts" <<'PY'
import json
import re
import sys

def records(value):
    if isinstance(value, list):
        return [record for item in value for record in records(item)]
    if isinstance(value, dict):
        if "name" in value:
            return [value]
        if isinstance(value.get("info"), dict) and "name" in value["info"]:
            return [value["info"]]
        if isinstance(value.get("packages"), list):
            return [record for item in value["packages"] for record in records(item)]
    return []

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
    found = records(payload)
if len(found) != 1:
    raise SystemExit(f"expected one APK metadata record, got {len(found)}")
record = found[0]
if record.get("name") != "portal-dns-guard":
    raise SystemExit(f"wrong package name: {record.get('name')!r}")
if not str(record.get("version", "")).startswith("1.0.0-"):
    raise SystemExit(f"wrong package version: {record.get('version')!r}")
architecture = record.get("arch", record.get("architecture"))
if architecture not in {"noarch", "all"}:
    raise SystemExit(f"wrong package architecture: {architecture!r}")
depends = record.get("depends")
if not isinstance(depends, list):
    raise SystemExit(f"APK dependency metadata is not a list: {depends!r}")
def dependency_name(item):
    if isinstance(item, dict) and item.get("name"):
        return str(item["name"])
    if isinstance(item, str):
        return re.split(r"[<>=~\s]", item.strip(), maxsplit=1)[0]
    raise SystemExit(f"unsupported APK dependency metadata: {item!r}")

dependency_names = {dependency_name(item) for item in depends}
for dependency in ("dnsmasq-full", "dnsproxy", "bind-dig", "jsonfilter", "ubus", "uclient-fetch", "ca-bundle"):
    if dependency not in dependency_names:
        raise SystemExit(f"missing APK dependency metadata: {dependency}")

def script_maps(value):
    if isinstance(value, list):
        return [found for item in value for found in script_maps(item)]
    if isinstance(value, dict):
        result = []
        if isinstance(value.get("scripts"), dict):
            result.append(value["scripts"])
        for key, item in value.items():
            if key != "scripts":
                result.extend(script_maps(item))
        return result
    return []

maps = script_maps(payload)
if len(maps) != 1:
    raise SystemExit(f"expected one APK scripts record, got {len(maps)}")
script_map = maps[0]

def script_value(scripts, name):
    if name not in scripts:
        raise SystemExit(f"missing APK script {name}")
    value = scripts[name]
    if not isinstance(value, str):
        raise SystemExit(
            f"invalid APK script {name}: expected string, "
            f"got {type(value).__name__}"
        )
    if not value:
        raise SystemExit(f"empty APK script {name}")
    return value

def require_script_line(name, content, line):
    if line not in content.splitlines():
        raise SystemExit(f"{name} is missing required line: {line}")

post_install = script_value(script_map, "post-install")
post_upgrade = script_value(script_map, "post-upgrade")
for line in ("#!/bin/sh", 'export pkgname="portal-dns-guard"', "default_postinst"):
    require_script_line("post-install", post_install, line)
for line in ("export PKG_UPGRADE=1", "default_postinst"):
    require_script_line("post-upgrade", post_upgrade, line)
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write("post-install: default_postinst present\n")
    output.write("post-upgrade: default_postinst present\n")
PY

  expected_files=(
    etc/config/portal-dns-guard
    etc/init.d/portal-dns-guard
    etc/hotplug.d/iface/95-portal-dns-guard
    etc/uci-defaults/99-portal-dns-guard
    usr/sbin/portal-dns-guard
  )
  for file in "${expected_files[@]}"; do
    [[ -f "${extract_dir}/${file}" ]] || fail "APK payload is missing /${file}"
  done

  [[ "$(stat -c '%a' "${extract_dir}/etc/config/portal-dns-guard")" == 600 ]] ||
    fail "APK UCI config mode is not 0600"
  for file in \
    etc/init.d/portal-dns-guard \
    etc/hotplug.d/iface/95-portal-dns-guard \
    etc/uci-defaults/99-portal-dns-guard \
    usr/sbin/portal-dns-guard; do
    [[ "$(stat -c '%a' "${extract_dir}/${file}")" == 755 ]] ||
      fail "APK executable mode is not 0755: /${file}"
  done

  sh -n \
    "${extract_dir}/etc/init.d/portal-dns-guard" \
    "${extract_dir}/etc/hotplug.d/iface/95-portal-dns-guard" \
    "${extract_dir}/etc/uci-defaults/99-portal-dns-guard" \
    "${extract_dir}/usr/sbin/portal-dns-guard"
  grep -Fq "delete 'dhcp.@dnsmasq[0].serversfile'" \
    "${extract_dir}/etc/uci-defaults/99-portal-dns-guard" || \
    fail "APK defaults retained the stale child-mount configuration"
  grep -Fq 'servers-file=$MANAGED_SERVERS_FILE' \
    "${extract_dir}/etc/uci-defaults/99-portal-dns-guard" || \
    fail "APK defaults do not emit the managed servers-file through extraconftext"

  conffiles="${extract_dir}/lib/apk/packages/portal-dns-guard.conffiles"
  [[ -f "$conffiles" ]] || fail "APK payload lacks its conffiles declaration"
  grep -Fqx '/etc/config/portal-dns-guard' "$conffiles" || \
    fail "APK does not preserve /etc/config/portal-dns-guard"

  (
    cd "$extract_dir"
    find . -type f -printf '%P\n' | sort
  ) > "$manifest"
  (
    cd "$extract_dir"
    find . -type f -printf '%m %P\n' | sort -k2
  ) > "$modes"
  if grep -Ei '(^|/)(tests?|fixtures?)(/|$)' "$manifest"; then
    fail "APK payload unexpectedly contains tests or fixtures"
  fi
  if grep -Ei '(^|/)readme([./]|$)' "$manifest"; then
    fail "APK payload unexpectedly contains the source-only README"
  fi
  if grep -Ei '(^|/)(id_(rsa|dsa|ecdsa|ed25519)|.*\.key|.*private.*)$' "$manifest"; then
    fail "APK payload unexpectedly contains a private-key-like file"
  fi
  if grep -RIlE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$extract_dir"; then
    fail "APK payload unexpectedly contains private key material"
  fi
  mkdir -p "$artifact_dir"
  cp -a "${candidates[0]}" "$artifact_dir/"
  sha256sum "${candidates[0]}" > "${state_dir}/portal-dns-guard-apk-sha256.txt"
  printf 'Validated portal-dns-guard APK: %s\n' "${candidates[0]}"
}

config_state() {
  local file="$1"
  local symbol="$2"
  local value

  value="$(sed -n "s/^${symbol}=//p" "$file" | tail -n1)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  elif grep -Fqx "# ${symbol} is not set" "$file"; then
    printf 'n\n'
  else
    printf 'unset\n'
  fi
}

target_make_value() {
  local name="$1"
  local output value

  if ! output="$(
    make -s --no-print-directory -C target/linux/mediatek \
      TOPDIR="$OPENWRT_ROOT" TARGET_BUILD=1 "val.${name}" 2>&1
  )"; then
    printf '%s\n' "$output" >&2
    fail "Could not query ${name} from the mediatek target make context"
  fi

  value="$(printf '%s\n' "$output" | tail -n1 | tr -d '\r')"
  [[ -n "$value" && "$value" != "${name} undefined" ]] || \
    fail "${name} is undefined in the mediatek target make context"
  printf '%s\n' "$value"
}

find_kernel_config() {
  local phase="$1"
  local kernel_build_dir target_build_dir build_dir_root
  local top_level_output top_level_linux_dir top_level_linux_dir_real top_level_status=0
  local target_linux_version vermagic_file
  local -a candidates

  mapfile -t candidates < <(
    find build_dir -type f \
      -path "*/linux-mediatek_filogic/linux-${EXPECTED_LINUX}/.config" \
      -print | sort
  )

  if (( ${#candidates[@]} == 0 )); then
    echo "${phase}: no matching Linux kernel config; discovered Linux build directories:" >&2
    find build_dir -maxdepth 5 -type d \
      \( -name 'target-*' -o -name 'linux-*' \) -print >&2 || true
    fail "${phase} Linux kernel config was not generated"
  fi
  if (( ${#candidates[@]} > 1 )); then
    echo "${phase}: multiple Linux kernel config candidates:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    fail "${phase} Linux kernel config selection is ambiguous"
  fi

  KERNEL_CONFIG="$(realpath "${candidates[0]}")"
  KERNEL_LINUX_DIR="$(dirname "$KERNEL_CONFIG")"
  kernel_build_dir="$(dirname "$KERNEL_LINUX_DIR")"
  target_build_dir="$(dirname "$kernel_build_dir")"
  build_dir_root="$(dirname "$target_build_dir")"

  [[ "$(basename "$KERNEL_LINUX_DIR")" == "linux-${EXPECTED_LINUX}" ]] || \
    fail "${phase} Linux directory has an unexpected version: ${KERNEL_LINUX_DIR}"
  [[ "$(basename "$kernel_build_dir")" == "linux-mediatek_filogic" ]] || \
    fail "${phase} kernel tree is not mediatek/filogic: ${KERNEL_LINUX_DIR}"
  [[ "$(basename "$target_build_dir")" == "target-${EXPECTED_ARCH}_musl" ]] || \
    fail "${phase} kernel tree is not for target-${EXPECTED_ARCH}_musl: ${KERNEL_LINUX_DIR}"
  [[ "$(realpath "$build_dir_root")" == "$(realpath build_dir)" ]] || \
    fail "${phase} kernel tree is not directly under the OpenWrt build_dir: ${KERNEL_LINUX_DIR}"

  top_level_output="$(make -s val.LINUX_DIR 2>&1)" || top_level_status=$?
  top_level_linux_dir="$(printf '%s\n' "$top_level_output" | tail -n1 | tr -d '\r')"
  if (( top_level_status != 0 )); then
    printf '%s\n' "$top_level_output" >&2
    echo "::notice::Top-level LINUX_DIR diagnostic failed; using the resolved target build tree"
  elif [[ -z "$top_level_linux_dir" || "$top_level_linux_dir" == "LINUX_DIR undefined" ]]; then
    echo "Top-level LINUX_DIR: undefined (expected/acceptable outside kernel target context)"
  else
    top_level_linux_dir_real="$(realpath -m "$top_level_linux_dir")"
    echo "Top-level LINUX_DIR: ${top_level_linux_dir_real}"
    [[ "$top_level_linux_dir_real" == "$KERNEL_LINUX_DIR" ]] || \
      fail "${phase} top-level LINUX_DIR does not match the resolved target tree"
  fi

  KERNEL_LINUX_VERSION="${KERNEL_LINUX_DIR##*/linux-}"
  [[ "$KERNEL_LINUX_VERSION" == "$EXPECTED_LINUX" ]] || \
    fail "${phase} kernel is ${KERNEL_LINUX_VERSION}, expected ${EXPECTED_LINUX}"
  target_linux_version="$(target_make_value LINUX_VERSION)"
  [[ "$target_linux_version" == "$KERNEL_LINUX_VERSION" ]] || \
    fail "${phase} target make context reports Linux ${target_linux_version}, tree is ${KERNEL_LINUX_VERSION}"

  vermagic_file="${KERNEL_LINUX_DIR}/.vermagic"
  [[ -f "$vermagic_file" ]] || fail "${phase} kernel vermagic file is missing: ${vermagic_file}"
  KERNEL_VERMAGIC="$(tr -d '\r\n' < "$vermagic_file")"
  [[ -n "$KERNEL_VERMAGIC" && "$KERNEL_VERMAGIC" != "unknown" ]] || \
    fail "${phase} kernel vermagic is empty or unknown: ${vermagic_file}"
  [[ "$KERNEL_VERMAGIC" != *[[:space:]]* ]] || \
    fail "${phase} kernel vermagic contains whitespace: ${vermagic_file}"

  KERNEL_RELEASE="$(target_make_value LINUX_RELEASE)"
  [[ "$KERNEL_RELEASE" != "unknown" && "$KERNEL_RELEASE" != *[[:space:]]* ]] || \
    fail "${phase} kernel release is invalid: ${KERNEL_RELEASE}"

  echo "Resolved ${phase} LINUX_DIR: ${KERNEL_LINUX_DIR}"
  echo "${phase} kernel config: ${KERNEL_CONFIG}"
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || \
  fail "campus-apk-build.sh is intentionally restricted to GitHub Actions"

readonly WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly OPENWRT_ROOT="${OPENWRT_ROOT:-/workdir/openwrt}"
readonly OUT_DIR="${WORKSPACE}/out"
readonly STATE_DIR="${OPENWRT_ROOT}/.campus-apk-state"
readonly CI_AUDIT_DIR="${OUT_DIR}/portal-dns-guard-ci"

[[ ! -e "$OPENWRT_ROOT" ]] || fail "Refusing to overwrite existing OPENWRT_ROOT: $OPENWRT_ROOT"
rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OPENWRT_ROOT")" "$CI_AUDIT_DIR"

{
  for script in \
    "$WORKSPACE"/package/portal-dns-guard/files/*.sh \
    "$WORKSPACE"/package/portal-dns-guard/files/*.init \
    "$WORKSPACE"/package/portal-dns-guard/files/*.hotplug \
    "$WORKSPACE"/tests/*.sh \
    "$WORKSPACE"/tests/fixtures/*.sh; do
    sh -n "$script"
  done
  printf 'PASS: shell syntax\n'
} 2>&1 | tee "$CI_AUDIT_DIR/shell-syntax.log"

{
  shellcheck --severity=error --shell=dash \
    "$WORKSPACE"/package/portal-dns-guard/files/*.sh \
    "$WORKSPACE"/package/portal-dns-guard/files/*.init \
    "$WORKSPACE"/package/portal-dns-guard/files/*.hotplug \
    "$WORKSPACE"/tests/*.sh \
    "$WORKSPACE"/tests/fixtures/*.sh
  shellcheck --severity=error --shell=bash \
    "$WORKSPACE/sh/campus-apk-build.sh" \
    "$WORKSPACE/sh/campus-image-build.sh" \
    "$WORKSPACE/sh/op.sh"
  printf 'PASS: ShellCheck severity=error\n'
} 2>&1 | tee "$CI_AUDIT_DIR/shellcheck.log"

{
  sh "$WORKSPACE/tests/portal-dns-guard-test.sh"
  sh "$WORKSPACE/tests/defaults-test.sh"
  sh "$WORKSPACE/tests/dnsmasq-jail-mount-test.sh"
  sh "$WORKSPACE/tests/startup-order-test.sh"
  python3 "$WORKSPACE/tests/apk-validator-test.py"
} 2>&1 | tee "$CI_AUDIT_DIR/fixture-tests.log"

set +e
sh "$WORKSPACE/tests/dnsmasq-failclosed-test.sh" \
  2>&1 | tee "$CI_AUDIT_DIR/dnsmasq-failclosed.log"
dnsmasq_test_rc=${PIPESTATUS[0]}
set -e
case "$dnsmasq_test_rc" in
  0) printf 'PASS\n' > "$CI_AUDIT_DIR/dnsmasq-failclosed.status" ;;
  77)
    printf 'BLOCKED: host dnsmasq or dig unavailable\n' > "$CI_AUDIT_DIR/dnsmasq-failclosed.status"
    GATE_BLOCKED=1
    ;;
  *) fail "real dnsmasq fail-closed integration test failed with rc=${dnsmasq_test_rc}" ;;
esac

set +e
sudo sh "$WORKSPACE/tests/ujail-atomic-rename-test.sh" \
  2>&1 | tee "$CI_AUDIT_DIR/bind-mount-atomic-rename.log"
mount_test_rc=${PIPESTATUS[0]}
set -e
case "$mount_test_rc" in
  0) printf 'PASS\n' > "$CI_AUDIT_DIR/bind-mount-atomic-rename.status" ;;
  77)
    printf 'BLOCKED: runner cannot provide an isolated mount namespace\n' > \
      "$CI_AUDIT_DIR/bind-mount-atomic-rename.status"
    GATE_BLOCKED=1
    ;;
  *) fail "bind-mount atomic-rename test failed with rc=${mount_test_rc}" ;;
esac

git clone --filter=blob:none --no-checkout "$OPENWRT_REPO" "$OPENWRT_ROOT"
git -C "$OPENWRT_ROOT" fetch --force --depth=1 origin "$OPENWRT_COMMIT"
git -C "$OPENWRT_ROOT" fetch --force --depth=1 origin \
  "refs/tags/${OPENWRT_TAG}:refs/tags/${OPENWRT_TAG}"

pinned_tree="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_COMMIT}^{tree}")"
tag_commit="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_TAG}^{commit}")"
tag_tree="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_TAG}^{tree}")"
tag_commit_matches=no
tag_tree_matches=no
if [[ "$tag_commit" == "$OPENWRT_COMMIT" ]]; then
  tag_commit_matches=yes
fi
if [[ "$tag_tree" == "$pinned_tree" ]]; then
  tag_tree_matches=yes
fi

[[ "$tag_tree_matches" == yes ]] || \
  fail "${OPENWRT_TAG} source tree ${tag_tree} differs from pinned tree ${pinned_tree}"
if [[ "$tag_commit_matches" == no ]]; then
  echo "::notice::tag commit differs, but source tree is identical. tag=${tag_commit}, pinned=${OPENWRT_COMMIT}, tree=${pinned_tree}"
fi

git -C "$OPENWRT_ROOT" checkout --detach "$OPENWRT_COMMIT"
[[ "$(git -C "$OPENWRT_ROOT" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]] || \
  fail "OpenWrt checkout is not the required source commit"
grep -Eq '^[[:space:]]*([^#[:space:]]+[[:space:]]+)*dtb:[[:space:]]*FORCE([[:space:]]|$)' \
  "$OPENWRT_ROOT/target/linux/Makefile" || \
  fail "Pinned target/linux/Makefile does not expose dtb as a public target"
OPENWRT_SOURCE_ROOT="$OPENWRT_ROOT" \
  sh "$WORKSPACE/tests/dnsmasq-jail-mount-test.sh" \
  2>&1 | tee "$CI_AUDIT_DIR/openwrt-exact-source.log"

cd "$OPENWRT_ROOT"
./scripts/feeds update -a
OPENWRT_SOURCE_ROOT="$OPENWRT_ROOT" \
OPENWRT_PACKAGES_ROOT="$OPENWRT_ROOT/feeds/packages" \
  sh "$WORKSPACE/tests/startup-order-test.sh" \
  2>&1 | tee "$CI_AUDIT_DIR/openwrt-exact-startup-order.log"

cp -a "$WORKSPACE"/patch/diy/*.patch "$OPENWRT_ROOT"/
cp -a "$WORKSPACE"/patch/luci/*.patch "$OPENWRT_ROOT"/feeds/luci/
cp -a "$WORKSPACE"/patch/keys/. "$OPENWRT_ROOT"/

chmod +x "$WORKSPACE/sh/op.sh" "$OPENWRT_ROOT/kmod-sign"
OP_author="shiyu1314" "$WORKSPACE/sh/op.sh"

cp -a "$WORKSPACE/patch/nginx/luci.locations" \
  "$OPENWRT_ROOT/feeds/packages/net/nginx/files-luci-support/"
cp -a "$WORKSPACE/patch/nginx/uci.conf.template" \
  "$OPENWRT_ROOT/feeds/packages/net/nginx-util/files/"

[[ "$(git -C feeds/packages rev-parse HEAD)" == "$PACKAGES_FEED_COMMIT" ]] || \
  fail "packages feed did not resolve to the source-pinned commit"

git clone --depth=1 --branch "$UA2F_TAG" --single-branch \
  "$UA2F_REPO" package/UA2F
[[ "$(git -C package/UA2F rev-parse HEAD)" == "$UA2F_COMMIT" ]] || \
  fail "UA2F tag ${UA2F_TAG} did not resolve to ${UA2F_COMMIT}"
git -C package/UA2F apply --unidiff-zero \
  "$WORKSPACE/patch/ua2f/0001-openwrt-package-v5.2.0-and-disabled-install.patch"
grep -Fqx 'PKG_VERSION:=5.2.0' package/UA2F/openwrt/Makefile || \
  fail "UA2F OpenWrt package metadata was not corrected to 5.2.0"

git clone --filter=blob:none "$RKP_IPID_REPO" package/rkp-ipid
git -C package/rkp-ipid checkout --detach "$RKP_IPID_COMMIT"
[[ "$(git -C package/rkp-ipid rev-parse HEAD)" == "$RKP_IPID_COMMIT" ]] || \
  fail "rkp-ipid checkout is not the pinned upstream commit"

# sh/op.sh provides the local package overlays and a custom xray-core, so
# replace only xray-core in this ephemeral tree with the exact official
# packages-feed recipe pinned by feeds.conf.default.
rm -rf package/porxy/xray-core package/feeds/packages/xray-core
./scripts/feeds install -f -p packages xray-core
git -C feeds/packages apply --unidiff-zero \
  "$WORKSPACE/patch/xray-core/0001-leave-service-disabled-after-install.patch"

xray_makefile="$(readlink -f package/feeds/packages/xray-core/Makefile)"
official_xray_makefile="$(readlink -f feeds/packages/net/xray-core/Makefile)"
[[ "$xray_makefile" == "$official_xray_makefile" ]] || \
  fail "xray-core is not sourced from the official packages feed"
xray_version="$(sed -n 's/^PKG_VERSION:=//p' "$official_xray_makefile" | head -n1)"
[[ -n "$xray_version" ]] || fail "Could not determine xray-core version"

if [[ -d "$WORKSPACE/files" ]]; then
  cp -a "$WORKSPACE/files" "$OPENWRT_ROOT/files"
fi

mkdir -p "$STATE_DIR"

# Baseline deliberately excludes only the three requested additions.
{
  printf '%s\n' \
    'CONFIG_TARGET_mediatek=y' \
    'CONFIG_TARGET_mediatek_filogic=y' \
    'CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y'
  grep -Ev '^CONFIG_PACKAGE_(ua2f|kmod-rkp-ipid|xray-core)=' \
    "$WORKSPACE/config/config-apk"
} > .config

make defconfig
cp .config "$STATE_DIR/baseline-openwrt.config"

for symbol in ua2f kmod-rkp-ipid xray-core; do
  if grep -Eq "^CONFIG_PACKAGE_${symbol}=[my]$" .config; then
    fail "Baseline unexpectedly selected CONFIG_PACKAGE_${symbol}"
  fi
done

[[ "$(config_state .config CONFIG_TARGET_ARCH_PACKAGES)" == '"aarch64_cortex-a53"' ]] || \
  fail "Baseline package architecture is not ${EXPECTED_ARCH}"

run_make tools/install
run_make toolchain/install
echo "Using target/linux/dtb to materialize baseline kernel config"
run_make target/linux/dtb

find build_dir -type f -name .config | grep 'linux-' || true
find_kernel_config Baseline
baseline_kernel_config="$KERNEL_CONFIG"
cp "$baseline_kernel_config" "$STATE_DIR/baseline-kernel.config"
baseline_glue="$(config_state "$baseline_kernel_config" CONFIG_NETFILTER_NETLINK_GLUE_CT)"

baseline_linux="$KERNEL_LINUX_VERSION"
baseline_vermagic="$KERNEL_VERMAGIC"
baseline_release="$KERNEL_RELEASE"
[[ "$baseline_linux" == "$EXPECTED_LINUX" ]] || \
  fail "Baseline kernel is ${baseline_linux}, expected ${EXPECTED_LINUX}"
[[ -n "$baseline_vermagic" && "$baseline_vermagic" != "unknown" ]] || \
  fail "Baseline kernel vermagic could not be determined"
[[ -n "$baseline_release" ]] || fail "Baseline kernel release could not be determined"
baseline_kernel_package_version="${baseline_linux}~${baseline_vermagic}-r${baseline_release}"

# Restore the complete config, including the three requested module packages.
{
  printf '%s\n' \
    'CONFIG_TARGET_mediatek=y' \
    'CONFIG_TARGET_mediatek_filogic=y' \
    'CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y'
  cat "$WORKSPACE/config/config-apk"
} > .config

make defconfig
cp .config "$STATE_DIR/final-openwrt.config"

for symbol in ua2f kmod-rkp-ipid xray-core; do
  grep -Fqx "CONFIG_PACKAGE_${symbol}=m" .config || \
    fail "CONFIG_PACKAGE_${symbol}=m was silently disabled or changed"
done
grep -Fqx 'CONFIG_PACKAGE_portal-dns-guard=y' .config || \
  fail "CONFIG_PACKAGE_portal-dns-guard=y was silently disabled or changed"

[[ "$(config_state .config CONFIG_TARGET_ARCH_PACKAGES)" == '"aarch64_cortex-a53"' ]] || \
  fail "Final package architecture is not ${EXPECTED_ARCH}"

nft_queue_state="$(config_state .config CONFIG_PACKAGE_kmod-nft-queue)"
nft_tproxy_state="$(config_state .config CONFIG_PACKAGE_kmod-nft-tproxy)"

make -j8 download
mapfile -t undersized_downloads < <(find dl -type f -size -1024c -print)
if (( ${#undersized_downloads[@]} > 0 )); then
  printf 'Removing undersized downloads:\n%s\n' "${undersized_downloads[*]}"
  rm -f -- "${undersized_downloads[@]}"
  make -j8 download
fi

# Recreate the kernel tree from the final config before compiling the module.
make target/linux/clean
echo "Using target/linux/dtb to materialize final kernel config"
run_make target/linux/dtb

find build_dir -type f -name .config | grep 'linux-' || true
find_kernel_config Final
final_kernel_config="$KERNEL_CONFIG"
cp "$final_kernel_config" "$STATE_DIR/final-kernel.config"
final_glue="$(config_state "$final_kernel_config" CONFIG_NETFILTER_NETLINK_GLUE_CT)"
diff -u "$STATE_DIR/baseline-kernel.config" "$STATE_DIR/final-kernel.config" \
  > "$STATE_DIR/kernel-config.diff" || true

final_linux="$KERNEL_LINUX_VERSION"
final_vermagic="$KERNEL_VERMAGIC"
final_release="$KERNEL_RELEASE"
[[ "$final_linux" == "$baseline_linux" ]] || fail "Final Linux version changed from baseline"
[[ "$final_vermagic" == "$baseline_vermagic" ]] || fail "Final vermagic changed from baseline"
[[ "$final_release" == "$baseline_release" ]] || fail "Final kernel release changed from baseline"

run_make target/linux/compile
run_make package/UA2F/openwrt/compile
run_make package/rkp-ipid/compile
run_make package/feeds/packages/xray-core/compile
run_make_verbose_logged package/portal-dns-guard/clean \
  "$CI_AUDIT_DIR/portal-dns-guard-package-clean.log"
run_make_verbose_logged package/portal-dns-guard/compile \
  "$CI_AUDIT_DIR/portal-dns-guard-package-compile.log"

apk_tool="$OPENWRT_ROOT/staging_dir/host/bin/apk"
[[ -x "$apk_tool" ]] || fail "OpenWrt host apk tool is missing"
validate_portal_dns_guard_apk "$apk_tool" "$STATE_DIR" "$OUT_DIR"

python3 "$WORKSPACE/sh/campus-apk-bundle.py" \
  --source-root "$OPENWRT_ROOT" \
  --out-dir "$OUT_DIR" \
  --apk-tool "$apk_tool" \
  --expected-arch "$EXPECTED_ARCH" \
  --expected-linux "$EXPECTED_LINUX" \
  --expected-kernel-version "$baseline_kernel_package_version" \
  --baseline-glue "$baseline_glue" \
  --final-glue "$final_glue" \
  --nft-queue-state "$nft_queue_state" \
  --nft-tproxy-state "$nft_tproxy_state" \
  --pinned-source-commit "$OPENWRT_COMMIT" \
  --resolved-tag-commit "$tag_commit" \
  --pinned-tree "$pinned_tree" \
  --resolved-tag-tree "$tag_tree" \
  --tag-commit-matches "$tag_commit_matches" \
  --tag-tree-matches "$tag_tree_matches" \
  --ua2f-commit "$UA2F_COMMIT" \
  --rkp-ipid-commit "$RKP_IPID_COMMIT" \
  --xray-version "$xray_version" \
  --public-key "$OPENWRT_ROOT/public-key.pem" \
  --kernel-config-diff "$STATE_DIR/kernel-config.diff"

mkdir -p "$OUT_DIR/portal-dns-guard-audit"
cp -a \
  "$STATE_DIR/portal-dns-guard-apk-metadata.json" \
  "$STATE_DIR/portal-dns-guard-apk-manifest.txt" \
  "$STATE_DIR/portal-dns-guard-apk-modes.txt" \
  "$STATE_DIR/portal-dns-guard-apk-scripts.txt" \
  "$STATE_DIR/portal-dns-guard-apk-sha256.txt" \
  "$OUT_DIR/portal-dns-guard-audit/"

grep -E \
  '^(CONFIG_TARGET_mediatek|CONFIG_TARGET_mediatek_filogic|CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc|CONFIG_PACKAGE_(portal-dns-guard|dnsmasq|dnsmasq-full|dnsproxy|bind-dig|jsonfilter|ubus|uclient-fetch|ca-bundle))=' \
  .config | sort > "$CI_AUDIT_DIR/final-config-relevant.txt"

# Reuse the original repository's signing helper and EC key. It signs APK
# repository indexes; the private key is intentionally never copied to out/.
bash "$OPENWRT_ROOT/kmod-sign" "$OUT_DIR"
if compgen -G "$OUT_DIR/deps/*.apk" >/dev/null; then
  bash "$OPENWRT_ROOT/kmod-sign" "$OUT_DIR/deps"
fi

public_key_sha256="$(sha256sum "$OUT_DIR/public-key.pem" | awk '{print $1}')"
cat > "$OUT_DIR/signing-info.txt" <<EOF
public_key_file=public-key.pem
public_key_sha256=${public_key_sha256}
repository_index=packages.adb
dependency_repository_index=$(if [[ -f "$OUT_DIR/deps/packages.adb" ]]; then echo deps/packages.adb; else echo none; fi)
repository_indexes_signed=yes
signing_method=apk mkndx --sign via the original patch/keys/kmod-sign helper
individual_apk_payload_signature=no; trust is established by the signed packages.adb index
private_key_in_artifact=no

Router trust check (run manually only when you choose to install):
  sha256sum /etc/apk/keys/*.pem
The output must include ${public_key_sha256} for the trusted key file before using
the signed local repository. If it does not, stop and decide whether to trust and
install out/public-key.pem; this workflow does not change router trust settings.
EOF

(
  cd "$OUT_DIR"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)

for required in \
  "$OUT_DIR"/portal-dns-guard-*.apk \
  "$OUT_DIR"/ua2f*.apk \
  "$OUT_DIR"/kmod-rkp-ipid*.apk \
  "$OUT_DIR"/xray-core*.apk \
  "$OUT_DIR/SHA256SUMS" \
  "$OUT_DIR/build-info.txt" \
  "$OUT_DIR/compatibility-report.txt" \
  "$OUT_DIR/install-order.txt" \
  "$OUT_DIR/signing-info.txt" \
  "$OUT_DIR/public-key.pem" \
  "$OUT_DIR/packages.adb"; do
  [[ -e "$required" ]] || fail "Required artifact output is missing: $required"
done

echo "Validated artifact directory: $OUT_DIR"
find "$OUT_DIR" -maxdepth 2 -type f -printf '%P\n' | sort

[[ "$GATE_BLOCKED" -eq 0 ]] || fail "one or more Linux/OpenWrt gates are blocked"
