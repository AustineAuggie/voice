#!/bin/bash
set -euo pipefail
umask 077
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${LOCALVOICE_BUILD_CACHE:-$PROJECT_ROOT/.build}"
RESOURCES="${1:?Pass the app Contents/Resources directory}"
mkdir -p "$BUILD_ROOT" "$RESOURCES/diarizer-libs"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    PLATFORM=osx-arm64; SUFFIX=dylib
    ARCHIVE_HASH=ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3
    SHERPA_HASH=2a169fe29c7e75168cc308b0d5b7f9085efebbb3a7f812d46c3a983d6788759f
    ONNX_HASH=3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b
    ;;
  Linux-x86_64)
    # Portable compiler and real model checks; shipping app is macOS only.
    PLATFORM=linux-x64; SUFFIX=so
    ARCHIVE_HASH=ce437357915491e6f2754b52bec7dcf62ff6fc6aaed9cdcd66f17807bbaef374
    SHERPA_HASH=e8ea0e45a1677c489d22eecb3a9420dbd7cee1b00e611ef623d0a558abb29226
    ONNX_HASH=4b3607aebd1784b26b6f9b20e4bd974c7ab8287043e4d095cb7d2cb40b5e566e
    ;;
  *) echo 'Speaker analysis supports Apple silicon macOS; Linux x86_64 is available for tests.'; exit 1 ;;
esac
SDK_NAME="sherpa-onnx-v2.0.1-$PLATFORM-shared-no-tts-lib"
ARCHIVE="$BUILD_ROOT/$SDK_NAME.tar.bz2"
SDK="$BUILD_ROOT/$SDK_NAME"
verify() { [[ -f "$1" ]] && echo "$2  $1" | shasum -a 256 -c - >/dev/null 2>&1; }
if ! verify "$SDK/lib/libsherpa-onnx-c-api.$SUFFIX" "$SHERPA_HASH" || ! verify "$SDK/lib/libonnxruntime.$SUFFIX" "$ONNX_HASH"; then
  if ! verify "$ARCHIVE" "$ARCHIVE_HASH"; then
    echo 'Downloading the verified local speaker engine (about 9 MB)...'
    curl --fail --location --retry 3 --connect-timeout 30 --proto '=https' --proto-redir '=https' \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$SDK_NAME.tar.bz2" -o "$ARCHIVE.download"
    echo "$ARCHIVE_HASH  $ARCHIVE.download" | shasum -a 256 -c -
    mv "$ARCHIVE.download" "$ARCHIVE"
  fi
  tar -xjf "$ARCHIVE" -C "$BUILD_ROOT" "$SDK_NAME/lib/libsherpa-onnx-c-api.$SUFFIX" "$SDK_NAME/lib/libonnxruntime.$SUFFIX"
fi
verify "$SDK/lib/libsherpa-onnx-c-api.$SUFFIX" "$SHERPA_HASH" || { echo 'Speaker engine verification failed.'; exit 1; }
verify "$SDK/lib/libonnxruntime.$SUFFIX" "$ONNX_HASH" || { echo 'Speaker runtime verification failed.'; exit 1; }
cp "$SDK/lib/libsherpa-onnx-c-api.$SUFFIX" "$SDK/lib/libonnxruntime.$SUFFIX" "$RESOURCES/diarizer-libs/"
if [[ "$PLATFORM" == osx-arm64 ]]; then
  xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=13.0 \
    "$PROJECT_ROOT/Native/diarize.cpp" -L"$SDK/lib" -lsherpa-onnx-c-api -o "$RESOURCES/localvoice-diarizer"
  install_name_tool -change @rpath/libsherpa-onnx-c-api.dylib @loader_path/diarizer-libs/libsherpa-onnx-c-api.dylib "$RESOURCES/localvoice-diarizer"
  install_name_tool -change @rpath/libonnxruntime.dylib @loader_path/libonnxruntime.dylib "$RESOURCES/diarizer-libs/libsherpa-onnx-c-api.dylib"
  install_name_tool -id @loader_path/libsherpa-onnx-c-api.dylib "$RESOURCES/diarizer-libs/libsherpa-onnx-c-api.dylib"
  install_name_tool -id @loader_path/libonnxruntime.dylib "$RESOURCES/diarizer-libs/libonnxruntime.dylib"
  for binary in "$RESOURCES/diarizer-libs/libonnxruntime.dylib" "$RESOURCES/diarizer-libs/libsherpa-onnx-c-api.dylib" "$RESOURCES/localvoice-diarizer"; do
    chmod 755 "$binary"
    if otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/|/usr/local/|@rpath/)' >/dev/null; then
      echo "Unexpected speaker engine dependency in $binary"; otool -L "$binary"; exit 1
    fi
    codesign --force --sign - "$binary"
    codesign --verify --strict "$binary"
  done
else
  "${CXX:-c++}" -std=c++17 -O2 "$PROJECT_ROOT/Native/diarize.cpp" -L"$SDK/lib" -lsherpa-onnx-c-api \
    '-Wl,-rpath,$ORIGIN/diarizer-libs' -o "$RESOURCES/localvoice-diarizer"
fi
for name in sherpa-onnx onnxruntime WeSpeaker Pyannote-segmentation; do
  cp "$PROJECT_ROOT/Resources/$name-LICENSE.txt" "$RESOURCES/"
done
cp "$PROJECT_ROOT/Resources/onnxruntime-ThirdPartyNotices.txt" "$PROJECT_ROOT/Resources/Speaker-models-NOTICE.txt" "$RESOURCES/"
echo 'Local speaker engine built.'
