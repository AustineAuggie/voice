#!/usr/bin/env python3
"""Generate the Voice 0.6.1 update checksums after finalising release files."""
import argparse
import hashlib
import json
from pathlib import Path


EXCLUDED = {
    "install.sh", "scripts/apply-update.py", "scripts/make-update-manifest.py",
    "scripts/update-manifest.json", "Tests/UpdateTests.py",
    "repair.sh", "scripts/apply-repair.py", "scripts/repair-manifest.json",
    "Tests/RepairTests.py",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def generate(source, baseline, previous, latest):
    old_manifest = json.loads((baseline / "scripts/repair-manifest.json").read_text())
    historical = {relative: [value] for relative, value in old_manifest["unchanged"].items()}
    for relative, checksums in old_manifest["files"].items():
        before = checksums["before"]
        historical[relative] = (before if isinstance(before, list) else [before]) + [checksums["after"]]
    original_names = set(historical)
    for release, version in ((previous, "0.5.0"), (latest, "0.6.0")):
        previous_manifest = json.loads((release / "scripts/update-manifest.json").read_text())
        if previous_manifest.get("version") != version:
            raise ValueError("The previous release must be the unchanged " + version + " package")
        for relative, entry in previous_manifest["files"].items():
            previous_path = release / relative
            if not previous_path.is_file() or digest(previous_path.read_bytes()) != entry["after"]:
                raise ValueError("Previous release payload differs from its manifest: " + relative)
            historical.setdefault(relative, []).extend(entry["accepted"] + [entry["after"]])
    files = {}
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part in (".build", "__pycache__", "dist", "dist.noindex", ".git") for part in relative.parts):
            continue
        name = relative.as_posix()
        if name in EXCLUDED or not path.is_file():
            continue
        if path.is_symlink():
            raise ValueError("Release payload cannot contain symlinks: " + name)
        expected = digest(path.read_bytes())
        accepted = historical.get(name, []).copy()
        prior = baseline / name
        if prior.is_file():
            accepted.append(digest(prior.read_bytes()))
        for release in (previous, latest):
            prior = release / name
            if prior.is_file():
                accepted.append(digest(prior.read_bytes()))
        accepted.append(expected)
        files[name] = {
            "accepted": sorted(set(accepted)),
            "after": expected,
            # Prior in-place repairs only copied paths from original 0.4.0.
            # Later-added test/tools files can be absent in that repaired folder.
            "allow_missing": name not in original_names,
            "mode": "0755" if path.suffix in (".sh", ".py") else "0644",
        }
    required = ["setup.sh", "build.sh", "Sources/MeetingState.swift", "Sources/MeetingCapture.swift"]
    if not all(name in files for name in required):
        raise ValueError("Release is missing required build inputs")
    return {"version": "0.6.1", "bases": ["0.4.0", "0.4.1", "0.4.2", "0.5.0", "0.6.0"], "source_roots": ["Sources", "Native"], "files": files}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="Extracted original LocalVoice-0.4.2 folder")
    parser.add_argument("previous", type=Path, help="Unchanged LocalVoice-0.5.0 folder")
    parser.add_argument("latest", type=Path, help="Unchanged Voice-0.6.0 folder")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    manifest = generate(source, args.baseline.resolve(), args.previous.resolve(), args.latest.resolve())
    destination = source / "scripts/update-manifest.json"
    destination.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print("Wrote " + str(destination) + ": " + str(len(manifest["files"])) + " checked payload files")
