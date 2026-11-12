"""Extract only the four required files from the pinned Windows speaker SDK.

Build-time helper. Python is never required by the installed application.
"""
import argparse
import hashlib
import shutil
import tarfile
from pathlib import Path

ARCHIVE_SHA256 = "21da6a8b92d63ca02ad41dbfc120012343aaaec2e5e02b14819c6b4f38004509"
SDK_NAME = "sherpa-onnx-v2.0.1-win-x64-shared-MT-Release-no-tts-lib"
FILES = ("sherpa-onnx-c-api.dll", "sherpa-onnx-c-api.lib", "onnxruntime.dll", "onnxruntime_providers_shared.dll")

def extract(archive: Path, directory: Path) -> None:
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Speaker SDK archive failed SHA-256 verification")
    output = directory / SDK_NAME / "lib"
    output.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:bz2") as bundle:
        for name in FILES:
            member = bundle.getmember(f"{SDK_NAME}/lib/{name}")
            if not member.isfile() or not 0 < member.size < 64 * 1024 * 1024:
                raise ValueError("Unexpected speaker SDK member")
            target = output / name
            temporary = target.with_suffix(target.suffix + ".extracting")
            try:
                # Archive paths are never used as output paths. Only the four
                # known filenames above are written into the chosen build cache.
                with bundle.extractfile(member) as source, temporary.open("wb") as destination:
                    shutil.copyfileobj(source, destination, length=1024 * 1024)
                if temporary.stat().st_size != member.size:
                    raise ValueError("Incomplete speaker SDK member")
                temporary.replace(target)
                print(f"Extracted {name}: {member.size} bytes", flush=True)
            finally:
                temporary.unlink(missing_ok=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("directory", type=Path)
    arguments = parser.parse_args()
    extract(arguments.archive, arguments.directory)
