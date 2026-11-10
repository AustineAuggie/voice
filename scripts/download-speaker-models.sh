#!/bin/bash
set -euo pipefail
umask 077
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${LOCALVOICE_BUILD_CACHE:-$PROJECT_ROOT/.build}"
MODEL_ROOT="${LOCALVOICE_SPEAKER_MODEL_DIR:-$HOME/Library/Application Support/LocalVoice/Models/Speakers}"
mkdir -p "$BUILD_ROOT" "$MODEL_ROOT"
verified() { [[ -f "$1" ]] && echo "$2  $1" | shasum -a 256 -c - >/dev/null 2>&1; }
fetch() {
  local target="$1" hash="$2" url="$3"
  if verified "$target" "$hash"; then return; fi
  curl --fail --location --retry 3 --connect-timeout 30 --proto '=https' --proto-redir '=https' "$url" -o "$target.download"
  echo "$hash  $target.download" | shasum -a 256 -c -
  mv "$target.download" "$target"; chmod 600 "$target"
}
SEGMENT_HASH=220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079
EMBED_HASH=5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94
if verified "$MODEL_ROOT/segmentation.onnx" "$SEGMENT_HASH"; then
  echo 'Reusing verified local speaker segmentation model.'
else
  echo 'Downloading local speaker segmentation model (about 7 MB)...'
  ARCHIVE="$BUILD_ROOT/speaker-segmentation-3.0.tar.bz2"
  fetch "$ARCHIVE" 24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488 \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
  tar -xOf "$ARCHIVE" sherpa-onnx-pyannote-segmentation-3-0/model.onnx > "$MODEL_ROOT/segmentation.onnx.download"
  echo "$SEGMENT_HASH  $MODEL_ROOT/segmentation.onnx.download" | shasum -a 256 -c -
  mv "$MODEL_ROOT/segmentation.onnx.download" "$MODEL_ROOT/segmentation.onnx"; chmod 600 "$MODEL_ROOT/segmentation.onnx"
fi
if verified "$MODEL_ROOT/embedding.onnx" "$EMBED_HASH"; then
  echo 'Reusing verified local speaker voice model.'
else
  echo 'Downloading local speaker voice model (about 27 MB)...'
  fetch "$MODEL_ROOT/embedding.onnx" "$EMBED_HASH" \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx
fi
echo 'Local speaker models ready. Meeting audio is processed on this computer.'
