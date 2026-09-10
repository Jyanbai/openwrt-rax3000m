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
readonly TARGET="mediatek"
readonly SUBTARGET="filogic"
readonly DEVICE="cmcc_rax3000m-emmc"

CURRENT_STATUS_FILE=""

fail() {
  if [[ -n "$CURRENT_STATUS_FILE" ]]; then
    printf 'FAILED: %s\n' "$*" > "$CURRENT_STATUS_FILE"
  fi
  echo "::error::$*" >&2
  exit 1
}

require_config() {
  local symbol="$1"
  local expected="$2"

  grep -Fqx "${symbol}=${expected}" .config ||
    fail "Final config does not contain ${symbol}=${expected}"
}

require_manifest_package() {
  local package="$1"
  shift

  grep -hEq "^${package}([[:space:]]|$)" "$@" ||
    fail "Image manifest is missing required package: ${package}"
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] ||
  fail "campus-image-build.sh is intentionally restricted to GitHub Actions"

readonly WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly OPENWRT_ROOT="${OPENWRT_ROOT:-/workdir/openwrt}"
readonly DL_CACHE="${OPENWRT_DL_CACHE:-/workdir/openwrt-dl}"
readonly OUT_DIR="${WORKSPACE}/full-image-out"
readonly FIRMWARE_DIR="${OUT_DIR}/firmware"

[[ ! -e "$OPENWRT_ROOT" ]] ||
  fail "Refusing to overwrite existing OPENWRT_ROOT: $OPENWRT_ROOT"
