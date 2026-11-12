#!/usr/bin/env python3
"""Exercise shipped Windows workers, including real tiny.en CPU inference.

Uses only standard Python. Downloads hash-pinned test assets into the build
cache; those assets are never included in the user's installation package.
"""
from __future__ import annotations
import argparse
import array
import hashlib
import json
import math
import os
import queue
import re
import struct
import subprocess
import shutil
import sys
import tempfile
import threading
import time
import urllib.request
import wave
from pathlib import Path

TINY_HASH = '921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f'
JFK_HASH = '59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e'

def download(url: str, path: Path, expected: str) -> Path:
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        return path
    temporary = path.with_suffix(path.suffix + '.download')
    with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as output:
        while block := response.read(1024 * 1024):
            output.write(block)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Test asset verification failed: {path.name}')
    temporary.replace(path)
    return path

def no_model_checks(engines: Path, directory: Path) -> None:
    for name in ('speech', 'editor'):
        p = subprocess.run([str(engines / f'localvoice-{name}.exe'), str(directory / 'missing-model')],
                           capture_output=True, text=True, encoding='utf-8', timeout=45)
        assert p.returncode == 1, (name, p.returncode, p.stderr[-1000:])
        assert json.loads(p.stdout.strip())['error'], (name, p.stdout)
    worker = str(engines / 'localvoice-diarizer.exe')
    audio = directory / '声音-Élodie.f32'
    output = directory / 'résultat-声音.json'
    args = [worker, '--audio', str(audio), '--output', str(output), '--segmentation', 'missing', '--embedding', 'missing']
    for content in (b'', bytes(16000 * 4)):
        audio.write_bytes(content)
        p = subprocess.run(args, capture_output=True, timeout=30)
        assert p.returncode == 0, p.stderr
        result = json.loads(output.read_text(encoding='utf-8'))
        assert result == {'sample_rate': 16000, 'num_speakers': 0, 'segments': []}, result
        assert audio.read_bytes() == content, 'Diarizer modified the input audio'
    for content in (b'bad', struct.pack('<f', float('nan')), struct.pack('<f', float('inf'))):
        audio.write_bytes(content)
        before = output.read_bytes()
        p = subprocess.run(args, capture_output=True, timeout=30)
        assert p.returncode == 1 and b'speaker-error invalid-audio' in p.stderr, p.stderr
        assert output.read_bytes() == before, 'A failed operation replaced the previous result'
    audio.write_bytes(struct.pack('<f', 2.0) * 1600)
    p = subprocess.run(args, capture_output=True, timeout=30)
    assert p.returncode == 1 and b'speaker-error missing-models' in p.stderr, p.stderr
    assert b'speaker-audio-normalized' in p.stderr
    assert audio.read_bytes() == struct.pack('<f', 2.0) * 1600, 'COW normalisation modified recorded audio'
    print('Native loading, Unicode paths, silence, invalid samples, atomic result and COW checks passed.', flush=True)

class Worker:
    def __init__(self, executable: Path, model: Path):
        self.process = subprocess.Popen([str(executable), str(model)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding='utf-8', bufsize=1)
        self.replies: queue.Queue = queue.Queue()
        def read():
            try:
                for line in self.process.stdout:
                    self.replies.put(json.loads(line))
            except BaseException as error:
                self.replies.put(error)
            finally:
                self.replies.put(EOFError('Worker stopped before replying'))
        threading.Thread(target=read, daemon=True).start()
    def reply(self, timeout=180):
        value = self.replies.get(timeout=timeout)
        if isinstance(value, BaseException):
            raise value
        return value
    def send(self, value):
        self.process.stdin.write(json.dumps(value, ensure_ascii=False) + '\n')
        self.process.stdin.flush()
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)

