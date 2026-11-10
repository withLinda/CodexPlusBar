#!/usr/bin/env python3
"""Prepare and publish the required DMG, fresh OpenChamber ZIP and checksums."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / "Extensions/expiry-selector"
ASSETS = ("CodexPlusBar.dmg", "expiry-selector.zip")
DISTRIBUTION = {
    "package.json", "plugin/package.json", "plugin/index.js", "service/main.js",
    "panel/index.html", "panel/main.js", "icon.svg", "README.md",
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def package_assets(dmg, dist, output):
    if output.exists():
        raise FileExistsError(f"Use a fresh release directory: {output}")
    if not dmg.is_file() or dmg.is_symlink() or not dmg.stat().st_size:
        raise ValueError("A completed, nonempty notarized DMG is required")
    paths = list(dist.rglob("*"))
    if dist.is_symlink() or any(path.is_symlink() for path in paths):
        raise ValueError("Extension distribution must not contain symlinks")
    files = {path.relative_to(dist).as_posix() for path in paths if path.is_file()}
    if files != DISTRIBUTION:
        raise ValueError(f"Incomplete or unexpected extension distribution: {files ^ DISTRIBUTION}")
    output.mkdir(parents=True)
    shutil.copyfile(dmg, output / ASSETS[0])
    with zipfile.ZipFile(output / ASSETS[1], "w") as archive:
        for name in sorted(files):
            # Fixed timestamps/permissions make identical source builds reproducible.
            entry = zipfile.ZipInfo("expiry-selector/" + name)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, (dist / name).read_bytes())
    (output / "SHA256SUMS").write_text("".join(digest(output / name) + "  " + name + "\n" for name in ASSETS))
    verify_assets(output)


def verify_assets(directory):
    for name in (*ASSETS, "SHA256SUMS"):
        file = directory / name
        if not file.is_file() or file.is_symlink() or not file.stat().st_size:
            raise ValueError(f"Missing release asset: {name}")
    lines = (directory / "SHA256SUMS").read_text().splitlines()
    expected = [digest(directory / name) + "  " + name for name in ASSETS]
    if sorted(lines) != sorted(expected):
        raise ValueError("SHA256SUMS must match both the DMG and extension ZIP")
    try:
        with zipfile.ZipFile(directory / ASSETS[1]) as archive:
            entries = archive.infolist()
            names = {entry.filename for entry in entries}
            if len(entries) != len(DISTRIBUTION) or names != {"expiry-selector/" + name for name in DISTRIBUTION}:
                raise ValueError("ZIP must contain only the complete expiry-selector/ distribution")
            if any(stat.S_ISLNK(entry.external_attr >> 16) for entry in entries) or archive.testzip():
                raise ValueError("Invalid extension ZIP payload")
            metadata = json.loads(archive.read("expiry-selector/package.json"))
            plugin = json.loads(archive.read("expiry-selector/plugin/package.json"))
            if (metadata.get("name") != "codexplusbar-expiry-selector" or not metadata.get("version")
                    or plugin.get("version") != metadata["version"]
                    or metadata.get("openchamber", {}).get("apiVersion") != 1):
                raise ValueError("Invalid extension package identity/version")
    except (zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError("Unreadable extension ZIP") from error
    print(f"Verified DMG + Account Priority {metadata['version']} ZIP + SHA256SUMS: {directory}")


def prepare(dmg, output):
    if output.exists():
        raise FileExistsError(f"Use a fresh release directory: {output}")
    if not dmg.is_file():
        raise ValueError(f"DMG not found: {dmg}")
    # Always rebuild from this checkout and its lockfile; never reuse a previous ZIP.
    for arguments in (["ci"], ["run", "build"], ["run", "verify:package"]):
        subprocess.run(["npm", *arguments], cwd=EXTENSION, check=True)
    package_assets(dmg, EXTENSION / "dist", output)


def publish(directory, tag, target, notes):
    verify_assets(directory)
    if not re.fullmatch(r"v[0-9][A-Za-z0-9._-]*", tag) or not re.fullmatch(r"[0-9a-f]{40}", target):
        raise ValueError("Use a version tag and full 40-character commit SHA")
    if not notes.is_file():
        raise ValueError("Release notes file is required")
    subprocess.run(["gh", "release", "create", tag, *[str(directory / name) for name in (*ASSETS, "SHA256SUMS")],
                    "--target", target, "--title", f"CodexPlusBar {tag[1:]}", "--notes-file", str(notes), "--draft"],
                   cwd=ROOT, check=True)
    # Keep failed/incomplete uploads in draft; only publish verified downloaded bytes.
    with tempfile.TemporaryDirectory(prefix="release-download-", dir=directory.parent) as temporary:
        downloaded = Path(temporary)
        subprocess.run(["gh", "release", "download", tag, "--dir", str(downloaded)], cwd=ROOT, check=True)
        verify_assets(downloaded)
        if any(digest(downloaded / name) != digest(directory / name) for name in (*ASSETS, "SHA256SUMS")):
            raise ValueError("Downloaded release differs from the prepared assets; release remains draft")
    subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest"], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="Rebuild extension and prepare all release assets")
    prepare_parser.add_argument("--dmg", type=Path, required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)
    verify_parser = commands.add_parser("verify", help="Verify required assets, archive layout and checksums")
    verify_parser.add_argument("--assets", type=Path, required=True)
    publish_parser = commands.add_parser("publish", help="Publish verified assets via GitHub CLI")
    publish_parser.add_argument("--assets", type=Path, required=True)
    publish_parser.add_argument("--tag", required=True)
    publish_parser.add_argument("--target", required=True)
    publish_parser.add_argument("--notes", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.command == "prepare":
        prepare(arguments.dmg.resolve(), arguments.output.resolve())
    elif arguments.command == "verify":
        verify_assets(arguments.assets.resolve())
    else:
        publish(arguments.assets.resolve(), arguments.tag, arguments.target, arguments.notes.resolve())


if __name__ == "__main__":
    main()