[[ "$DL_CACHE" == /workdir/* ]] ||
  fail "Download cache must remain under /workdir: $DL_CACHE"

rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OPENWRT_ROOT")" "$DL_CACHE" "$OUT_DIR"
printf 'NOT_EXECUTED: image preparation has not completed\n' > \
  "$OUT_DIR/full-image-build.status"
printf 'NOT_EXECUTED: full image build has not passed\n' > \
  "$OUT_DIR/static-image-inspection.status"
{
  printf 'openwrt_repo=%s\n' "$OPENWRT_REPO"
  printf 'openwrt_tag=%s\n' "$OPENWRT_TAG"
  printf 'openwrt_commit=%s\n' "$OPENWRT_COMMIT"
  printf 'target=%s\n' "$TARGET"
  printf 'subtarget=%s\n' "$SUBTARGET"
  printf 'device=%s\n' "$DEVICE"
  printf 'make_world_exit=NOT_EXECUTED\n'
} > "$OUT_DIR/build-info.txt"

git clone --filter=blob:none --no-checkout "$OPENWRT_REPO" "$OPENWRT_ROOT"
git -C "$OPENWRT_ROOT" fetch --force --depth=1 origin "$OPENWRT_COMMIT"
git -C "$OPENWRT_ROOT" fetch --force --depth=1 origin \
  "refs/tags/${OPENWRT_TAG}:refs/tags/${OPENWRT_TAG}"

pinned_tree="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_COMMIT}^{tree}")"
tag_commit="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_TAG}^{commit}")"
tag_tree="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_TAG}^{tree}")"
[[ "$tag_tree" == "$pinned_tree" ]] ||
  fail "${OPENWRT_TAG} source tree ${tag_tree} differs from pinned tree ${pinned_tree}"
if [[ "$tag_commit" != "$OPENWRT_COMMIT" ]]; then
  echo "::notice::tag commit differs, but source tree is identical. tag=${tag_commit}, pinned=${OPENWRT_COMMIT}, tree=${pinned_tree}"
fi

git -C "$OPENWRT_ROOT" checkout --detach "$OPENWRT_COMMIT"
[[ "$(git -C "$OPENWRT_ROOT" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]] ||
  fail "OpenWrt checkout is not the required source commit"

rm -rf "$OPENWRT_ROOT/dl"
ln -s "$DL_CACHE" "$OPENWRT_ROOT/dl"

cd "$OPENWRT_ROOT"
./scripts/feeds update -a

cp -a "$WORKSPACE"/patch/diy/*.patch "$OPENWRT_ROOT"/
cp -a "$WORKSPACE"/patch/luci/*.patch "$OPENWRT_ROOT"/feeds/luci/
cp -a "$WORKSPACE"/patch/keys/. "$OPENWRT_ROOT"/

chmod +x "$WORKSPACE/sh/op.sh" "$OPENWRT_ROOT/kmod-sign"
OP_author="shiyu1314" "$WORKSPACE/sh/op.sh"

cp -a "$WORKSPACE/patch/nginx/luci.locations" \
  "$OPENWRT_ROOT/feeds/packages/net/nginx/files-luci-support/"
cp -a "$WORKSPACE/patch/nginx/uci.conf.template" \
  "$OPENWRT_ROOT/feeds/packages/net/nginx-util/files/"

[[ "$(git -C feeds/packages rev-parse HEAD)" == "$PACKAGES_FEED_COMMIT" ]] ||
  fail "packages feed did not resolve to the source-pinned commit"

git clone --depth=1 --branch "$UA2F_TAG" --single-branch \
  "$UA2F_REPO" package/UA2F
[[ "$(git -C package/UA2F rev-parse HEAD)" == "$UA2F_COMMIT" ]] ||
  fail "UA2F tag ${UA2F_TAG} did not resolve to ${UA2F_COMMIT}"
git -C package/UA2F apply --unidiff-zero \
  "$WORKSPACE/patch/ua2f/0001-openwrt-package-v5.2.0-and-disabled-install.patch"
grep -Fqx 'PKG_VERSION:=5.2.0' package/UA2F/openwrt/Makefile ||
  fail "UA2F OpenWrt package metadata was not corrected to 5.2.0"

git clone --filter=blob:none "$RKP_IPID_REPO" package/rkp-ipid
git -C package/rkp-ipid checkout --detach "$RKP_IPID_COMMIT"
[[ "$(git -C package/rkp-ipid rev-parse HEAD)" == "$RKP_IPID_COMMIT" ]] ||
  fail "rkp-ipid checkout is not the pinned upstream commit"

rm -rf package/porxy/xray-core package/feeds/packages/xray-core
./scripts/feeds install -f -p packages xray-core
git -C feeds/packages apply --unidiff-zero \
  "$WORKSPACE/patch/xray-core/0001-leave-service-disabled-after-install.patch"

xray_makefile="$(readlink -f package/feeds/packages/xray-core/Makefile)"
official_xray_makefile="$(readlink -f feeds/packages/net/xray-core/Makefile)"
[[ "$xray_makefile" == "$official_xray_makefile" ]] ||
  fail "xray-core is not sourced from the official packages feed"

if [[ -d "$WORKSPACE/files" ]]; then
  cp -a "$WORKSPACE/files" "$OPENWRT_ROOT/files"
fi

{
  printf '%s\n' \
    'CONFIG_TARGET_mediatek=y' \
    'CONFIG_TARGET_mediatek_filogic=y' \
    'CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y'
  cat "$WORKSPACE/config/config-apk"
} > .config

make defconfig
require_config CONFIG_TARGET_mediatek y
require_config CONFIG_TARGET_mediatek_filogic y
require_config CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc y
require_config CONFIG_PACKAGE_portal-dns-guard y
require_config CONFIG_PACKAGE_dnsproxy y
require_config CONFIG_PACKAGE_dnsmasq-full y
require_config CONFIG_PACKAGE_firewall4 y

grep -E \
  '^(CONFIG_TARGET_mediatek|CONFIG_TARGET_mediatek_filogic|CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc|CONFIG_PACKAGE_(portal-dns-guard|dnsmasq|dnsmasq-full|dnsproxy|firewall4))=' \
  .config | sort > "$OUT_DIR/final-config-relevant.txt"

mapfile -t undersized_downloads < <(find "$DL_CACHE" -type f -size -1024c -print)
if (( ${#undersized_downloads[@]} > 0 )); then
  printf 'Removing undersized cached downloads before make download:\n%s\n' \
    "${undersized_downloads[*]}"
  rm -f -- "${undersized_downloads[@]}"
fi

echo "Downloading sources for ${TARGET}/${SUBTARGET}/${DEVICE}"
set +e
make -j"$(nproc)" download 2>&1 | tee "$OUT_DIR/make-download.log"
download_rc=${PIPESTATUS[0]}
set -e
(( download_rc == 0 )) || fail "make download failed with rc=${download_rc}"

CURRENT_STATUS_FILE="$OUT_DIR/full-image-build.status"
printf 'RUNNING\n' > "$CURRENT_STATUS_FILE"
echo "Building complete OpenWrt image: make -j$(nproc) world"
set +e
make -j"$(nproc)" world 2>&1 | tee "$OUT_DIR/full-image-build.log"
image_build_rc=${PIPESTATUS[0]}
set -e
if (( image_build_rc != 0 )); then
  fail "full target/image build failed with rc=${image_build_rc}"
fi
printf 'PASS\n' > "$CURRENT_STATUS_FILE"
CURRENT_STATUS_FILE="$OUT_DIR/static-image-inspection.status"
printf 'RUNNING\n' > "$CURRENT_STATUS_FILE"

target_dir="bin/targets/${TARGET}/${SUBTARGET}"
[[ -d "$target_dir" ]] || fail "Target output directory is missing: $target_dir"

mapfile -t images < <(
  find "$target_dir" -maxdepth 1 -type f -name '*rax3000m-emmc*' \
    ! -name '*.manifest' ! -name '*.buildinfo' ! -name '*.json' \
    ! -name '*.sha' -print | sort
)
(( ${#images[@]} > 0 )) || fail "No RAX3000M eMMC firmware image was produced"

mapfile -t manifests < <(
  find "$target_dir" -maxdepth 1 -type f -name '*rax3000m-emmc*.manifest' \
    -print | sort
)
(( ${#manifests[@]} > 0 )) || fail "No RAX3000M eMMC image manifest was produced"
[[ -f "$target_dir/sha256sums" ]] || fail "Target sha256sums is missing"

require_manifest_package portal-dns-guard "${manifests[@]}"
require_manifest_package dnsproxy "${manifests[@]}"
require_manifest_package dnsmasq-full "${manifests[@]}"
require_manifest_package firewall4 "${manifests[@]}"
printf '%s\n' \
  'PASS: portal-dns-guard is in the image manifest' \
  'PASS: dnsproxy is in the image manifest' \
  'PASS: dnsmasq-full is in the image manifest' \
  'PASS: firewall4 is in the image manifest' \
  > "$OUT_DIR/image-package-manifest-check.txt"

(
  cd "$target_dir"
  sha256sum -c sha256sums
) 2>&1 | tee "$OUT_DIR/image-sha256-verification.log"

mkdir -p "$FIRMWARE_DIR"
cp -a "${images[@]}" "${manifests[@]}" "$FIRMWARE_DIR/"
cp -a "$target_dir/sha256sums" "$OUT_DIR/target-sha256sums"
if [[ -f "$target_dir/profiles.json" ]]; then
  cp -a "$target_dir/profiles.json" "$FIRMWARE_DIR/"
fi

(
  cd "$FIRMWARE_DIR"
  find . -maxdepth 1 -type f ! -name sha256sums -print0 | sort -z |
    xargs -0 sha256sum > sha256sums
  sha256sum -c sha256sums
) 2>&1 | tee "$OUT_DIR/firmware-sha256-verification.log"

{
  printf 'openwrt_repo=%s\n' "$OPENWRT_REPO"
  printf 'openwrt_tag=%s\n' "$OPENWRT_TAG"
  printf 'openwrt_commit=%s\n' "$OPENWRT_COMMIT"
  printf 'openwrt_tree=%s\n' "$pinned_tree"
  printf 'target=%s\n' "$TARGET"
  printf 'subtarget=%s\n' "$SUBTARGET"
  printf 'device=%s\n' "$DEVICE"
  printf 'make_world_exit=0\n'
  printf 'runtime_inspection=NOT_EXECUTED; reserved for non-production canary\n'
} > "$OUT_DIR/build-info.txt"

printf '%s\n' \
  'PASS: make world exited 0' \
  'PASS: RAX3000M eMMC firmware image exists' \
  'PASS: image manifest and sha256sums exist' \
  'PASS: portal-dns-guard, dnsproxy, dnsmasq-full, and firewall4 are in the image manifest' \
  'NOT_EXECUTED: procd, ujail, generated dnsmasq config, and Portal transitions require a booted canary' \
  > "$OUT_DIR/static-image-inspection.txt"

(
  cd "$OUT_DIR"
  find . -type f ! -name ARTIFACT-SHA256SUMS -print0 | sort -z |
    xargs -0 sha256sum > ARTIFACT-SHA256SUMS
  sha256sum -c ARTIFACT-SHA256SUMS
)

printf 'PASS\n' > "$CURRENT_STATUS_FILE"
CURRENT_STATUS_FILE=""

echo "Validated full-image artifact directory: $OUT_DIR"
find "$OUT_DIR" -maxdepth 2 -type f -printf '%P\n' | sort
