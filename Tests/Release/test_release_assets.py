import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts/release_assets.py"
spec = importlib.util.spec_from_file_location("release_assets", SCRIPT)
release = importlib.util.module_from_spec(spec) if SCRIPT.exists() else None
if release:
    spec.loader.exec_module(release)


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(release, "Release preparation must include the extension ZIP")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.dist = self.root / "dist"
        self.files = {
            "package.json": json.dumps({"name": "codexplusbar-expiry-selector", "version": "0.2.0",
                "type": "module", "openchamber": {"apiVersion": 1}}).encode(),
            "plugin/package.json": b'{"type":"module","exports":"./index.js","version":"0.2.0"}',
            "plugin/index.js": b"export default { id: 'synthetic' };",
            "service/main.js": b"// synthetic service",
            "panel/main.js": b"console.log('synthetic panel');",
            "panel/index.html": b'<script src="./main.js"></script>',
            "icon.svg": b"<svg/>",
            "README.md": b"Synthetic extension instructions",
        }
        for name, data in self.files.items():
            file = self.dist / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        self.dmg = self.root / "signed-original.dmg"
        self.dmg.write_bytes(b"synthetic signed disk image bytes")
        self.output = self.root / "github"

    def prepare(self):
        release.package_assets(self.dmg, self.dist, self.output)

    def test_archive_installs_as_one_folder_and_checksums_match_both_assets(self):
        self.prepare()
        self.assertEqual({p.name for p in self.output.iterdir()},
                         {"CodexPlusBar.dmg", "expiry-selector.zip", "SHA256SUMS"})
        self.assertEqual((self.output / "CodexPlusBar.dmg").read_bytes(), self.dmg.read_bytes())
        with zipfile.ZipFile(self.output / "expiry-selector.zip") as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {"expiry-selector/" + name for name in self.files})
            for name, data in self.files.items():
                self.assertEqual(archive.read("expiry-selector/" + name), data)
        lines = (self.output / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        release.verify_assets(self.output)

    def test_missing_extra_or_symlinked_distribution_files_are_rejected(self):
        missing = self.dist / "plugin/index.js"
        missing.unlink()
        with self.assertRaises(ValueError):
            self.prepare()
        missing.write_bytes(self.files["plugin/index.js"])
        extra = self.dist / "fixture-credentials.json"
        extra.write_text("synthetic fixture; never distribute")
        with self.assertRaises(ValueError):
            self.prepare()
        extra.unlink()
        missing.unlink()
        missing.symlink_to(self.dist / "service/main.js")
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved_instead_of_mixing_release_files(self):
        self.output.mkdir()
        sentinel = self.output / "previous.zip"
        sentinel.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_missing_extension_or_changed_bytes_block_publication_before_github(self):
        self.prepare()
        notes = self.root / "notes.md"
        notes.write_text("Synthetic release")
        for name in ["expiry-selector.zip", "CodexPlusBar.dmg", "SHA256SUMS"]:
            asset = self.output / name
            original = asset.read_bytes()
            for changed in [None, b"changed"]:
                with self.subTest(name=name, changed=changed):
                    if changed is None:
                        asset.unlink()
                    else:
                        asset.write_bytes(changed)
                    with patch.object(release.subprocess, "run") as github:
                        with self.assertRaises(ValueError):
                            release.publish(self.output, "v1.8.0", "a" * 40, notes)
                        github.assert_not_called()
                    asset.write_bytes(original)

    def test_zip_payload_validation_is_independent_of_its_checksum(self):
        self.prepare()
        archive = self.output / "expiry-selector.zip"
        with zipfile.ZipFile(archive, "a") as output:
            output.writestr("expiry-selector/../outside.txt", "unsafe archive layout")
        sums = self.output / "SHA256SUMS"
        sums.write_text("".join(hashlib.sha256((self.output / name).read_bytes()).hexdigest()
                                + "  " + name + "\n" for name in ["CodexPlusBar.dmg", "expiry-selector.zip"]))
        with self.assertRaises(ValueError):
            release.verify_assets(self.output)

    def test_publication_requires_uploaded_bytes_to_match_before_leaving_draft(self):
        self.prepare()
        notes = self.root / "notes.md"
        notes.write_text("Synthetic release")
        for changed in [False, True]:
            commands = []

            def github(arguments, **options):
                commands.append(arguments)
                if arguments[1:3] == ["release", "download"]:
                    downloaded = pathlib.Path(arguments[arguments.index("--dir") + 1])
                    for file in self.output.iterdir():
                        shutil.copyfile(file, downloaded / file.name)
                    if changed:
                        (downloaded / "CodexPlusBar.dmg").write_bytes(b"different validly checksummed image")
                        (downloaded / "SHA256SUMS").write_text("".join(
                            hashlib.sha256((downloaded / name).read_bytes()).hexdigest() + "  " + name + "\n"
                            for name in ["CodexPlusBar.dmg", "expiry-selector.zip"]))

            with self.subTest(changed=changed), patch.object(release.subprocess, "run", side_effect=github):
                if changed:
                    with self.assertRaises(ValueError):
                        release.publish(self.output, "v1.8.0", "a" * 40, notes)
                    self.assertEqual([command[2] for command in commands], ["create", "download"])
                else:
                    release.publish(self.output, "v1.8.0", "a" * 40, notes)
                    self.assertEqual([command[2] for command in commands], ["create", "download", "edit"])
                    self.assertIn("--draft=false", commands[-1])
                create = commands[0]
                for name in ["CodexPlusBar.dmg", "expiry-selector.zip", "SHA256SUMS"]:
                    self.assertIn(str(self.output / name), create)
                self.assertIn("--draft", create)

    def test_upload_failure_cannot_publish(self):
        self.prepare()
        notes = self.root / "notes.md"
        notes.write_text("Synthetic release")
        with patch.object(release.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "gh")) as github:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish(self.output, "v1.8.0", "a" * 40, notes)
            self.assertEqual(github.call_count, 1)
            self.assertEqual(github.call_args.args[0][2], "create")


if __name__ == "__main__":
    unittest.main()
