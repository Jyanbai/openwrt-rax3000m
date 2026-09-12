#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT/sh/campus-apk-build.sh"
BUNDLE_SCRIPT="$ROOT/sh/campus-apk-bundle.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for constant in OPENWRT_TAG OPENWRT_COMMIT EXPECTED_OPENWRT_TREE; do
  assignment="$(sed -n "s/^readonly ${constant}=/${constant}=/p" "$BUILD_SCRIPT")"
  [ -n "$assignment" ] || fail "missing ${constant} constant"
  eval "$assignment"
done

[ "$OPENWRT_COMMIT" = "0e38877debc3b65b11b4b0589268d29c6b19404f" ] || \
  fail "unexpected immutable OpenWrt commit"
[ "$EXPECTED_OPENWRT_TREE" = "dec27f1d40a4c5de175cdc70392fc6571c971552" ] || \
  fail "unexpected immutable OpenWrt tree"

provenance_function="$(awk '
  /^openwrt_source_provenance_gate\(\) \{/ { copying=1 }
  copying { print }
  copying && /^}$/ { exit }
' "$BUILD_SCRIPT")"
[ -n "$provenance_function" ] || fail "provenance function was not found"
eval "$provenance_function"

run_case() {
  case_pinned_tree="$1"
  case_tag_commit="$2"
  case_tag_tree="$3"
  set +e
  case_output="$({
    openwrt_source_provenance_gate \
      "$case_pinned_tree" "$case_tag_commit" "$case_tag_tree"
    printf 'commit_match=%s tree_match=%s\n' \
      "$tag_commit_matches" "$tag_tree_matches"
  } 2>&1)"
  case_rc=$?
  set -e
}

run_case "$EXPECTED_OPENWRT_TREE" "$OPENWRT_COMMIT" "$EXPECTED_OPENWRT_TREE"
[ "$case_rc" -eq 0 ] || fail "correct pinned commit/tree was rejected"
[ "$case_output" = "commit_match=yes tree_match=yes" ] || \
  fail "correct pinned commit/tree produced unexpected output: $case_output"

wrong_tree="0000000000000000000000000000000000000000"
run_case "$wrong_tree" "$OPENWRT_COMMIT" "$EXPECTED_OPENWRT_TREE"
[ "$case_rc" -ne 0 ] || fail "wrong pinned tree unexpectedly passed"
case "$case_output" in
  *"has tree ${wrong_tree}, expected ${EXPECTED_OPENWRT_TREE}"*) ;;
  *) fail "wrong pinned tree produced the wrong error: $case_output" ;;
esac

moved_tag_commit="862f847e9f0990cf5ffee4dd06a0b3788cf9ed67"
moved_tag_tree="cd33471afedbba19c0e461f748fe0ed25bcb7ab3"
run_case "$EXPECTED_OPENWRT_TREE" "$moved_tag_commit" "$moved_tag_tree"
[ "$case_rc" -eq 0 ] || fail "moved tag unexpectedly failed provenance gate"
for expected in \
  '::warning::v25.12.5 differs from immutable OpenWrt source pin' \
  "tag_commit=${moved_tag_commit}" \
  "tag_tree=${moved_tag_tree}" \
  "pinned_commit=${OPENWRT_COMMIT}" \
  "pinned_tree=${EXPECTED_OPENWRT_TREE}" \
  'commit_match=no tree_match=no'; do
  case "$case_output" in
    *"$expected"*) ;;
    *) fail "moved-tag warning is missing: $expected" ;;
  esac
done

grep -Fq \
  'pinned_tree="$(git -C "$OPENWRT_ROOT" rev-parse "${OPENWRT_COMMIT}^{tree}")"' \
  "$BUILD_SCRIPT" || fail "pinned commit tree is not resolved explicitly"
grep -Fq \
  'git -C "$OPENWRT_ROOT" checkout --detach "$OPENWRT_COMMIT"' \
  "$BUILD_SCRIPT" || fail "checkout no longer uses immutable OPENWRT_COMMIT"
double_open_bracket="$(printf '[%s' '[')"
double_close_bracket="$(printf ']%s' ']')"
grep -Fq \
  "${double_open_bracket} \"\$(git -C \"\$OPENWRT_ROOT\" rev-parse HEAD)\" == \"\$OPENWRT_COMMIT\" ${double_close_bracket}" \
  "$BUILD_SCRIPT" || fail "checked-out HEAD is no longer verified against OPENWRT_COMMIT"
if grep -Fq 'fail "${OPENWRT_TAG} source tree' "$BUILD_SCRIPT"; then
  fail "build script still treats the moving tag tree as authoritative"
fi
if grep -Fq 'if args.tag_tree_matches != "yes":' "$BUNDLE_SCRIPT"; then
  fail "bundle still rejects a moved provenance-only tag"
fi

printf 'PASS: immutable OpenWrt source provenance gate tests (3 scenarios)\n'
