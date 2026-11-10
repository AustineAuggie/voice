#!/usr/bin/env python3
"""Exercise the app rename/install transaction with simulated Mac commands.

The real Bash helper runs against temporary app bundles. These tests validate
backup/rollback semantics, not macOS code signing or Finder registration.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="voice install test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.built = self.root / "build/Voice.app"
        self.apps = self.root / "Applications"
        self.backups = self.root / "App-backups.noindex"
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.bundle(self.built, "new-voice")
        self.environment = os.environ.copy()
        self.environment.update({"PATH": str(self.commands) + os.pathsep + self.environment["PATH"],
                                 "VOICE_TEST_MV_COUNTER": str(self.root / "mv-count")})
        self.command("ditto", '#!/bin/bash\nif [[ "${VOICE_TEST_COPY_FAIL:-0}" == 1 ]]; then exit 1; fi\nexec cp -R "$1" "$2"\n')
        self.command("codesign", '#!/bin/bash\nexit "${VOICE_TEST_SIGNATURE_FAIL:-0}"\n')
        self.command("plutil", '''#!/usr/bin/env python3
import plistlib,sys
try:
    with open(sys.argv[-1], 'rb') as stream:
        print(plistlib.load(stream)['CFBundleIdentifier'])
except Exception:
    sys.exit(1)
''')
        self.command("mv", '''#!/bin/bash
count=0
if [[ -f "$VOICE_TEST_MV_COUNTER" ]]; then count=$(cat "$VOICE_TEST_MV_COUNTER"); fi
count=$((count + 1))
printf '%s' "$count" > "$VOICE_TEST_MV_COUNTER"
if [[ "$count" == "${VOICE_TEST_FAIL_MOVE:-0}" ]]; then exit 1; fi
exec /bin/mv "$@"
''')

    def command(self, name, text):
        path = self.commands / name
        path.write_text(text)
        path.chmod(0o755)

    def bundle(self, path, marker, identifier="com.sunday.localvoice"):
        path.mkdir(parents=True)
        (path / "identity").write_text(marker)
        (path / "Contents").mkdir()
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))

    def run_install(self, success=True):
        helper = Path(__file__).resolve().parent.parent / "scripts/install-app.sh"
        result = subprocess.run(["bash", str(helper), str(self.built), str(self.apps), str(self.backups)],
                                env=self.environment, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse(list(self.apps.glob(".Voice-stage.*")))
        return result

    def marker(self, path):
        return (path / "identity").read_text()

    def test_fresh_install(self):
        self.run_install()
        self.assertEqual(self.marker(self.apps / "Voice.app"), "new-voice")
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_legacy_name_is_backed_up(self):
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.run_install()
        self.assertFalse((self.apps / "LocalVoice.app").exists())
        self.assertEqual(self.marker(self.apps / "Voice.app"), "new-voice")
        saved = list(self.backups.glob("Previous.*/LocalVoice.app"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0]), "old-localvoice")

    def test_both_names_are_retained(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.run_install()
        saved = list(self.backups.glob("Previous.*"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0] / "Voice.app"), "old-voice")
        self.assertEqual(self.marker(saved[0] / "LocalVoice.app"), "old-localvoice")
        self.assertEqual(self.marker(self.apps / "Voice.app"), "new-voice")

    def test_signature_failure_leaves_existing_apps(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.environment["VOICE_TEST_SIGNATURE_FAIL"] = "1"
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "old-voice")
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_copy_failure_leaves_old_app(self):
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.environment["VOICE_TEST_COPY_FAIL"] = "1"
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")
        self.assertFalse((self.apps / "Voice.app").exists())

    def test_final_move_failure_restores_both_names(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.environment["VOICE_TEST_FAIL_MOVE"] = "3"
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "old-voice")
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")

    def test_second_backup_failure_restores_first_app(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.environment["VOICE_TEST_FAIL_MOVE"] = "2"
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "old-voice")
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")

    def test_fresh_move_failure_leaves_no_partial_app(self):
        self.environment["VOICE_TEST_FAIL_MOVE"] = "1"
        self.run_install(False)
        self.assertFalse((self.apps / "Voice.app").exists())

    def test_rollback_never_nests_old_app_in_occupied_destination(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.command("mv", '''#!/bin/bash
count=0
if [[ -f "$VOICE_TEST_MV_COUNTER" ]]; then count=$(cat "$VOICE_TEST_MV_COUNTER"); fi
count=$((count + 1)); printf '%s' "$count" > "$VOICE_TEST_MV_COUNTER"
if [[ "$count" == 3 ]]; then
  mkdir "$2"; printf '%s' 'unexpected-destination' > "$2/identity"; exit 1
fi
if [[ "$count" == 4 ]]; then exit 1; fi
exec /bin/mv "$@"
''')
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "unexpected-destination")
        self.assertFalse((self.apps / "Voice.app/Voice.app").exists())
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")
        saved = list(self.backups.glob("Previous.*/Voice.app"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0]), "old-voice")

    def test_existing_symlink_is_left_untouched(self):
        outside = self.root / "outside.app"
        self.bundle(outside, "do-not-move")
        self.apps.mkdir()
        (self.apps / "LocalVoice.app").symlink_to(outside, target_is_directory=True)
        self.run_install(False)
        self.assertTrue((self.apps / "LocalVoice.app").is_symlink())
        self.assertEqual(self.marker(outside), "do-not-move")

    def test_unrelated_voice_app_is_left_untouched(self):
        self.bundle(self.apps / "Voice.app", "other-product", "com.example.voice")
        self.bundle(self.apps / "LocalVoice.app", "old-localvoice")
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "other-product")
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "old-localvoice")
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_unrelated_legacy_name_is_left_untouched(self):
        self.bundle(self.apps / "Voice.app", "old-voice")
        self.bundle(self.apps / "LocalVoice.app", "other-product", "com.example.localvoice")
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "old-voice")
        self.assertEqual(self.marker(self.apps / "LocalVoice.app"), "other-product")
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_malformed_existing_bundle_is_left_untouched(self):
        self.bundle(self.apps / "Voice.app", "unknown-app")
        (self.apps / "Voice.app/Contents/Info.plist").write_text("not a plist")
        self.run_install(False)
        self.assertEqual(self.marker(self.apps / "Voice.app"), "unknown-app")
        self.assertEqual(list(self.backups.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
