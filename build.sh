#!/bin/bash
set -euo pipefail
umask 077
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${LOCALVOICE_BUILD_CACHE:-$PROJECT_ROOT/.build}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then echo 'Build on an Apple silicon Mac in a native Terminal.'; exit 1; fi
SDK_VERSION="$(xcrun --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ "$SDK_MAJOR" -lt 15 ]]; then
  echo 'Update Apple Command Line Tools (macOS SDK 15 or newer) before building this meeting-notes update.'
  exit 1
fi
command -v cmake >/dev/null || { echo 'Run setup.sh first; it installs CMake automatically.'; exit 1; }
mkdir -p "$BUILD_ROOT" "$PROJECT_ROOT/dist.noindex"
fetch_engine() {
  local directory="$1" repo="$2" tag="$3" commit="$4"
  if [[ ! -d "$directory/.git" ]]; then git clone --depth 1 --branch "$tag" "$repo" "$directory"; fi
  if [[ "$(git -C "$directory" rev-parse HEAD)" != "$commit" || -n "$(git -C "$directory" status --porcelain --untracked-files=no)" ]]; then
    echo "Engine source is not the expected clean version: $directory"; exit 1
  fi
}
SPEECH_SOURCE="$BUILD_ROOT/whisper.cpp"
EDITOR_SOURCE="$BUILD_ROOT/llama.cpp-b5046"
fetch_engine "$SPEECH_SOURCE" https://github.com/ggml-org/whisper.cpp.git v1.7.6 a8d002cfd879315632a579e73f0148d06959de36
fetch_engine "$EDITOR_SOURCE" https://github.com/ggml-org/llama.cpp.git b5046 74d4f5b041ad837153b0e90fc864b8290e01d8d5
bash "$PROJECT_ROOT/scripts/test.sh"
# Compile the Mac interface before expensive native-engine builds.
STAGING="$(mktemp -d "$BUILD_ROOT/app-v3.XXXXXX")"; trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Voice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --show-sdk-path)" "$PROJECT_ROOT"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices \
  -framework CryptoKit -framework Combine -framework CoreAudio -framework ScreenCaptureKit -framework CoreMedia -o "$APP/Contents/MacOS/LocalVoice"
COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DGGML_METAL=ON -DGGML_OPENMP=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DJSON_INCLUDE="$SPEECH_SOURCE/examples")
JOBS="$(sysctl -n hw.ncpu)"; if [[ "$JOBS" -gt 8 ]]; then JOBS=8; fi
# CMake records the absolute source directory. Give each extracted source path
# its own small build directory while reusing the downloaded engine sources.
SOURCE_KEY="$(printf '%s' "$PROJECT_ROOT" | shasum -a 256 | cut -c1-12)"
SPEECH_BUILD="$BUILD_ROOT/localvoice-speech-v3-$SOURCE_KEY"
EDITOR_BUILD="$BUILD_ROOT/localvoice-editor-v3-$SOURCE_KEY"
cmake -S "$PROJECT_ROOT/Native" -B "$SPEECH_BUILD" -DVOICE_ENGINE=speech -DENGINE_SOURCE="$SPEECH_SOURCE" "${COMMON[@]}"
cmake --build "$SPEECH_BUILD" --target localvoice-speech -j "$JOBS"
cmake -S "$PROJECT_ROOT/Native" -B "$EDITOR_BUILD" -DVOICE_ENGINE=editor -DENGINE_SOURCE="$EDITOR_SOURCE" "${COMMON[@]}"
cmake --build "$EDITOR_BUILD" --target localvoice-editor -j "$JOBS"
bash "$PROJECT_ROOT/scripts/build-diarizer.sh" "$APP/Contents/Resources"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SPEECH_BUILD/localvoice-speech" "$APP/Contents/Resources/"
cp "$EDITOR_BUILD/localvoice-editor" "$APP/Contents/Resources/"
cp "$SPEECH_SOURCE/LICENSE" "$APP/Contents/Resources/whisper.cpp-LICENSE"
cp "$EDITOR_SOURCE/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE"
cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES.txt" "$PROJECT_ROOT/Resources/Qwen-LICENSE.txt" "$PROJECT_ROOT/Resources/nlohmann-LICENSE.txt" "$PROJECT_ROOT/Resources/Whisper-model-LICENSE.txt" "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/"
sed -n '1,35p' "$SPEECH_SOURCE/examples/json.hpp" > "$APP/Contents/Resources/nlohmann-json-NOTICE.txt"
xcrun swift "$PROJECT_ROOT/scripts/MakeIcon.swift" "$STAGING/AppIcon.iconset"
iconutil -c icns "$STAGING/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
for binary in "$APP/Contents/MacOS/LocalVoice" "$APP/Contents/Resources/localvoice-speech" "$APP/Contents/Resources/localvoice-editor" "$APP/Contents/Resources/localvoice-diarizer"; do
  if otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/|/usr/local/|@rpath/)' >/dev/null; then
    echo "External dependency found in $binary"; otool -L "$binary"; exit 1
  fi
  codesign --force --sign - "$binary"
done
codesign --force --sign - "$APP"; codesign --verify --deep --strict "$APP"
OUTPUT="$PROJECT_ROOT/dist.noindex/Voice.app"
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$PROJECT_ROOT/dist.noindex/Voice-previous-$(date +%Y%m%d-%H%M%S).app"; fi
mv "$APP" "$OUTPUT"
echo "Mac build complete: $OUTPUT"
