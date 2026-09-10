#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = REPO_ROOT / "sh" / "campus-image-validate.py"
PROFILE = "cmcc_rax3000m-emmc"
IMAGE_NAME = "openwrt-mediatek-filogic-cmcc_rax3000m-emmc-squashfs-sysupgrade.bin"
IMAGE_CONTENT = b"fixture RAX3000M eMMC sysupgrade\n"
IMAGE_SHA = hashlib.sha256(IMAGE_CONTENT).hexdigest()


def base_profiles() -> dict:
    return {
        "profiles": {
            PROFILE: {
                "titles": [
                    {"vendor": "CMCC", "model": "RAX3000M (eMMC version)"}
                ],
                "images": [
                    {
                        "name": IMAGE_NAME,
                        "type": "sysupgrade",
                        "filesystem": "squashfs",
                        "sha256": IMAGE_SHA,
                    }
                ],
            }
        }
    }


def write_fixture(root: Path) -> Path:
    target = root / "bin" / "targets" / "mediatek" / "filogic"
    target.mkdir(parents=True)
    (root / "final.config").write_text(
        "CONFIG_TARGET_MULTI_PROFILE=y\n"
        "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y\n"
        "CONFIG_PACKAGE_portal-dns-guard=y\n",
        encoding="utf-8",
    )
    (root / "build-info.txt").write_text("make_world_exit=0\n", encoding="utf-8")
    (root / "full-image-build.status").write_text("PASS\n", encoding="utf-8")
    (root / "binary-evidence-retention.status").write_text(
        "PASS\n", encoding="utf-8"
    )
    (target / IMAGE_NAME).write_bytes(IMAGE_CONTENT)
    (target / "profiles.json").write_text(
        json.dumps(base_profiles()), encoding="utf-8"
    )
    (target / "sha256sums").write_text(
        f"{IMAGE_SHA}  {IMAGE_NAME}\n", encoding="utf-8"
    )
    # The name deliberately does not contain the device profile.
    (target / "openwrt-mediatek-filogic.manifest").write_text(
        "portal-dns-guard - 1\n"
        "dnsproxy - 0.83.0\n"
        "dnsmasq-full - 2.90\n"
        "firewall4 - 2026\n",
        encoding="utf-8",
    )
    return target


def run_validator(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            str(root),
            "--output-dir",
            str(root / "validation"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def expect_failure(name: str, mutate, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix=f"image-validator-{name}-") as temp:
        root = Path(temp)
        target = write_fixture(root)
        mutate(root, target)
        result = run_validator(root)
        output = result.stdout + result.stderr
        if result.returncode == 0 or expected not in output:
            raise AssertionError(
                f"{name}: expected failure containing {expected!r}\n{output}"
            )


def rewrite_profiles(target: Path, data: dict) -> None:
    (target / "profiles.json").write_text(json.dumps(data), encoding="utf-8")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="image-validator-pass-") as temp:
        root = Path(temp)
        write_fixture(root)
        result = run_validator(root)
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        if "openwrt-mediatek-filogic.manifest" not in (
            root / "validation" / "manifest-files.txt"
        ).read_text(encoding="utf-8"):
            raise AssertionError("non-device-specific manifest was not accepted")

    expect_failure(
        "profile-missing",
        lambda _root, target: rewrite_profiles(target, {"profiles": {}}),
        f"profiles.json is missing profile: {PROFILE}",
    )
    expect_failure(
        "sysupgrade-missing",
        lambda _root, target: rewrite_profiles(
            target,
            {
                "profiles": {
                    PROFILE: {
                        "titles": base_profiles()["profiles"][PROFILE]["titles"],
                        "images": [
                            {
                                "name": "factory.bin",
                                "type": "factory",
                                "filesystem": "squashfs",
                                "sha256": "0" * 64,
                            }
                        ],
                    }
                }
            },
        ),
        f"Profile {PROFILE} has no sysupgrade image",
    )
    expect_failure(
        "file-missing",
        lambda _root, target: (target / IMAGE_NAME).unlink(),
        f"Profile sysupgrade file is missing: {IMAGE_NAME}",
    )
    expect_failure(
        "malformed-profiles",
        lambda _root, target: (target / "profiles.json").write_text(
            "{not-json", encoding="utf-8"
        ),
        "profiles.json is malformed",
    )

    def json_sha_mismatch(_root: Path, target: Path) -> None:
        data = copy.deepcopy(base_profiles())
        data["profiles"][PROFILE]["images"][0]["sha256"] = "0" * 64
        rewrite_profiles(target, data)

    expect_failure(
        "json-sha-mismatch",
        json_sha_mismatch,
        f"profiles.json SHA256 mismatch for {IMAGE_NAME}",
    )
    expect_failure(
        "sha-entry-missing",
        lambda _root, target: (target / "sha256sums").write_text(
            "1" * 64 + "  unrelated.bin\n", encoding="utf-8"
        ),
        f"sha256sums is missing entry for {IMAGE_NAME}",
    )
    expect_failure(
        "sha-mismatch",
        lambda _root, target: (target / "sha256sums").write_text(
            "1" * 64 + f"  {IMAGE_NAME}\n", encoding="utf-8"
        ),
        f"sha256sums mismatch for {IMAGE_NAME}",
    )

    print("PASS: full-image validation regression fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
