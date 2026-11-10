#!/usr/bin/env python3
"""Compile and run the actual MeetingCapture.stop body using Foundation fakes.

Usage: python3 Tests/capture_stop_smoke.py [Sources/MeetingCapture.swift]
Set SWIFTC for a non-default compiler. On macOS the default is xcrun swiftc.
This detects closure typing regressions; it is not a macOS SDK build or audio test.
"""
import argparse
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile


def stop_method(source):
    signature = "func stop(completion: @escaping (Result<Void, Error>) -> Void)"
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise ValueError("Unclosed production stop method")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path,
                        default=here.parent / "Sources/MeetingCapture.swift")
    args = parser.parse_args()
    harness = (here / "CaptureStopHarness.swift").read_text()
    generated = harness.replace("// PRODUCTION_STOP_METHOD", stop_method(args.source.read_text()))
    compiler = shlex.split(os.environ.get("SWIFTC", "xcrun swiftc" if platform.system() == "Darwin" else "swiftc"))
    with tempfile.TemporaryDirectory(prefix="localvoice-capture-stop-") as temp:
        swift = Path(temp) / "CaptureStopTests.swift"
        executable = Path(temp) / "capture-stop-tests"
        swift.write_text(generated)
        subprocess.run(compiler + ["-swift-version", "5", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=15)
