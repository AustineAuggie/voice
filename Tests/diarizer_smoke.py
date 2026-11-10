#!/usr/bin/env python3
"""Exercise the real native speaker worker; optional WAV fixtures must be mono 16 kHz PCM16.

python3 Tests/diarizer_smoke.py ENGINE SEGMENTATION.onnx EMBEDDING.onnx [FIXTURE.wav ...]
Fixtures are not bundled. The observed release-test results identify upstream URLs/hashes.
This tests CPU inference and cancellation, not macOS hardware capture or overall word accuracy.
"""
import argparse
import array
import json
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('engine', type=Path)
parser.add_argument('segmentation', type=Path)
parser.add_argument('embedding', type=Path)
parser.add_argument('fixtures', type=Path, nargs='*')
args = parser.parse_args()
checks = 0

def check(condition, message):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='localvoice-diarizer-check-') as temporary:
    root = Path(temporary)
    audio, output = root/'audio.f32', root/'result.json'
    base = [str(args.engine.resolve()), '--audio', str(audio), '--output', str(output),
            '--segmentation', str(args.segmentation.resolve()), '--embedding', str(args.embedding.resolve())]
    def invoke(data, extra=(), successful=True, marker=None):
        audio.write_bytes(data)
        output.unlink(missing_ok=True)
        run = subprocess.run(base + list(extra), capture_output=True, text=True, timeout=180)
        check((run.returncode == 0) == successful, 'Unexpected exit: '+run.stderr[-1500:])
        check(audio.read_bytes() == data, 'The original audio must never change')
        if marker: check('speaker-error '+marker+'\n' in run.stderr, 'Missing diagnostic marker')
        if successful:
            check(output.stat().st_mode & 0o777 == 0o600, 'Result must be private')
            return json.loads(output.read_text())
        check(not output.exists(), 'A failed request must not publish results')
    check(invoke(b'')['num_speakers'] == 0, 'Empty capture has no speakers')
    check(invoke(bytes(16000*4))['segments'] == [], 'Silence has no speakers')
    invoke(b'bad', successful=False, marker='invalid-audio')
    for value in [float('nan'), float('inf'), -float('inf')]:
        invoke(struct.pack('<f', value), successful=False, marker='invalid-audio')
    invoke(bytes(4), extra=['--speakers','0'], successful=False, marker='invalid-options')
    invoke(bytes(4), extra=['--threads','words'], successful=False, marker='invalid-options')
    invoke(bytes(4), extra=['--threads','99999999999999999999'], successful=False, marker='invalid-options')
    # Use a non-silent recording to ensure missing models are detected.
    nonzero = struct.pack('<f',0.1)*16000
    audio.write_bytes(nonzero)
    output.unlink(missing_ok=True)
    broken = base.copy(); broken[broken.index('--embedding')+1] = str(root/'missing-model.onnx')
    run = subprocess.run(broken, capture_output=True, timeout=30)
    check(run.returncode != 0 and not output.exists(), 'Missing model must fail without a result')
    check(b'speaker-error missing-models\n' in run.stderr, 'Missing model needs an actionable marker')
    print('Input validation and private result checks passed.')
    last = None
    overscale_checked = False
    for fixture in args.fixtures:
        with wave.open(str(fixture), 'rb') as reader:
            check(reader.getframerate() == 16000 and reader.getnchannels() == 1 and reader.getsampwidth() == 2,
                  'Fixture must be mono 16 kHz PCM16')
            values = array.array('h', reader.readframes(reader.getnframes()))
        if sys.byteorder != 'little': values.byteswap()
        pcm = array.array('f', (x/32768.0 for x in values))
        if sys.byteorder != 'little': pcm.byteswap()
        last = pcm.tobytes()
        begin = time.monotonic(); result = invoke(last)
        labels = set()
        previous_start = 0
        for segment in result['segments']:
            check(0 <= segment['start'] < segment['end'] <= len(values)/16000, 'Invalid audio bounds')
            check(segment['start'] >= previous_start, 'Segments must be time sorted')
            previous_start = segment['start']
            labels.add(segment['speaker'])
            score = segment.get('confidence')
            check(score is None or -1 <= score <= 1, 'Invalid clustering confidence')
        check(labels == set(range(result['num_speakers'])), 'Speaker labels must be contiguous')
        print(f'{fixture.name}: {result["num_speakers"]} estimated speakers, {len(result["segments"])} turns, {time.monotonic()-begin:.2f}s CPU.')
        if not overscale_checked:
            # Regression: finite floating capture may exceed 1.0 after mixing or
            # resampling. It must be analysed, with only the private copy attenuated.
            def pack_floats(items):
                samples = array.array('f', items)
                if sys.byteorder != 'little': samples.byteswap()
                return samples.tobytes()
            boosted = array.array('f', (x/32768.0*4 for x in values))
            peak = max(abs(x) for x in boosted)
            check(peak > 1.001, 'Fixture must reproduce the former full-scale rejection')
            normalized = invoke(pack_floats(x/peak for x in boosted))
            attenuated = invoke(pack_floats(boosted))
            check(attenuated == normalized, 'Over-range audio must match its safely normalized reference')
            check(attenuated['num_speakers'] > 0, 'Boosted speech must still produce speakers')
            print(f'{fixture.name}: over-range peak {peak:.3f} succeeds and matches normalized reference.')
            overscale_checked = True
    if last:
        # Real inference should still be in progress when cancelled, and must
        # not publish a result that could be attached to another meeting.
        audio.write_bytes(last*8); output.unlink(missing_ok=True)
        process = subprocess.Popen(base, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.1)
            check(process.poll() is None, 'Cancellation fixture ended unexpectedly early')
            process.terminate(); process.wait(timeout=10)
            check(process.returncode != 0 and not output.exists(), 'Cancelled inference published a result')
        finally:
            if process.poll() is None: process.kill(); process.wait()
    print(f'Passed {checks} native speaker-worker checks.')
