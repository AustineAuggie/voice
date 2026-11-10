#!/usr/bin/env python3
"""Actual native Whisper checks: ENGINE MODEL upstream/samples/jfk.wav.

The tiny multilingual model is sufficient for a compiler/protocol regression.
It is not an accuracy benchmark for the installed Large-v3 Turbo model.
"""
import argparse
import json
import math
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("model", type=Path)
    parser.add_argument("wav", type=Path)
    args = parser.parse_args()
    checks = 0

    def check(value, message):
        nonlocal checks
        checks += 1
        if not value:
            raise AssertionError(message)

    with tempfile.TemporaryDirectory(prefix="localvoice-timing-") as directory:
        root = Path(directory)
        with wave.open(str(args.wav)) as wav:
            assert wav.getframerate() == 16000 and wav.getsampwidth() == 2 and wav.getnchannels() == 1
            samples = struct.unpack("<" + "h" * wav.getnframes(), wav.readframes(wav.getnframes()))
        duration = len(samples) / 16000
        audio = root / "speech.f32"
        audio.write_bytes(struct.pack("<" + "f" * len(samples), *(n / 32768 for n in samples)))
        silence = root / "silence.f32"
        silence.write_bytes(bytes(64000))
        invalid = root / "invalid.f32"
        invalid.write_bytes(struct.pack("<f", float("nan")))
        process = subprocess.Popen([str(args.engine.resolve()), str(args.model.resolve())],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)

        def receive(timeout=120):
            check(bool(select.select([process.stdout], [], [], timeout)[0]), "Native worker timed out")
            return json.loads(process.stdout.readline())

        def request(identifier, path=audio, **options):
            payload = {"id": identifier, "audio": str(path), "language": "en", "prompt": ""}
            payload.update(options)
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            reply = receive()
            check(reply.get("id") == identifier, "Worker response ID must match")
            return reply

        try:
            check(receive().get("ready") is True, "Worker must become ready")
            original = request("ordinary-before")["text"]
            check("country" in original.lower(), "Ordinary dictation must transcribe the fixture")
            for language, accuracy in [("en", False), ("en", True), ("auto", True)]:
                reply = request(f"timed-{language}-{accuracy}", timed=True, language=language, accuracy=accuracy)
                result = json.loads(reply["text"])
                check(result.get("version") == 1, "Timed payload is versioned")
                check("country" in result["text"].lower(), "Timed transcript retains recognised speech")
                words = result["words"]
                check(len(words) > 10, "Real word timestamps must be available on the fixture")
                check("".join(word["text"] for word in words) == result["text"], "Timing pieces preserve every transcript character")
                previous = 0
                for word in words:
                    check(isinstance(word["text"], str) and bool(word["text"]), "Each timing piece contains text")
                    start, end = word["start"], word["end"]
                    check(math.isfinite(start) and math.isfinite(end), "Word timing is finite")
                    check(previous <= start < end <= duration, "Word timing is ordered and bounded by input audio")
                    previous = end
                print(f"Timed {language}, accuracy={accuracy}: {len(words)} words in {duration:.2f}s audio")
            check(request("ordinary-after")["text"] == original, "Timed meetings do not change later ordinary dictation")
            check(request("explicit-off", timed=False)["text"] == original, "Explicit timed=false preserves ordinary output")
            quiet = json.loads(request("timed-silence", path=silence, timed=True)["text"])
            check(quiet == {"version": 1, "text": "", "words": []}, "Silence uses the same timed JSON shape")
            check(request("plain-silence", path=silence)["text"] == "", "Ordinary silence remains empty")
            check("error" in request("missing", path=root / "missing.f32", timed=True), "Missing audio returns an error")
            check("error" in request("invalid", path=invalid, timed=True), "Invalid sample returns an error")
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        check(process.returncode == 0, "Worker exits cleanly")
        print(f"Passed {checks} native timed-transcription checks.")


if __name__ == "__main__":
    main()
