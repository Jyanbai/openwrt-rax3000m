#!/usr/bin/env python3

"""Focused static and metadata checks for the XKeen canary dependencies."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "sh" / "campus-apk-build.sh"
BUNDLE_SCRIPT = ROOT / "sh" / "campus-apk-bundle.py"
REQUESTED_CONFIG = ROOT / "config" / "config-apk"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def expect_static_contract() -> None:
    config_lines = REQUESTED_CONFIG.read_text(encoding="utf-8").splitlines()
    if config_lines.count("CONFIG_PACKAGE_jq=m") != 1:
        fail("requested config must contain exactly one CONFIG_PACKAGE_jq=m")
    for forbidden in (
        "CONFIG_PACKAGE_jq-full=m",
        "CONFIG_PACKAGE_jq-full=y",
        "CONFIG_PACKAGE_ss=m",
        "CONFIG_PACKAGE_ss=y",
    ):
        if forbidden in config_lines:
            fail(f"requested config unexpectedly contains {forbidden}")

    source = BUILD_SCRIPT.read_text(encoding="utf-8")
    required = (
        "readonly PACKAGES_FEED_COMMIT=\"5caa62e0bc9f7fb9b0c12a23267bceb7724214dd\"",
        "./scripts/feeds install -f -p packages jq",
        "official_jq_makefile=\"$(readlink -f feeds/packages/utils/jq/Makefile)\"",
        '[[ "$jq_makefile" == "$official_jq_makefile" ]]',
        "grep -Ev '^CONFIG_PACKAGE_(ua2f|kmod-rkp-ipid|xray-core|jq)='",
        "for symbol in ua2f kmod-rkp-ipid xray-core jq; do",
        "grep -Fqx \"CONFIG_PACKAGE_${symbol}=m\" .config",
        "run_make package/feeds/packages/jq/compile",
        '--packages-feed-commit "$PACKAGES_FEED_COMMIT"',
        '--jq-version "$jq_version"',
        '"$OUT_DIR"/jq-*.apk',
        'adbdump --format json "$OUT_DIR/packages.adb"',
    )
    for snippet in required:
        if snippet not in source:
            fail(f"build script is missing contract: {snippet}")

    for forbidden_compile in (
        "run_make package/feeds/packages/jq-full/compile",
        "run_make package/feeds/packages/ss/compile",
    ):
        if forbidden_compile in source:
            fail(f"build script unexpectedly compiles: {forbidden_compile}")

    index_validator_marker = '  "$EXPECTED_ARCH" "$jq_version" <<\'PY\'\n'
    try:
        validator_start = source.index(index_validator_marker) + len(
            index_validator_marker
        )
        validator_end = source.index("\nPY\n", validator_start)
    except ValueError as exc:
        raise SystemExit("FAIL: could not locate repository-index validator") from exc
    compile(
        source[validator_start:validator_end],
        "campus-apk-build.sh:repository-index-validator",
        "exec",
    )

    if source.count("for symbol in ua2f kmod-rkp-ipid xray-core jq; do") != 2:
        fail("jq must be checked once in baseline and once in final config")


def load_bundle_module():
    spec = importlib.util.spec_from_file_location("campus_apk_bundle", BUNDLE_SCRIPT)
    if spec is None or spec.loader is None:
        fail("could not load campus APK bundle module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apk_record(**overrides):
    record = {
        "name": "jq",
        "version": "1.8.1-r2",
        "arch": "aarch64_cortex-a53",
        "depends": [{"name": "libc", "version": "1.2.5-r0", "match": 1}],
        "_path": "/build/bin/packages/aarch64_cortex-a53/packages/jq-1.8.1-r2.apk",
    }
    record.update(overrides)
    return record


def expect_failure(module, name: str, records, expected_error: str) -> None:
    try:
        module.select_and_validate_jq(records, "aarch64_cortex-a53", "1.8.1")
    except RuntimeError as exc:
        if expected_error not in str(exc):
            fail(f"{name} returned the wrong error: {exc}")
        return
    fail(f"{name} unexpectedly passed")


def expect_wrong_output_path_failure(module) -> None:
    try:
        module.select_and_validate_jq(
            [apk_record(_path="/build/bin/host/packages/jq-1.8.1-r2.apk")],
            "aarch64_cortex-a53",
            "1.8.1",
            Path("/build/bin/packages/aarch64_cortex-a53/packages"),
        )
    except RuntimeError as exc:
        if "jq APK came from" not in str(exc):
            fail(f"wrong output path returned the wrong error: {exc}")
        return
    fail("wrong output path unexpectedly passed")


def expect_metadata_contract() -> None:
    module = load_bundle_module()
    if "jq" not in module.MAIN_PACKAGES:
        fail("jq is not a main bundle package")

    selected = module.select_and_validate_jq(
        [apk_record()], "aarch64_cortex-a53", "1.8.1"
    )
    if selected["name"] != "jq":
        fail("valid jq record was not selected")

    cases = (
        ("missing APK", [], "Expected exactly one built jq APK"),
        (
            "duplicate APK",
            [apk_record(), apk_record(_path="/other/jq-1.8.1-r2.apk")],
            "Expected exactly one built jq APK",
        ),
        ("wrong package name", [apk_record(name="jq-full")], "jq APK package name"),
        ("wrong architecture", [apk_record(arch="x86_64")], "jq architecture is x86_64"),
        ("unparseable dependencies", [apk_record(depends="libc")], "dependency metadata is not a list"),
        ("missing libc", [apk_record(depends=[{"name": "libgcc"}])], "does not include libc"),
        (
            "regex variant dependency",
            [apk_record(depends=[{"name": "libc"}, {"name": "oniguruma"}])],
            "unexpectedly depends on oniguruma",
        ),
    )
    for name, records, expected_error in cases:
        expect_failure(module, name, records, expected_error)
    expect_wrong_output_path_failure(module)


def main() -> None:
    expect_static_contract()
    expect_metadata_contract()
    print("PASS: XKeen canary jq config, provenance, and APK validation tests (9 metadata cases)")


if __name__ == "__main__":
    main()
