#!/usr/bin/env python3
"""Apply checked 0.6.1 source files while preserving the native build cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def contained(root, relative):
    name = Path(relative)
    if not relative or name.is_absolute() or ".." in name.parts or relative != name.as_posix():
        raise ValueError("Invalid update path: " + relative)
    path = root
    for part in name.parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Refusing a symbolic link in the update path: " + relative)
    path.resolve().relative_to(root.resolve())
    return path


def apply(source, target):
    if not source.is_dir() or not target.is_dir() or target.is_symlink():
        raise ValueError("The source and target must be ordinary project folders")
    manifest = json.loads((source / "scripts/update-manifest.json").read_text())
    if manifest.get("version") != "0.6.1" or not isinstance(manifest.get("files"), dict):
        raise ValueError("Invalid update manifest")
    payload = manifest["files"]
    # Unexpected extra Swift/C++ input can silently alter the build. Preserve
    # unrelated files elsewhere, but refuse unknown additions to these roots.
    for directory in manifest.get("source_roots", []):
        folder = contained(target, directory)
        if folder.exists():
            for path in folder.rglob("*"):
                if path.is_file() or path.is_symlink():
                    relative = path.relative_to(target).as_posix()
                    # Finder creates these alongside source files. They do not
                    # participate in the build; preserve ordinary files only.
                    if path.name == ".DS_Store" and path.is_file() and not path.is_symlink():
                        continue
                    if relative not in payload:
                        raise ValueError("Unknown source input was left untouched: " + relative)
    pending = []
    for relative, entry in payload.items():
        src, dst = contained(source, relative), contained(target, relative)
        data = src.read_bytes()
        if digest(data) != entry["after"]:
            raise ValueError("The downloaded update is incomplete: " + relative)
        if dst.exists():
            if not dst.is_file():
                raise ValueError("An update file is a directory: " + relative)
            current = digest(dst.read_bytes())
            if current not in entry["accepted"]:
                raise ValueError("Unrecognised edits were left untouched: " + relative)
            if current == entry["after"]:
                continue
            mode = stat.S_IMODE(dst.stat().st_mode)
        else:
            if not entry["allow_missing"]:
                raise ValueError("An existing project file is missing: " + relative)
            mode = int(entry["mode"], 8)
        pending.append((relative, dst, data, mode, dst.exists()))
    if not pending:
        print("Voice 0.6.1 source update is already applied. Continuing installation.")
        return
    cache = contained(target, ".build")
    cache.mkdir(exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="update-0.6.1-backup-", dir=cache))
    stage = Path(tempfile.mkdtemp(prefix="update-0.6.1-stage-", dir=cache))
    replaced = []
    made_directories = []
    try:
        for relative, dst, data, mode, existed in pending:
            if existed:
                saved = backup / relative
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, saved)
            prepared = stage / relative
            prepared.parent.mkdir(parents=True, exist_ok=True)
            prepared.write_bytes(data)
            prepared.chmod(mode)
        try:
            for relative, dst, _, _, existed in pending:
                missing = []
                parent = dst.parent
                while not parent.exists():
                    missing.append(parent)
                    parent = parent.parent
                for directory in reversed(missing):
                    directory.mkdir()
                    made_directories.append(directory)
                os.replace(stage / relative, dst)
                replaced.append((relative, dst, existed))
        except Exception:
            for relative, dst, existed in reversed(replaced):
                if existed:
                    restored = stage / relative
                    restored.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(backup / relative, restored)
                    os.replace(restored, dst)
                else:
                    dst.unlink()
            for directory in reversed(made_directories):
                try:
                    directory.rmdir()
                except OSError:
                    pass
            raise
    finally:
        shutil.rmtree(stage)
    print("Applied Voice 0.6.1 source update; existing build cache retained.")
    print("Previous source files are backed up at " + str(backup))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    try:
        # Reject a symlink before resolving; CMake's original source path matters.
        target = args.target.expanduser().absolute()
        apply(Path(__file__).resolve().parent.parent, target)
    except Exception as error:
        print("Update stopped: " + str(error), file=sys.stderr)
        print("Your installed app and models are unchanged. Run setup.sh from the new Voice-0.6.1 folder to build separately.", file=sys.stderr)
        sys.exit(1)
