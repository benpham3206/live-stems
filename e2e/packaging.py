"""Inspect a packaged Live Stems bundle without changing it."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys


IDENTIFIER = "com.benpham.livestems"
EXECUTABLE = "LiveStems"
ICON_NAME = "LiveStems"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class PackagingFailure(Exception):
    """A package check did not meet an acceptance criterion."""


def read_plist(path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise PackagingFailure(f"cannot read Info.plist: {error}") from error


def read_settings(path):
    try:
        settings = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackagingFailure(f"cannot read local.json: {error}") from error
    if not isinstance(settings, dict) or not isinstance(settings.get("root"), str):
        raise PackagingFailure("local.json has no string root")
    return settings


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_icns(path):
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise PackagingFailure(f"cannot read LiveStems.icns: {error}") from error
    if len(raw) < 8 or raw[:4] != b"icns":
        raise PackagingFailure("LiveStems.icns has no icns header")
    declared = struct.unpack(">I", raw[4:8])[0]
    if declared != len(raw):
        raise PackagingFailure(
            f"LiveStems.icns header length {declared} != file size {len(raw)}"
        )

    elements = []
    png_elements = []
    offset = 8
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise PackagingFailure("LiveStems.icns has a truncated element header")
        kind = raw[offset : offset + 4].decode("ascii", "replace")
        element_size = struct.unpack(">I", raw[offset + 4 : offset + 8])[0]
        if element_size < 8 or offset + element_size > len(raw):
            raise PackagingFailure(f"LiveStems.icns has an invalid {kind} element size")
        payload = raw[offset + 8 : offset + element_size]
        element = {"type": kind, "bytes": element_size, "payload_bytes": len(payload)}
        if payload.startswith(PNG_SIGNATURE):
            if len(payload) < 33:
                raise PackagingFailure(f"LiveStems.icns {kind} PNG is truncated")
            ihdr_length = struct.unpack(">I", payload[8:12])[0]
            if payload[12:16] != b"IHDR" or ihdr_length != 13:
                raise PackagingFailure(f"LiveStems.icns {kind} has no valid PNG IHDR")
            width, height = struct.unpack(">II", payload[16:24])
            bit_depth = payload[24]
            color_type = payload[25]
            has_alpha = color_type in (4, 6)
            if not has_alpha:
                raise PackagingFailure(
                    f"LiveStems.icns {kind} PNG has no alpha color type: {color_type}"
                )
            element.update(
                {
                    "width": width,
                    "height": height,
                    "bit_depth": bit_depth,
                    "color_type": color_type,
                    "has_alpha": has_alpha,
                }
            )
            png_elements.append(element)
        elements.append(element)
        offset += element_size
    if offset != len(raw):
        raise PackagingFailure("LiveStems.icns element records do not fill the file")
    if not png_elements:
        raise PackagingFailure("LiveStems.icns has no alpha-capable PNG elements")
    return {
        "bytes": len(raw),
        "sha256": sha256(path),
        "declared_bytes": declared,
        "elements": elements,
        "png_elements": png_elements,
    }


def command(args):
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def inspect_bundle(app, expected_root):
    app = Path(app).expanduser()
    expected_root = Path(expected_root).expanduser().resolve()
    if not app.is_dir() or app.is_symlink():
        raise PackagingFailure(f"bundle is missing or is a symlink: {app}")

    info_path = app / "Contents/Info.plist"
    executable_path = app / "Contents/MacOS" / EXECUTABLE
    settings_path = app / "Contents/Resources/local.json"
    icon_path = app / "Contents/Resources/LiveStems.icns"
    plist = read_plist(info_path)
    settings = read_settings(settings_path)
    actual_root = Path(settings["root"]).expanduser().resolve()
    if actual_root != expected_root:
        raise PackagingFailure(
            f"local.json root {actual_root} does not match {expected_root}"
        )
    if plist.get("CFBundleIdentifier") != IDENTIFIER:
        raise PackagingFailure("CFBundleIdentifier is not stable")
    if plist.get("CFBundleExecutable") != EXECUTABLE:
        raise PackagingFailure("CFBundleExecutable is not LiveStems")
    if plist.get("CFBundleIconFile") != ICON_NAME:
        raise PackagingFailure("CFBundleIconFile is not LiveStems")
    if plist.get("CFBundlePackageType") != "APPL":
        raise PackagingFailure("CFBundlePackageType is not APPL")
    if not executable_path.is_file() or not os.access(executable_path, os.X_OK):
        raise PackagingFailure("LiveStems executable is missing or not executable")

    icon = parse_icns(icon_path)
    verified = command(["codesign", "--verify", "--strict", str(app)])
    if verified.returncode != 0:
        raise PackagingFailure(f"strict codesign verification failed: {verified.stdout.strip()}")
    requirement = command(["codesign", "-d", "-r-", str(app)]).stdout
    designated = next(
        (line.strip() for line in requirement.splitlines() if "designated =>" in line),
        "",
    )
    if f'identifier "{IDENTIFIER}"' not in designated or "cdhash" in designated:
        raise PackagingFailure("designated requirement has no stable identifier")

    return {
        "status": "pass",
        "app": str(app),
        "bundle_identifier": plist["CFBundleIdentifier"],
        "bundle_executable": plist["CFBundleExecutable"],
        "bundle_icon_file": plist["CFBundleIconFile"],
        "workspace_root": str(actual_root),
        "executable": str(executable_path),
        "icon": icon,
        "signature": {
            "strict_codesign": True,
            "designated_requirement": designated,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--expected-root", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        report = inspect_bundle(args.app, args.expected_root)
    except PackagingFailure as error:
        report = {"status": "fail", "app": str(args.app), "failure": str(error)}
    encoded = json.dumps(report, indent=2) + "\n"
    print(encoded, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
