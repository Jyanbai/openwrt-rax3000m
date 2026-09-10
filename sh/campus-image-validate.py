#!/usr/bin/env python3

"""Offline validation for a retained RAX3000M full-image artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


PROFILE = "cmcc_rax3000m-emmc"
REQUIRED_PACKAGES = (
    "portal-dns-guard",
    "dnsproxy",
    "dnsmasq-full",
    "firewall4",
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA256SUM_LINE_RE = re.compile(r"^([0-9A-Fa-f]{64})\s+\*?(.+)$")
REQUIRED_CONFIG_LINES = (
    "CONFIG_TARGET_MULTI_PROFILE=y",
    "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y",
    "CONFIG_PACKAGE_portal-dns-guard=y",
)


class ValidationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def locate_target_dir(artifact_root: Path) -> Path:
    nested = artifact_root / "bin" / "targets" / "mediatek" / "filogic"
    if nested.is_dir():
        return nested
    if (artifact_root / "profiles.json").is_file():
        return artifact_root
    raise ValidationError(
        "Retained artifact does not contain bin/targets/mediatek/filogic"
    )


def load_profiles(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValidationError("profiles.json is missing") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"profiles.json is malformed: {exc}") from exc
    if not isinstance(data, dict):
        raise ValidationError("profiles.json root must be an object")
    return data


def load_sha256sums(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise ValidationError("sha256sums is missing") from exc

    checksums: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        match = SHA256SUM_LINE_RE.fullmatch(line)
        if not match:
            raise ValidationError(f"Malformed sha256sums line {line_number}: {line}")
        digest, name = match.groups()
        if name in checksums:
            raise ValidationError(f"Duplicate sha256sums entry: {name}")
        checksums[name] = digest.lower()
    return checksums


def load_final_config(artifact_root: Path) -> tuple[Path, set[str]]:
    candidates = (
        artifact_root / "final.config",
        artifact_root / "final-config-relevant.txt",
    )
    for path in candidates:
        if path.is_file():
            lines = {
                line.strip()
                for line in path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
            return path, lines
    raise ValidationError("Retained artifact does not contain final.config")


def require_build_boundary(artifact_root: Path) -> None:
    required_files = {
        "full-image-build.status": "PASS",
        "binary-evidence-retention.status": "PASS",
    }
    for name, expected in required_files.items():
        path = artifact_root / name
        try:
            actual = path.read_text(encoding="utf-8").strip()
        except FileNotFoundError as exc:
            raise ValidationError(f"Retained artifact is missing {name}") from exc
        if actual != expected:
            raise ValidationError(f"Retained artifact has {name}={actual!r}, expected PASS")

    build_info = artifact_root / "build-info.txt"
    try:
        build_info_lines = build_info.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise ValidationError("Retained artifact is missing build-info.txt") from exc
    if "make_world_exit=0" not in build_info_lines:
        raise ValidationError("Retained artifact does not prove make_world_exit=0")


def validate_title(profile: dict) -> list[dict]:
    titles = profile.get("titles")
    if not isinstance(titles, list) or not titles:
        raise ValidationError(f"Profile {PROFILE} has no title/model information")
    for title in titles:
        if not isinstance(title, dict):
            continue
        vendor = title.get("vendor")
        model = title.get("model")
        if (
            isinstance(vendor, str)
            and vendor.casefold() == "cmcc"
            and isinstance(model, str)
            and "rax3000m" in model.casefold()
            and "emmc" in model.casefold()
        ):
            return titles
    raise ValidationError(
        f"Profile {PROFILE} title/model does not identify CMCC RAX3000M eMMC"
    )


def validate_images(
    profile: dict, target_dir: Path, checksums: dict[str, str]
) -> list[dict[str, str]]:
    images = profile.get("images")
    if not isinstance(images, list) or not images:
        raise ValidationError(f"Profile {PROFILE} images array is missing or empty")

    sysupgrade_images = [
        image
        for image in images
        if isinstance(image, dict) and image.get("type") == "sysupgrade"
    ]
    if not sysupgrade_images:
        raise ValidationError(f"Profile {PROFILE} has no sysupgrade image")

    evidence: list[dict[str, str]] = []
    for image in sysupgrade_images:
        name = image.get("name")
        expected = image.get("sha256")
        filesystem = image.get("filesystem")
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise ValidationError("profiles.json has an unsafe or empty image filename")
        if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected.lower()):
            raise ValidationError(f"profiles.json has an invalid SHA256 for {name}")
        if not isinstance(filesystem, str) or not filesystem:
            raise ValidationError(f"profiles.json has no filesystem for {name}")

        image_path = target_dir / name
        if not image_path.is_file():
            raise ValidationError(f"Profile sysupgrade file is missing: {name}")
        actual = sha256_file(image_path)
        if actual != expected.lower():
            raise ValidationError(
                f"profiles.json SHA256 mismatch for {name}: expected {expected}, actual {actual}"
            )
        sums_digest = checksums.get(name)
        if sums_digest is None:
            raise ValidationError(f"sha256sums is missing entry for {name}")
        if sums_digest != actual:
            raise ValidationError(
                f"sha256sums mismatch for {name}: expected {sums_digest}, actual {actual}"
            )
        evidence.append(
            {
                "name": name,
                "type": "sysupgrade",
                "filesystem": filesystem,
                "sha256": actual,
            }
        )
    return evidence


def manifest_package_evidence(manifests: list[Path]) -> dict[str, list[str]]:
    evidence: dict[str, list[str]] = {}
    for manifest in manifests:
        for line in manifest.read_text(encoding="utf-8").splitlines():
            fields = line.split()
            if fields:
                evidence.setdefault(fields[0], []).append(manifest.name)
    return evidence


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate(artifact_root: Path, output_dir: Path) -> None:
    artifact_root = artifact_root.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    status_path = output_dir / "static-image-inspection.status"
    status_path.write_text("RUNNING\n", encoding="utf-8")

    try:
        require_build_boundary(artifact_root)
        target_dir = locate_target_dir(artifact_root)
        profiles_path = target_dir / "profiles.json"
        profiles = load_profiles(profiles_path)
        all_profiles = profiles.get("profiles")
        if not isinstance(all_profiles, dict) or PROFILE not in all_profiles:
            raise ValidationError(f"profiles.json is missing profile: {PROFILE}")
        profile = all_profiles[PROFILE]
        if not isinstance(profile, dict):
            raise ValidationError(f"Profile {PROFILE} is not an object")

        titles = validate_title(profile)
        checksums = load_sha256sums(target_dir / "sha256sums")
        image_evidence = validate_images(profile, target_dir, checksums)

        config_path, config_lines = load_final_config(artifact_root)
        missing_config = [line for line in REQUIRED_CONFIG_LINES if line not in config_lines]
        if missing_config:
            raise ValidationError("Final config is missing " + ", ".join(missing_config))
        selected_rax3000m = sorted(
            line
            for line in config_lines
            if line.startswith(
                "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m"
            )
            and line.endswith("=y")
        )
        expected_selection = [
            "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_rax3000m-emmc=y"
        ]
        if selected_rax3000m != expected_selection:
            raise ValidationError(
                "Final config does not select only the CMCC RAX3000M eMMC profile"
            )

        manifests = sorted(target_dir.glob("*.manifest"))
        manifest_names = [path.name for path in manifests]
        (output_dir / "manifest-files.txt").write_text(
            "".join(f"{name}\n" for name in manifest_names), encoding="utf-8"
        )
        if manifests:
            package_evidence = manifest_package_evidence(manifests)
            missing_packages = [
                package for package in REQUIRED_PACKAGES if package not in package_evidence
            ]
            if missing_packages:
                raise ValidationError(
                    "Image manifest package set is missing: "
                    + ", ".join(missing_packages)
                )
            write_json(
                output_dir / "manifest-package-evidence.json",
                {package: package_evidence[package] for package in REQUIRED_PACKAGES},
            )
            manifest_status = "PASS"
        else:
            manifest_status = "NOT_EXECUTED: no *.manifest was retained"
            print(
                "::warning::No image manifest was retained; "
                "Tier 2 package validation is NOT_EXECUTED"
            )

        write_json(
            output_dir / "profile-evidence.json",
            {"profile": PROFILE, "titles": titles, "images": image_evidence},
        )
        write_json(output_dir / "image-evidence.json", image_evidence)
        inclusion_lines = [
            "Tier 1 final config: PASS "
            f"({config_path.name}: CONFIG_PACKAGE_portal-dns-guard=y)",
            f"Tier 2 actual manifest package set: {manifest_status}",
            "Tier 3 final rootfs extraction: NOT_EXECUTED; reserved for canary or a proven extractor",
        ]
        (output_dir / "portal-dns-guard-inclusion.txt").write_text(
            "\n".join(inclusion_lines) + "\n", encoding="utf-8"
        )
        summary = [
            "PASS: retained artifact records make_world_exit=0 and build/retention PASS",
            "PASS: final config selects only the required eMMC multi-profile build input",
            f"PASS: profiles.json contains exact profile {PROFILE}",
            "PASS: profile title/model identifies CMCC RAX3000M eMMC",
        ]
        summary.extend(
            f"PASS: {item['name']} type={item['type']} "
            f"filesystem={item['filesystem']} sha256={item['sha256']}"
            for item in image_evidence
        )
        summary.extend(
            [
                "PASS: profiles.json, actual files, and sha256sums agree",
                f"{manifest_status}: manifest package validation",
                "NOT_EXECUTED: final rootfs extraction and runtime canary inspection",
            ]
        )
        (output_dir / "validation-summary.txt").write_text(
            "\n".join(summary) + "\n", encoding="utf-8"
        )
        status_path.write_text("PASS\n", encoding="utf-8")
        print("\n".join(summary))
    except Exception as exc:
        status_path.write_text(f"FAILED: {exc}\n", encoding="utf-8")
        if isinstance(exc, ValidationError):
            print(f"::error::{exc}", file=sys.stderr)
            raise
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_root", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("full-image-validation-out"))
    args = parser.parse_args()
    try:
        validate(args.artifact_root, args.output_dir)
    except ValidationError:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
