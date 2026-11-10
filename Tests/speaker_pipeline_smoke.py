#!/usr/bin/env python3
"""Run one real <24s fixture through speech, diarization and production alignment.

Requires built native workers, downloaded models, the Swift compiler and a mono
16kHz signed-16-bit WAV. No fixture or model is downloaded by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import shlex
import shutil
import struct
import subprocess
import tempfile
import time
import wave


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("speech", "speech_model", "diarizer", "segmentation", "embedding", "wav", "output"):
        p.add_argument(name, type=Path)
    p.add_argument("--debug-dir", type=Path, help="Keep native responses for diagnosing a failed integration check")
    args = p.parse_args()
    root = Path(__file__).resolve().parent.parent
    compiler = shlex.split(os.environ.get("SWIFTC", "xcrun swiftc" if platform.system() == "Darwin" else "swiftc"))
    with tempfile.TemporaryDirectory(prefix="speaker-pipeline-") as directory:
        folder = Path(directory)
        with wave.open(str(args.wav)) as wav:
            assert wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == 16000
            samples = struct.unpack("<" + "h" * wav.getnframes(), wav.readframes(wav.getnframes()))
        assert 0 < len(samples) <= 24 * 16000
        audio = folder / "input.f32"
        audio.write_bytes(struct.pack("<" + "f" * len(samples), *(n / 32768 for n in samples)))
        native = folder / "diarizer.json"
        started = time.monotonic()
        subprocess.run([str(args.diarizer.resolve()), "--audio", str(audio), "--output", str(native),
                        "--segmentation", str(args.segmentation.resolve()), "--embedding", str(args.embedding.resolve()),
                        "--threads", "2"], check=True, timeout=180)
        diarizer_seconds = time.monotonic() - started
        with (folder / "speech.log").open("w") as log:
            process = subprocess.Popen([str(args.speech.resolve()), str(args.speech_model.resolve())],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            try:
                assert select.select([process.stdout], [], [], 180)[0], "Speech model load timed out"
                assert json.loads(process.stdout.readline()).get("ready") is True
                started = time.monotonic()
                request = {"id": "speaker-pipeline", "audio": str(audio), "language": "en", "accuracy": True, "timed": True}
                process.stdin.write(json.dumps(request) + "\n"); process.stdin.flush()
                assert select.select([process.stdout], [], [], 900)[0], "Timed transcription timed out"
                reply = json.loads(process.stdout.readline())
                assert reply.get("id") == "speaker-pipeline" and "error" not in reply, reply
                timed = folder / "timed.json"; timed.write_text(reply["text"])
                speech_seconds = time.monotonic() - started
            finally:
                process.stdin.close()
                try: process.wait(timeout=20)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        executable = folder / "speaker-pipeline"
        if args.debug_dir:
            args.debug_dir.mkdir(parents=True, exist_ok=True)
            for file in (audio, timed, native): shutil.copy2(file, args.debug_dir / file.name)
        parsed = json.loads(timed.read_text())
        print(json.dumps({"timed_word_count": len(parsed.get("words", [])), "timed_text": parsed.get("text"),
                          "diarizer_speakers": json.loads(native.read_text()).get("num_speakers")}), flush=True)
        subprocess.run(compiler + ["-swift-version", "5", "-parse-as-library"] +
                       [str(root / "Sources" / x) for x in ("Domain.swift", "MeetingDomain.swift", "SpeakerDomain.swift", "MeetingSpeakers.swift")] +
                       [str(root / "Tests/SpeakerPipelineSmoke.swift"), "-o", str(executable)], check=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(executable), str(audio), str(timed), str(native), str(args.output.resolve())], check=True)
        evidence = json.loads(args.output.read_text())
        evidence.update({"fixture": args.wav.name, "fixture_sha256": hashlib.sha256(args.wav.read_bytes()).hexdigest(),
                         "speech_model": args.speech_model.name, "diarizer_seconds": round(diarizer_seconds, 3),
                         "speech_seconds": round(speech_seconds, 3),
                         "invalid_timing_word_count": sum(w.get("timingValid") is False for w in parsed["words"]),
                         "unassigned_turn_count": sum(t.get("speaker") is None for t in evidence["turns"]),
                         "note": "Pipeline integration check only. Speaker count agreement is not a diarization error-rate benchmark."})
        args.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
