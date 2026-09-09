#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "sh" / "campus-apk-build.sh"
START_MARKER = '  python3 - "$metadata" "$scripts" <<\'PY\'\n'
END_MARKER = "\nPY\n"
DEPENDENCIES = (
    "dnsmasq-full",
    "dnsproxy",
    "bind-dig",
    "jsonfilter",
    "ubus",
    "uclient-fetch",
    "ca-bundle",
)


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def validator_source():
    source = BUILD_SCRIPT.read_text(encoding="utf-8")
    try:
        start = source.index(START_MARKER) + len(START_MARKER)
        end = source.index(END_MARKER, start)
    except ValueError as exc:
        raise SystemExit("FAIL: could not locate inline APK validator") from exc
    return source[start:end]


def valid_payload():
    return {
        "info": {
            "name": "portal-dns-guard",
            "version": "1.0.0-r1",
            "arch": "noarch",
            "depends": [{"name": name} for name in DEPENDENCIES],
        },
        "scripts": {
            "post-install": (
                "#!/bin/sh\n"
                'export pkgname="portal-dns-guard"\n'
                'printf \'%s\\n\' "$pkgname/path/with \'quotes\'"\n'
                "default_postinst\n"
            ),
            "post-upgrade": (
                "#!/bin/sh\n"
                "export PKG_UPGRADE=1\n"
                'printf "%s\\n" "$PKG_UPGRADE/path/with \'quotes\'"\n'
                "default_postinst\n"
            ),
        },
    }


def run_case(source, payload):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        metadata = root / "metadata.json"
        scripts = root / "scripts.txt"
        metadata.write_text(json.dumps(payload), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-c", source, str(metadata), str(scripts)],
            check=False,
            capture_output=True,
            text=True,
        )
        output = scripts.read_text(encoding="utf-8") if scripts.exists() else ""
        return result, output


def expect_pass(source):
    result, output = run_case(source, valid_payload())
    if result.returncode != 0:
        fail(f"plain multiline shell scripts were rejected: {result.stderr.strip()}")
    expected = (
        "post-install: default_postinst present\n"
        "post-upgrade: default_postinst present\n"
    )
    if output != expected:
        fail(f"unexpected validator audit output: {output!r}")


def expect_failure(source, name, mutate, expected_error):
    payload = valid_payload()
    mutate(payload["scripts"])
    result, _ = run_case(source, payload)
    if result.returncode == 0:
        fail(f"{name} unexpectedly passed")
    if expected_error not in result.stderr:
        fail(
            f"{name} returned the wrong error: expected {expected_error!r}, "
            f"got {result.stderr.strip()!r}"
        )


def main():
    source = validator_source()
    expect_pass(source)

    cases = (
        (
            "missing post-install",
            lambda scripts: scripts.pop("post-install"),
            "missing APK script post-install",
        ),
        (
            "null post-install",
            lambda scripts: scripts.__setitem__("post-install", None),
            "invalid APK script post-install: expected string, got NoneType",
        ),
        (
            "numeric post-install",
            lambda scripts: scripts.__setitem__("post-install", 7),
            "invalid APK script post-install: expected string, got int",
        ),
        (
            "object post-install",
            lambda scripts: scripts.__setitem__("post-install", {}),
            "invalid APK script post-install: expected string, got dict",
        ),
        (
            "array post-install",
            lambda scripts: scripts.__setitem__("post-install", []),
            "invalid APK script post-install: expected string, got list",
        ),
        (
            "empty post-install",
            lambda scripts: scripts.__setitem__("post-install", ""),
            "empty APK script post-install",
        ),
        (
            "post-install missing shebang",
            lambda scripts: scripts.__setitem__(
                "post-install",
                scripts["post-install"].replace("#!/bin/sh\n", ""),
            ),
            "post-install is missing required line: #!/bin/sh",
        ),
        (
            "post-install wrong pkgname",
            lambda scripts: scripts.__setitem__(
                "post-install",
                scripts["post-install"].replace(
                    'export pkgname="portal-dns-guard"',
                    'export pkgname="wrong-package"',
                ),
            ),
            'post-install is missing required line: export pkgname="portal-dns-guard"',
        ),
        (
            "post-install missing default_postinst",
            lambda scripts: scripts.__setitem__(
                "post-install",
                scripts["post-install"].replace("default_postinst\n", ""),
            ),
            "post-install is missing required line: default_postinst",
        ),
        (
            "post-upgrade missing PKG_UPGRADE",
            lambda scripts: scripts.__setitem__(
                "post-upgrade",
                scripts["post-upgrade"].replace("export PKG_UPGRADE=1\n", ""),
            ),
            "post-upgrade is missing required line: export PKG_UPGRADE=1",
        ),
        (
            "post-upgrade missing default_postinst",
            lambda scripts: scripts.__setitem__(
                "post-upgrade",
                scripts["post-upgrade"].replace("default_postinst\n", ""),
            ),
            "post-upgrade is missing required line: default_postinst",
        ),
    )
    for name, mutate, expected_error in cases:
        expect_failure(source, name, mutate, expected_error)

    print("PASS: portal-dns-guard APK validator tests")


if __name__ == "__main__":
    main()
