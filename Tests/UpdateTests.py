#!/usr/bin/env python3
"""Exercise the checked upgrade without running a Mac installer.

Usage: python3 Tests/UpdateTests.py /path/to/LocalVoice-0.4.2 /path/to/LocalVoice-0.5.0 /path/to/Voice-0.6.0
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="localvoice-update-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "Voice-0.6.1"
        shutil.copytree(SOURCE, self.source, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        self.manifest = GENERATOR.generate(self.source, BASELINE, PREVIOUS, LATEST)
        self.write_manifest()
        self.target = self.root / "LocalVoice-0.4.0"
        shutil.copytree(BASELINE, self.target, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        self.marker = self.target / ".build/completed-worker"
        self.marker.parent.mkdir(exist_ok=True)
        self.marker.write_bytes(b"native cache")
        self.original = self.snapshot()

    def write_manifest(self):
        (self.source / "scripts/update-manifest.json").write_text(json.dumps(self.manifest))

    def snapshot(self):
        return {p.relative_to(self.target).as_posix(): p.read_bytes()
                for p in self.target.rglob("*") if p.is_file()
                and ".build" not in p.relative_to(self.target).parts}

    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()):
            UPDATE.apply(self.source, self.target)

    def assert_unchanged(self):
        self.assertEqual(self.original, self.snapshot())
        self.assertEqual(self.marker.read_bytes(), b"native cache")

    def assert_updated(self):
        for relative in self.manifest["files"]:
            self.assertEqual((self.target / relative).read_bytes(), (self.source / relative).read_bytes())
        self.assertEqual(self.marker.read_bytes(), b"native cache")

    def test_upgrade_042_keeps_cache_and_backups(self):
        self.apply()
        self.assert_updated()
        backups = list((self.target / ".build").glob("update-0.6.1-backup-*"))
        self.assertEqual(len(backups), 1)
        for relative, previous in self.original.items():
            if relative in self.manifest["files"] and previous != (self.source / relative).read_bytes():
                self.assertEqual((backups[0] / relative).read_bytes(), previous)

    def test_upgrade_050_and_repeat_keeps_cached_engines(self):
        shutil.rmtree(self.target)
        shutil.copytree(PREVIOUS, self.target, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        self.marker.parent.mkdir(exist_ok=True)
        self.marker.write_bytes(b"native cache")
        self.original = self.snapshot()
        self.apply()
        self.assert_updated()
        applied = self.snapshot()
        self.apply()
        self.assertEqual(applied, self.snapshot())

    def test_previous_release_manifest_must_match_its_bytes(self):
        previous = self.root / "changed-050"
        shutil.copytree(PREVIOUS, previous, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        file = previous / "Sources/MeetingState.swift"
        file.write_bytes(file.read_bytes() + b"\n// modified previous release\n")
        with self.assertRaisesRegex(ValueError, "Previous release payload differs"):
            GENERATOR.generate(self.source, BASELINE, previous, LATEST)

    def test_upgrade_060_and_repeat_keeps_cached_engines(self):
        shutil.rmtree(self.target)
        shutil.copytree(LATEST, self.target, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        self.marker.parent.mkdir(exist_ok=True)
        self.marker.write_bytes(b"native cache")
        self.original = self.snapshot()
        self.apply()
        self.assert_updated()
        applied = self.snapshot()
        self.apply()
        self.assertEqual(applied, self.snapshot())

    def test_latest_release_manifest_must_match_its_bytes(self):
        latest = self.root / "changed-060"
        shutil.copytree(LATEST, latest, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        file = latest / "Sources/MeetingState.swift"
        file.write_bytes(file.read_bytes() + b"\n// modified latest release\n")
        with self.assertRaisesRegex(ValueError, "Previous release payload differs"):
            GENERATOR.generate(self.source, BASELINE, PREVIOUS, latest)

    def test_edited_060_input_refused_before_writes(self):
        shutil.rmtree(self.target)
        shutil.copytree(LATEST, self.target, ignore=shutil.ignore_patterns(".build", "__pycache__", "dist.noindex"))
        self.marker.parent.mkdir(exist_ok=True)
        self.marker.write_bytes(b"native cache")
        file = self.target / "Sources/MeetingState.swift"
        file.write_bytes(file.read_bytes() + b"\n// preserve my local change\n")
        self.original = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Unrecognised edits"):
            self.apply()
        self.assert_unchanged()
        self.assertFalse(list((self.target / ".build").glob("update-*")))

    def test_repaired_original_folder_may_lack_later_added_files(self):
        history = json.loads((BASELINE / "scripts/repair-manifest.json").read_text())
        original_names = set(history["files"]) | set(history["unchanged"])
        for relative in self.original:
            if relative not in original_names:
                (self.target / relative).unlink()
        self.apply()
        self.assert_updated()

    def test_historical_040_041_hashes_are_accepted(self):
        history = json.loads((BASELINE / "scripts/repair-manifest.json").read_text())
        for relative, old in history["files"].items():
            if relative in self.manifest["files"]:
                accepted = self.manifest["files"][relative]["accepted"]
                for digest in old["before"] + [old["after"]]:
                    self.assertIn(digest, accepted)
        # Exercise selection of an accepted historical version through the
        # real apply path, without pretending hashes can recreate old bytes.
        relative = "Sources/MeetingState.swift"
        old_bytes = b"// historical source fixture\n"
        self.manifest["files"][relative]["accepted"].append(UPDATE.digest(old_bytes))
        (self.target / relative).write_bytes(old_bytes)
        self.write_manifest()
        self.apply()
        self.assert_updated()

    def test_idempotent_repeat(self):
        self.apply()
        snapshot = self.snapshot()
        backups = list((self.target / ".build").glob("update-0.6.1-backup-*"))
        self.apply()
        self.assertEqual(self.snapshot(), snapshot)
        self.assertEqual(list((self.target / ".build").glob("update-0.6.1-backup-*")), backups)

    def test_edited_input_refused_before_writes(self):
        file = self.target / "Sources/MeetingState.swift"
        file.write_bytes(file.read_bytes() + b"\n// local edit\n")
        self.original = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Unrecognised edits"):
            self.apply()
        self.assert_unchanged()
        self.assertFalse(list((self.target / ".build").glob("update-*")))

    def test_damaged_payload_refused_before_writes(self):
        file = self.source / "Sources/MeetingState.swift"
        file.write_bytes(file.read_bytes() + b"\n// damaged download\n")
        with self.assertRaisesRegex(ValueError, "downloaded update is incomplete"):
            self.apply()
        self.assert_unchanged()

    def test_unknown_swift_input_refused(self):
        (self.target / "Sources/Custom.swift").write_text("// preserve this local file\n")
        self.original = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Unknown source input"):
            self.apply()
        self.assert_unchanged()

    def test_finder_metadata_preserved_but_symlink_refused(self):
        for directory in ("Sources", "Native"):
            (self.target / directory / ".DS_Store").write_bytes(b"Finder metadata")
        self.apply()
        self.assert_updated()
        for directory in ("Sources", "Native"):
            self.assertEqual((self.target / directory / ".DS_Store").read_bytes(), b"Finder metadata")
        metadata = self.target / "Sources/.DS_Store"
        metadata.unlink()
        outside = self.root / "outside-metadata"
        outside.write_bytes(b"Do not follow")
        metadata.symlink_to(outside)
        self.original = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Unknown source input"):
            self.apply()
        self.assert_unchanged()
        self.assertEqual(outside.read_bytes(), b"Do not follow")

    def test_missing_original_file_refused(self):
        (self.target / "Sources/MeetingState.swift").unlink()
        self.original = self.snapshot()
        with self.assertRaisesRegex(ValueError, "existing project file is missing"):
            self.apply()
        self.assert_unchanged()

    def test_failure_restores_old_and_removes_new_files(self):
        # Ensure a newly created file is committed before the injected failure.
        existing = "README.md"
        added = "Sources/UpdateRollbackFixture.swift"
        content = b"// new source for rollback test\n"
        (self.source / added).write_bytes(content)
        entry = {"accepted": [UPDATE.digest(content)], "after": UPDATE.digest(content), "allow_missing": True, "mode": "0644"}
        others = {k: v for k, v in self.manifest["files"].items() if k != existing}
        # Force an existing-file change even when the source docs are unchanged.
        content = (self.source / existing).read_bytes() + b"\nUpgrade regression fixture.\n"
        (self.source / existing).write_bytes(content)
        prior = self.manifest["files"][existing]
        prior["after"] = UPDATE.digest(content)
        prior["accepted"].append(prior["after"])
        self.manifest["files"] = {existing: prior, added: entry, **others}
        self.write_manifest()
        original_replace = os.replace
        calls = 0
        def fail_once(src, dst):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError("simulated replace failure")
            original_replace(src, dst)
        with patch.object(UPDATE.os, "replace", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "simulated replace failure"):
                self.apply()
        self.assert_unchanged()
        self.assertFalse((self.target / added).exists())
        self.assertFalse(list((self.target / ".build").glob("update-0.6.1-stage-*")))
        self.apply()
        self.assert_updated()

    def test_source_and_cache_symlinks_refused(self):
        file = self.target / "Sources/MeetingState.swift"
        outside = self.root / "original.swift"
        file.rename(outside); file.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            self.apply()
        self.assert_unchanged()
        file.unlink(); outside.rename(file)
        cache = self.target / ".build"
        outside_cache = self.root / "outside-cache"
        cache.rename(outside_cache); cache.symlink_to(outside_cache, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            self.apply()
        self.assert_unchanged()

    def test_script_permissions_and_unrelated_files(self):
        setup = self.target / "setup.sh"
        setup.chmod(0o640)
        (self.target / "my-notes.txt").write_text("Keep my notes")
        self.apply()
        self.assertEqual(stat.S_IMODE(setup.stat().st_mode), 0o640)
        for relative, entry in self.manifest["files"].items():
            if relative not in self.original:
                self.assertEqual(stat.S_IMODE((self.target / relative).stat().st_mode), int(entry["mode"], 8))
        self.assertEqual((self.target / "my-notes.txt").read_text(), "Keep my notes")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: python3 Tests/UpdateTests.py /path/to/LocalVoice-0.4.2 /path/to/LocalVoice-0.5.0 /path/to/Voice-0.6.0")
    BASELINE = Path(sys.argv[1]).resolve()
    PREVIOUS = Path(sys.argv[2]).resolve()
    LATEST = Path(sys.argv[3]).resolve()
    SOURCE = Path(__file__).resolve().parent.parent
    GENERATOR = module("make_update", SOURCE / "scripts/make-update-manifest.py")
    UPDATE = module("apply_update", SOURCE / "scripts/apply-update.py")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
