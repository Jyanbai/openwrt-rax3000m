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

fail() {
  echo "::error::$*" >&2
  exit 1
}

run_make() {
  local target="$1"
  echo "Building OpenWrt target: ${target}"
  make -j"$(nproc)" "$target" || make -j1 "$target" V=s
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

make_value() {
  local name="$1"
  make -s "val.${name}" | tail -n1 | tr -d '\r'
}

find_kernel_config() {
  find build_dir -type f \
    -path "*/linux-mediatek_filogic/linux-${EXPECTED_LINUX}/.config" \
    -print -quit
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || \
  fail "campus-apk-build.sh is intentionally restricted to GitHub Actions"

readonly WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly OPENWRT_ROOT="${OPENWRT_ROOT:-/workdir/openwrt}"
readonly OUT_DIR="${WORKSPACE}/out"
readonly STATE_DIR="${OPENWRT_ROOT}/.campus-apk-state"

[[ ! -e "$OPENWRT_ROOT" ]] || fail "Refusing to overwrite existing OPENWRT_ROOT: $OPENWRT_ROOT"
rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OPENWRT_ROOT")" "$OUT_DIR"

git clone --filter=blob:none --no-checkout "$OPENWRT_REPO" "$OPENWRT_ROOT"
git -C "$OPENWRT_ROOT" fetch --force --depth=1 origin \
  "refs/tags/${OPENWRT_TAG}:refs/tags/${OPENWRT_TAG}"

resolved_commit="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_TAG}^{commit}")"
[[ "$resolved_commit" == "$OPENWRT_COMMIT" ]] || \
  fail "${OPENWRT_TAG} resolved to ${resolved_commit}, expected ${OPENWRT_COMMIT}"

git -C "$OPENWRT_ROOT" checkout --detach "$OPENWRT_COMMIT"
[[ "$(git -C "$OPENWRT_ROOT" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]] || \
  fail "OpenWrt checkout is not the required source commit"

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

# sh/op.sh intentionally remains unchanged. It provides a custom xray-core,
# so replace only that package in this ephemeral tree with the exact official
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
run_make target/linux/prepare

baseline_kernel_config="$(find_kernel_config)"
[[ -n "$baseline_kernel_config" ]] || fail "Baseline Linux kernel config was not generated"
cp "$baseline_kernel_config" "$STATE_DIR/baseline-kernel.config"
baseline_glue="$(config_state "$baseline_kernel_config" CONFIG_NETFILTER_NETLINK_GLUE_CT)"

baseline_linux="$(make_value LINUX_VERSION)"
baseline_vermagic="$(make_value LINUX_VERMAGIC)"
baseline_release="$(make_value LINUX_RELEASE)"
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
run_make target/linux/prepare

final_kernel_config="$(find_kernel_config)"
[[ -n "$final_kernel_config" ]] || fail "Final Linux kernel config was not generated"
cp "$final_kernel_config" "$STATE_DIR/final-kernel.config"
final_glue="$(config_state "$final_kernel_config" CONFIG_NETFILTER_NETLINK_GLUE_CT)"
diff -u "$STATE_DIR/baseline-kernel.config" "$STATE_DIR/final-kernel.config" \
  > "$STATE_DIR/kernel-config.diff" || true

final_linux="$(make_value LINUX_VERSION)"
final_vermagic="$(make_value LINUX_VERMAGIC)"
final_release="$(make_value LINUX_RELEASE)"
[[ "$final_linux" == "$baseline_linux" ]] || fail "Final Linux version changed from baseline"
[[ "$final_vermagic" == "$baseline_vermagic" ]] || fail "Final vermagic changed from baseline"
[[ "$final_release" == "$baseline_release" ]] || fail "Final kernel release changed from baseline"

run_make target/linux/compile
run_make package/UA2F/openwrt/compile
run_make package/rkp-ipid/compile
run_make package/feeds/packages/xray-core/compile

apk_tool="$OPENWRT_ROOT/staging_dir/host/bin/apk"
[[ -x "$apk_tool" ]] || fail "OpenWrt host apk tool is missing"

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
  --source-commit "$OPENWRT_COMMIT" \
  --ua2f-commit "$UA2F_COMMIT" \
  --rkp-ipid-commit "$RKP_IPID_COMMIT" \
  --xray-version "$xray_version" \
  --public-key "$OPENWRT_ROOT/public-key.pem" \
  --kernel-config-diff "$STATE_DIR/kernel-config.diff"

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
