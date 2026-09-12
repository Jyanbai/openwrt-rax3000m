#!/usr/bin/env python3
"""Validate and assemble the RAX3000M campus APK offline bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from collections import defaultdict, deque
from pathlib import Path
from typing import Any, NoReturn


MAIN_PACKAGES = ("ua2f", "kmod-rkp-ipid", "xray-core", "jq")
BASE_PACKAGES = {
    "base-files",
    "busybox",
    "kernel",
    "libc",
    "libdl",
    "libgcc",
    "libm",
    "libpthread",
    "librt",
}


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def run(command: list[str], *, text: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )


def extract_records(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        records: list[dict[str, Any]] = []
        for item in payload:
            records.extend(extract_records(item))
        return records
    if isinstance(payload, dict):
        if "name" in payload:
            return [payload]
        # apk-tools 3.x package files use the package schema, whose package
        # metadata is nested under `info`. Repository indexes instead contain
        # a flat `packages` array of the same pkginfo records.
        info = payload.get("info")
        if isinstance(info, dict) and "name" in info:
            return [info]
        packages = payload.get("packages")
        if isinstance(packages, list):
            records = []
            for item in packages:
                records.extend(extract_records(item))
            return records
    return []


def dump_apk(apk_tool: Path, apk_path: Path) -> dict[str, Any]:
    completed = run([str(apk_tool), "adbdump", "--format", "json", str(apk_path)])
    try:
        records = extract_records(json.loads(completed.stdout))
    except json.JSONDecodeError as exc:
        fail(f"Could not parse metadata for {apk_path}: {exc}")
    if len(records) != 1:
        fail(f"Expected one metadata record in {apk_path}, found {len(records)}")
    record = records[0]
    record["_path"] = str(apk_path)
    return record


def list_values(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return re.findall(r"\S+(?:\s+\([^)]*\))?", value)
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(list_values(item))
        return result
    if isinstance(value, dict):
        if "name" in value:
            name = str(value["name"])
            version = str(value.get("version", ""))
            match_value = value.get("match")
            if not version:
                try:
                    match = int(match_value) if match_value not in (None, "") else 0
                except (TypeError, ValueError):
                    fail(f"Unsupported APK dependency match value: {match_value!r}")
                return [f"{'!' if match & 16 else ''}{name}"]

            # apk-tools omits `match` for equality and otherwise serializes
            # APK_VERSION_* as a numeric bit mask (1 = equal, 16 = conflict).
            try:
                match = int(match_value) if match_value not in (None, "") else 1
            except (TypeError, ValueError):
                fail(f"Unsupported APK dependency match value: {match_value!r}")
            conflict = bool(match & 16)
            operator = {
                1: "=",
                2: "<",
                3: "<=",
                4: ">",
                5: ">=",
                6: "><",
                7: "",
                8: "~",
                9: "~",
                11: "<~",
                13: ">~",
            }.get(match & ~16)
            if operator is None:
                fail(f"Unsupported APK dependency match mask: {match}")
            return [f"{'!' if conflict else ''}{name}{operator}{version}"]
        result = []
        for item in value.values():
            result.extend(list_values(item))
        return result
    return [str(value)]


DEP_RE = re.compile(r"^([^<>=~\s]+)\s*([<>=~]+)?\s*(.*)$")


def parse_dependency(raw: str) -> tuple[str, str, str]:
    cleaned = raw.strip()
    cleaned = re.sub(r"\s*\(([^()]*)\)\s*$", r"\1", cleaned)
    match = DEP_RE.match(cleaned)
    if not match:
        return cleaned, "", ""
    return match.group(1), match.group(2) or "", match.group(3).strip()


def canonical_dependency(raw: str) -> str:
    name, operator, version = parse_dependency(raw)
    return f"{name}{operator}{version}".replace(" ", "")


def record_path(record: dict[str, Any]) -> Path:
    return Path(str(record["_path"]))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def select_unique(records: list[dict[str, Any]], description: str) -> dict[str, Any]:
    if not records:
        fail(f"No built APK found for {description}")
    if len(records) == 1:
        return records[0]

    hashes = {sha256_file(record_path(record)) for record in records}
    if len(hashes) == 1:
        return sorted(records, key=lambda item: str(item["_path"]))[0]
    paths = ", ".join(str(record["_path"]) for record in records)
    fail(f"Ambiguous APKs for {description}: {paths}")


def select_and_validate_jq(
    records: list[dict[str, Any]],
    expected_arch: str,
    expected_version: str,
    expected_output_dir: Path | None = None,
) -> dict[str, Any]:
    if len(records) != 1:
        paths = ", ".join(str(record.get("_path", "<unknown>")) for record in records)
        fail(f"Expected exactly one built jq APK, found {len(records)}: {paths or 'none'}")

    record = records[0]
    if record.get("name") != "jq":
        fail(f"jq APK package name is {record.get('name')!r}, expected 'jq'")

    architecture = str(record.get("arch", record.get("architecture", "")))
    if architecture != expected_arch:
        fail(f"jq architecture is {architecture}, expected {expected_arch}")

    if expected_output_dir is not None:
        apk_path = record_path(record).resolve()
        if apk_path.parent != expected_output_dir.resolve():
            fail(
                f"jq APK came from {apk_path.parent}, "
                f"expected {expected_output_dir.resolve()}"
            )

    apk_version = str(record.get("version", ""))
    if not apk_version.startswith(f"{expected_version}-"):
        fail(
            f"jq APK version is {apk_version}, "
            f"expected {expected_version} release metadata"
        )

    raw_dependencies = record.get("depends")
    if not isinstance(raw_dependencies, list):
        fail(f"jq APK dependency metadata is not a list: {raw_dependencies!r}")
    for dependency in raw_dependencies:
        if isinstance(dependency, str):
            continue
        if not isinstance(dependency, dict) or not dependency.get("name"):
            fail(f"jq APK contains invalid dependency metadata: {dependency!r}")

    dependencies = list_values(raw_dependencies)
    dependency_names = [
        parse_dependency(dependency)[0] for dependency in dependencies
    ]
    if not dependencies or any(
        not name or name.startswith("!") for name in dependency_names
    ):
        fail(f"jq APK dependency metadata is empty or invalid: {raw_dependencies!r}")
    if "libc" not in dependency_names:
        fail(f"jq APK runtime dependency metadata does not include libc: {dependencies}")
    if "oniguruma" in dependency_names:
        fail(f"standard jq unexpectedly depends on oniguruma: {dependencies}")

    return record


def version_matches(record: dict[str, Any], operator: str, required: str) -> bool:
    if not required or operator not in {"=", "=="}:
        return True
    return str(record.get("version", "")) == required


def public_record(record: dict[str, Any], source_root: Path) -> dict[str, Any]:
    result = {key: value for key, value in record.items() if key != "_path"}
    result["build_path"] = str(record_path(record).relative_to(source_root))
    result["sha256"] = sha256_file(record_path(record))
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--apk-tool", type=Path, required=True)
    parser.add_argument("--expected-arch", required=True)
    parser.add_argument("--expected-linux", required=True)
    parser.add_argument("--expected-kernel-version", required=True)
    parser.add_argument("--baseline-glue", required=True)
    parser.add_argument("--final-glue", required=True)
    parser.add_argument("--nft-queue-state", required=True)
    parser.add_argument("--nft-tproxy-state", required=True)
    parser.add_argument("--pinned-source-commit", required=True)
    parser.add_argument("--resolved-tag-commit", required=True)
    parser.add_argument("--pinned-tree", required=True)
    parser.add_argument("--resolved-tag-tree", required=True)
    parser.add_argument("--tag-commit-matches", choices=("yes", "no"), required=True)
    parser.add_argument("--tag-tree-matches", choices=("yes", "no"), required=True)
    parser.add_argument("--ua2f-commit", required=True)
    parser.add_argument("--rkp-ipid-commit", required=True)
    parser.add_argument("--packages-feed-commit", required=True)
    parser.add_argument("--xray-version", required=True)
    parser.add_argument("--jq-version", required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--kernel-config-diff", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_root = args.source_root.resolve()
    out_dir = args.out_dir.resolve()
    apk_tool = args.apk_tool.resolve()

    if not apk_tool.is_file():
        fail(f"APK metadata tool is missing: {apk_tool}")
    if not args.public_key.is_file():
        fail(f"Public signing key is missing: {args.public_key}")
    if args.tag_tree_matches != "yes":
        fail("Resolved tag tree does not match the pinned source tree")

    apk_paths = sorted((source_root / "bin").rglob("*.apk"))
    if not apk_paths:
        fail("The OpenWrt build produced no APK files")

    records = [dump_apk(apk_tool, path) for path in apk_paths]
    by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
    providers: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        name = str(record.get("name", ""))
        by_name[name].append(record)
        providers[name].append(record)
        for provided in list_values(record.get("provides")):
            provider_name, _, _ = parse_dependency(provided)
            providers[provider_name].append(record)

    main_records = {
        name: select_unique(by_name.get(name, []), name)
        for name in MAIN_PACKAGES
        if name != "jq"
    }
    main_records["jq"] = select_and_validate_jq(
        by_name.get("jq", []),
        args.expected_arch,
        args.jq_version,
        source_root / "bin" / "packages" / args.expected_arch / "packages",
    )

    for name, record in main_records.items():
        architecture = str(record.get("arch", record.get("architecture", "")))
        if architecture != args.expected_arch:
            fail(f"{name} architecture is {architecture}, expected {args.expected_arch}")

    ua2f_version = str(main_records["ua2f"].get("version", ""))
    if not ua2f_version.startswith("5.2.0-"):
        fail(f"UA2F APK version is {ua2f_version}, expected 5.2.0 release metadata")

    xray_apk_version = str(main_records["xray-core"].get("version", ""))
    if not xray_apk_version.startswith(f"{args.xray_version}-"):
        fail(
            f"xray-core APK version is {xray_apk_version}, "
            f"expected {args.xray_version} release metadata"
        )

    jq_apk_version = str(main_records["jq"].get("version", ""))
    jq_runtime_dependencies = [
        canonical_dependency(dependency)
        for dependency in list_values(main_records["jq"].get("depends"))
    ]

    rkp_version = str(main_records["kmod-rkp-ipid"].get("version", ""))
    if not rkp_version.startswith(f"{args.expected_linux}-"):
        fail(f"rkp-ipid APK version is {rkp_version}, expected Linux {args.expected_linux}")

    rkp_dependencies = list_values(main_records["kmod-rkp-ipid"].get("depends"))
    kernel_dependencies = [
        canonical_dependency(dep)
        for dep in rkp_dependencies
        if parse_dependency(dep)[0] == "kernel"
    ]
    expected_kernel_dependency = f"kernel={args.expected_kernel_version}"
    if kernel_dependencies != [expected_kernel_dependency]:
        fail(
            "rkp-ipid kernel dependency mismatch: "
            f"found {kernel_dependencies}, expected {[expected_kernel_dependency]}"
        )

    if "kernel" in by_name:
        kernel_record = select_unique(by_name["kernel"], "same-build kernel package")
        if str(kernel_record.get("version", "")) != args.expected_kernel_version:
            fail(
                "Same-build kernel package version does not match baseline: "
                f"{kernel_record.get('version')} != {args.expected_kernel_version}"
            )

    ko_candidates = sorted(
        path
        for path in (source_root / "build_dir").rglob("rkp-ipid.ko")
        if path.is_file()
    )
    if not ko_candidates:
        fail("Compiled rkp-ipid.ko was not found in build_dir")
    ko_path = ko_candidates[0]
    modinfo_text = run(["modinfo", str(ko_path)]).stdout.strip()
    module_vermagic = run(["modinfo", "-F", "vermagic", str(ko_path)]).stdout.strip()
    if not module_vermagic.startswith(args.expected_linux):
        fail(
            f"rkp-ipid.ko vermagic is {module_vermagic}, "
            f"expected prefix {args.expected_linux}"
        )
    module_file = run(["file", str(ko_path)]).stdout.strip()
    if "ARM aarch64" not in module_file and "ARM64" not in module_file:
        fail(f"rkp-ipid.ko is not an AArch64 module: {module_file}")

    # Resolve a bounded transitive closure from the actual built APK metadata.
    selected_dependencies: dict[str, dict[str, Any]] = {}
    unresolved: set[str] = set()
    queue: deque[dict[str, Any]] = deque(main_records.values())
    visited: set[str] = set(MAIN_PACKAGES)

    while queue:
        parent = queue.popleft()
        for raw_dependency in list_values(parent.get("depends")):
            dep_name, operator, required_version = parse_dependency(raw_dependency)
            if not dep_name or dep_name.startswith("!") or dep_name == "kernel":
                continue
            if dep_name in BASE_PACKAGES:
                continue

            candidates = [
                record
                for record in providers.get(dep_name, [])
                if version_matches(record, operator, required_version)
            ]
            if not candidates:
                unresolved.add(canonical_dependency(raw_dependency))
                continue

            resolved = select_unique(candidates, f"dependency {raw_dependency}")
            resolved_name = str(resolved.get("name", dep_name))
            if resolved_name in BASE_PACKAGES or resolved_name in MAIN_PACKAGES:
                continue
            if resolved_name not in selected_dependencies:
                selected_dependencies[resolved_name] = resolved
            if resolved_name not in visited:
                visited.add(resolved_name)
                queue.append(resolved)

            if len(selected_dependencies) > 80:
                fail("Dependency closure exceeded 80 APKs; refusing to create an oversized bundle")

    if unresolved:
        fail("Unresolved APK dependencies: " + ", ".join(sorted(unresolved)))

    out_dir.mkdir(parents=True, exist_ok=True)
    deps_dir = out_dir / "deps"
    deps_dir.mkdir(parents=True, exist_ok=True)

    for name, record in main_records.items():
        destination = out_dir / record_path(record).name
        shutil.copy2(record_path(record), destination)

    for name, record in sorted(selected_dependencies.items()):
        destination = deps_dir / record_path(record).name
        shutil.copy2(record_path(record), destination)

    shutil.copy2(args.public_key, out_dir / "public-key.pem")
    if args.kernel_config_diff.is_file():
        shutil.copy2(args.kernel_config_diff, out_dir / "kernel-config.diff")

    metadata = {
        "main_packages": {
            name: public_record(record, source_root)
            for name, record in main_records.items()
        },
        "dependency_packages": {
            name: public_record(record, source_root)
            for name, record in sorted(selected_dependencies.items())
        },
        "kernel_dependency": expected_kernel_dependency,
        "module_vermagic": module_vermagic,
    }
    (out_dir / "package-metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    dependency_lines = [
        f"{name}\t{record.get('version', '')}\t{record_path(record).name}"
        for name, record in sorted(selected_dependencies.items())
    ]
    (out_dir / "dependency-manifest.txt").write_text(
        ("\n".join(dependency_lines) + "\n") if dependency_lines else "none\n",
        encoding="utf-8",
    )

    (out_dir / "rkp-ipid-modinfo.txt").write_text(
        f"source_module={ko_path.relative_to(source_root)}\n"
        f"file={module_file}\n"
        f"vermagic={module_vermagic}\n\n"
        f"{modinfo_text}\n",
        encoding="utf-8",
    )

    (out_dir / "build-info.txt").write_text(
        "\n".join(
            [
                "device=cmcc_rax3000m-emmc",
                f"arch={args.expected_arch}",
                "openwrt=25.12.5",
                f"kernel={args.expected_linux}",
                "source_repo=shiyu1314/openwrt-source",
                "source_tag=v25.12.5",
                f"pinned_source_commit={args.pinned_source_commit}",
                f"resolved_tag_commit={args.resolved_tag_commit}",
                f"pinned_tree={args.pinned_tree}",
                f"resolved_tag_tree={args.resolved_tag_tree}",
                f"tag_commit_matches={args.tag_commit_matches}",
                f"tag_tree_matches={args.tag_tree_matches}",
                "ua2f_version=5.2.0",
                f"ua2f_upstream_commit={args.ua2f_commit}",
                f"rkp_ipid_upstream_commit={args.rkp_ipid_commit}",
                f"packages_feed_commit={args.packages_feed_commit}",
                f"xray_core_version={args.xray_version}",
                f"jq_version={args.jq_version}",
                f"jq_apk_version={jq_apk_version}",
                "jq_recipe=feeds/packages/utils/jq/Makefile",
                f"jq_runtime_dependencies={','.join(jq_runtime_dependencies)}",
                f"kernel_package_version={args.expected_kernel_version}",
                f"kmod_rkp_ipid_kernel_dependency={expected_kernel_dependency}",
                f"rkp_ipid_module_vermagic={module_vermagic}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    glue_changed = args.baseline_glue != args.final_glue
    baseline_has_glue = args.baseline_glue == "y"
    final_has_glue = args.final_glue == "y"
    apk_only_ua2f = baseline_has_glue and final_has_glue
    full_firmware_recommended = not apk_only_ua2f

    compatibility_lines = [
        "RAX3000M OpenWrt 25.12.5 compatibility report",
        "",
        "Build identity",
        f"- Architecture: {args.expected_arch}",
        f"- Linux version: {args.expected_linux}",
        f"- OpenWrt release: 25.12.5",
        f"- pinned_source_commit={args.pinned_source_commit}",
        f"- resolved_tag_commit={args.resolved_tag_commit}",
        f"- pinned_tree={args.pinned_tree}",
        f"- resolved_tag_tree={args.resolved_tag_tree}",
        f"- tag_commit_matches={args.tag_commit_matches}",
        f"- tag_tree_matches={args.tag_tree_matches}",
        "",
        "NETFILTER_NETLINK_GLUE_CT / UA2F",
        f"- Baseline CONFIG_NETFILTER_NETLINK_GLUE_CT: {args.baseline_glue}",
        f"- Final CONFIG_NETFILTER_NETLINK_GLUE_CT after adding UA2F: {args.final_glue}",
        f"- Adding UA2F changes this kernel symbol: {'yes' if glue_changed else 'no'}",
        "- UA2F v5.2.0 upstream documents NETFILTER_NETLINK_GLUE_CT as required for its connmark feature.",
        f"- Existing firmware can use full UA2F functionality with APK-only install: {'yes' if apk_only_ua2f else 'no'}",
        f"- Full firmware rebuild recommended for UA2F: {'yes' if full_firmware_recommended else 'no'}",
        "- The UA2F userland APK is still built even when the current firmware lacks that built-in kernel capability.",
        "",
        "NFQUEUE / firewall4 / Momo and sing-box",
        f"- CONFIG_PACKAGE_kmod-nft-queue after final defconfig: {args.nft_queue_state}",
        f"- CONFIG_PACKAGE_kmod-nft-tproxy after final defconfig: {args.nft_tproxy_state}",
        "- UA2F v5.2.0 supports nftables and its default mode is NFQUEUE.",
        "- Keep UA2F mode=NFQUEUE; do not use its TPROXY mode alongside Momo/sing-box TPROXY/fwmark handling.",
        "- Set disable_connmark=1 before any future UA2F enablement to reduce connmark conflicts.",
        "- MTK flow offloading, WED, or HNAT can bypass the UA2F/rkp-ipid processing path; this build does not disable them.",
        "",
        "rkp-ipid kernel ABI",
        f"- APK architecture: {main_records['kmod-rkp-ipid'].get('arch', '')}",
        f"- APK version: {rkp_version}",
        f"- Kernel dependency: {expected_kernel_dependency}",
        f"- Baseline kernel package version: {args.expected_kernel_version}",
        "- Same-build dependency comparison: pass",
        f"- Module vermagic: {module_vermagic}",
        "- Full modinfo is in rkp-ipid-modinfo.txt.",
        "- The target router was not queried. Before installation, its installed kernel virtual version must equal the dependency above.",
        "- rkp-ipid uses firewall marks but this bundle installs no mark, TTL, iptables, or nftables rules.",
        "- Because the package contains /etc/modules.d/99-rkp-ipid, OpenWrt default post-install runs kmodloader and may load it immediately.",
        "",
        "jq",
        f"- APK architecture: {main_records['jq'].get('arch', '')}",
        f"- APK version: {jq_apk_version}",
        f"- Runtime dependencies: {', '.join(jq_runtime_dependencies)}",
        "- The standard noregex variant is used; jq-full and Oniguruma are not included.",
        "",
        "Install-time behavior",
        "- UA2F ships enabled=0. OpenWrt default post-install attempts its init script, which exits before launching UA2F or adding rules; the package patch then removes its boot-enable link.",
        "- On nftables systems UA2F's custom post-install only clears a stale firewall.ua2f UCI include and commits UCI; it does not reload firewall or network.",
        "- Xray ships enabled=0. Its init attempt is a no-op and the package patch removes its boot-enable link.",
        "- No service, network, firewall, WAN/LAN, Portal, HNAT, or reboot command is run by this workflow.",
        "",
        "Conclusion",
        f"- Kernel ABI acceptance: pass",
        f"- UA2F APK-only sufficiency: {'sufficient' if apk_only_ua2f else 'limited; rebuild the complete firmware for full support'}",
    ]
    (out_dir / "compatibility-report.txt").write_text(
        "\n".join(compatibility_lines) + "\n",
        encoding="utf-8",
    )

    repositories = '--repository "$BUNDLE_DIR"'
    if selected_dependencies:
        repositories = '--repository "$BUNDLE_DIR/deps" ' + repositories
    common = f'--repositories-file /dev/null {repositories}'
    install_lines = [
        "Run these commands manually from the extracted out/ directory only after checking compatibility-report.txt and signing-info.txt.",
        "The commands install packages but do not configure or enable UA2F/Xray, add mark rules, or restart networking/firewall.",
        "",
        'BUNDLE_DIR="$(pwd)"',
    ]
    if selected_dependencies:
        dependency_names = " ".join(sorted(selected_dependencies))
        install_lines.append(f"apk add {common} {dependency_names}")
    install_lines.extend(
        [
            f"apk add {common} {main_records['ua2f']['name']}",
            f"apk add {common} {main_records['kmod-rkp-ipid']['name']}",
            f"apk add {common} {main_records['jq']['name']}",
            f"apk add {common} {main_records['xray-core']['name']}",
            "",
            "Important: installing kmod-rkp-ipid may load the module immediately through kmodloader.",
            "No force-dependency or untrusted-package option is used.",
        ]
    )
    (out_dir / "install-order.txt").write_text(
        "\n".join(install_lines) + "\n",
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "main": {name: record_path(record).name for name, record in main_records.items()},
                "dependency_count": len(selected_dependencies),
                "baseline_glue": args.baseline_glue,
                "final_glue": args.final_glue,
                "kernel_dependency": expected_kernel_dependency,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr, file=sys.stderr)
        sys.exit(1)