def speaker_checks(engines: Path, directory: Path, cache: Path, audio: Path) -> None:
    original_model = download('https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx',
        cache / 'segmentation.onnx', '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079')
    segmentation = directory / 'segmentation-声音.onnx'
    shutil.copyfile(original_model, segmentation)
    assert hashlib.sha256(segmentation.read_bytes()).hexdigest() == '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079'
    embedding = download('https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx',
        cache / 'embedding.onnx', '5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94')
    output = directory / 'speaker-inference.json'
    original = audio.read_bytes()
    p = subprocess.run([str(engines / 'localvoice-diarizer.exe'), '--audio', str(audio),
        '--output', str(output), '--segmentation', str(segmentation), '--embedding', str(embedding), '--threads', '2'],
        capture_output=True, timeout=180)
    assert p.returncode == 0, (p.returncode, p.stderr[-2000:])
    result = json.loads(output.read_text(encoding='utf-8'))
    assert result['sample_rate'] == 16000 and result['num_speakers'] > 0 and result['segments'], result
    duration = len(original) / 64000
    assert all(0 <= segment['start'] < segment['end'] <= duration and
        0 <= segment['speaker'] < result['num_speakers'] for segment in result['segments']), result
    assert audio.read_bytes() == original, 'Real speaker inference modified audio'
    print(f'Real Windows speaker inference passed ({result["num_speakers"]} estimated speakers). This is a loading/inference check, not an accuracy benchmark.', flush=True)

def speech_checks(engines: Path, directory: Path, cache: Path) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    model = download('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
                     cache / 'ggml-tiny.en.bin', TINY_HASH)
    wav = download('https://raw.githubusercontent.com/ggml-org/whisper.cpp/a8d002cfd879315632a579e73f0148d06959de36/samples/jfk.wav',
                   cache / 'jfk.wav', JFK_HASH)
    with wave.open(str(wav), 'rb') as reader:
        assert (reader.getframerate(), reader.getnchannels(), reader.getsampwidth()) == (16000, 1, 2)
        pcm = reader.readframes(reader.getnframes())
    floats = array.array('f', (sample[0] / 32768.0 for sample in struct.iter_unpack('<h', pcm)))
    if sys.byteorder != 'little':
        floats.byteswap()
    audio = directory / 'dictée-声音.f32'
    audio.write_bytes(floats.tobytes())
    unicode_model = directory / 'modèle-声音.bin'
    try:
        os.link(model, unicode_model)
    except OSError:
        shutil.copyfile(model, unicode_model)
    worker = Worker(engines / 'localvoice-speech.exe', unicode_model)
    try:
        assert worker.reply().get('ready') is True
        request = {'id': 'first', 'audio': str(audio), 'language': 'en', 'accuracy': False}
        worker.send(request)
        result = worker.reply()
        assert result.get('id') == 'first' and 'error' not in result, result
        assert 'country' in result['text'].lower() and 'ask' in result['text'].lower(), result
        worker.send(dict(request, id='timed', timed=True))
        result = worker.reply()
        assert result.get('id') == 'timed' and 'error' not in result, result
        payload = json.loads(result['text'])
        assert payload['version'] == 1 and payload['words'] and 'country' in payload['text'].lower(), payload
        assert all(math.isfinite(w['start']) and math.isfinite(w['end']) for w in payload['words'])
        # Native worker must return the cancelled request under its own ID and
        # remain usable for the following dictation, rather than staying busy.
        long_audio = directory / 'cancel.f32'
        long_audio.write_bytes(floats.tobytes() * 20)
        worker.send(dict(request, id='cancel-me', audio=str(long_audio)))
        worker.send({'cancel': 'cancel-me'})
        cancelled = worker.reply()
        assert cancelled.get('id') == 'cancel-me' and 'cancel' in cancelled.get('error', '').lower(), cancelled
        worker.send(dict(request, id='restart'))
        result = worker.reply()
        assert result.get('id') == 'restart' and 'country' in result.get('text', '').lower(), result
        print('Real Windows speech inference, timed words, cancellation and immediate restart passed.', flush=True)
    finally:
        worker.close()
    speaker_checks(engines, directory, cache, audio)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--engines', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=Path(__file__).resolve().parents[2] / '.build/windows-smoke')
    parser.add_argument('--no-inference', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='Voice-native-') as temporary:
        directory = Path(temporary)
        no_model_checks(args.engines.resolve(), directory)
        if not args.no_inference:
            speech_checks(args.engines.resolve(), directory, args.cache)

if __name__ == '__main__':
    main()
