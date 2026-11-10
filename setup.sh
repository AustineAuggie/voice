#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "Setup stopped at line $LINENO. Keep this output for troubleshooting. Any installed app is retained until final installation."' ERR
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then echo 'Run this on your Apple silicon Mac.'; exit 1; fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]]; then echo 'macOS 13 or newer is required.'; exit 1; fi
echo 'Voice 0.6.1 setup - speaker recovery and meeting detection fixes'
MISSING=0
for TOOL in swiftc clang git; do
  if ! xcrun --find "$TOOL" >/dev/null 2>&1; then echo "Missing Apple developer tool: $TOOL"; MISSING=1; fi
done
if [[ "$MISSING" == 1 ]]; then xcode-select --install || true; echo 'Complete the Apple installer, then rerun this command.'; exit 1; fi
SDK_VERSION="$(xcrun --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt 15 ]]; then
  echo 'Update Apple Command Line Tools through System Settings > Software Update (macOS SDK 15 or newer is needed), then rerun setup.'
  exit 1
fi
if [[ ! -f "$PROJECT_ROOT/Sources/AppState.swift" || ! -f "$PROJECT_ROOT/Native/editor.cpp" ]]; then echo 'Keep setup.sh inside the extracted Voice-0.6.1 folder.'; exit 1; fi
BUILD_CACHE="$PROJECT_ROOT/.build"
for PREVIOUS_CACHE in "$HOME/Downloads/LocalVoice-Upgrade/.build" "$HOME/Downloads/LocalVoice-Start-Here/.build"; do
  if [[ -d "$PREVIOUS_CACHE/whisper.cpp/.git" ]]; then BUILD_CACHE="$PREVIOUS_CACHE"; break; fi
done
mkdir -p "$BUILD_CACHE"; export LOCALVOICE_BUILD_CACHE="$BUILD_CACHE"
CMAKE_BIN="$BUILD_CACHE/cmake-4.1.3-macos-universal/CMake.app/Contents/bin"
export PATH="$CMAKE_BIN:/opt/homebrew/bin:/Applications/CMake.app/Contents/bin:$PATH"
if ! command -v cmake >/dev/null; then
  echo 'Downloading verified CMake into the project cache...'
  ARCHIVE="$BUILD_CACHE/cmake-4.1.3-macos-universal.tar.gz"
  curl --fail --location --retry 3 --connect-timeout 30 --proto '=https' --proto-redir '=https' \
    https://cmake.org/files/v4.1/cmake-4.1.3-macos-universal.tar.gz -o "$ARCHIVE"
  echo "c49928ef376f563214902d0a9b5de619febc7d3cef9a42b8ce8e208911d3e50b  $ARCHIVE" | shasum -a 256 -c -
  tar -xzf "$ARCHIVE" -C "$BUILD_CACHE"
fi
MODEL_DIR="$HOME/Library/Application Support/LocalVoice/Models"
mkdir -p "$MODEL_DIR"
NEEDED_KB=1600000
for SPEC in 'ggml-large-v3-turbo.bin:1624555275' 'qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf:3993201344' 'qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf:689872288'; do
  NAME="${SPEC%%:*}"; SIZE="${SPEC##*:}"
  if [[ ! -f "$MODEL_DIR/$NAME" ]] || [[ "$(stat -f%z "$MODEL_DIR/$NAME")" -ne "$SIZE" ]]; then NEEDED_KB=$((NEEDED_KB + SIZE / 1024 + 1)); fi
done
AVAILABLE_KB="$(df -Pk "$MODEL_DIR" | awk 'NR==2 {print $4}')"
if [[ "$AVAILABLE_KB" -lt "$NEEDED_KB" ]]; then echo "Allow about $((NEEDED_KB / 1024 / 1024 + 1)) GB of free space for missing models and the build."; exit 1; fi
download_model() {
  local name="$1" hash="$2" url="$3"
  if [[ -f "$MODEL_DIR/$name" ]] && echo "$hash  $MODEL_DIR/$name" | shasum -a 256 -c - >/dev/null 2>&1; then echo "Reusing verified $name"; return; fi
  echo "Downloading ${name}..."
  curl --http1.1 --fail --location --retry 3 --connect-timeout 30 --proto '=https' --proto-redir '=https' "$url?download=true" -o "$MODEL_DIR/$name.download"
  echo "$hash  $MODEL_DIR/$name.download" | shasum -a 256 -c -
  mv "$MODEL_DIR/$name.download" "$MODEL_DIR/$name"; chmod 600 "$MODEL_DIR/$name"
}
download_model ggml-large-v3-turbo.bin 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
download_model qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db \
  https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf
download_model qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf 539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a \
  https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf
bash "$PROJECT_ROOT/scripts/download-speaker-models.sh"
bash "$PROJECT_ROOT/build.sh"
if pgrep -x LocalVoice >/dev/null; then
  osascript -e 'tell application id "com.sunday.localvoice" to quit' || true
  for ((i=0;i<20;i++)); do if ! pgrep -x LocalVoice >/dev/null; then break; fi; sleep 0.25; done
  if pgrep -x LocalVoice >/dev/null; then echo 'Quit Voice (or the old LocalVoice app) from its menu, then rerun setup.'; exit 1; fi
fi
# Preserve the existing installation location. The binary and bundle identifier
# stay compatible with prior permission/settings records; the app is now Voice.
INSTALL_DIR="$HOME/Applications"
if [[ ! -d "$HOME/Applications/Voice.app" && ! -d "$HOME/Applications/LocalVoice.app" ]] &&
   [[ -d /Applications/Voice.app || -d /Applications/LocalVoice.app ]]; then
  if [[ -w /Applications ]] &&
     [[ ! -e /Applications/Voice.app || -w /Applications/Voice.app ]] &&
     [[ ! -e /Applications/LocalVoice.app || -w /Applications/LocalVoice.app ]]; then
    INSTALL_DIR=/Applications
  else
    echo 'Installing Voice in your user Applications folder; open this updated copy.'
  fi
fi
DESTINATION="$INSTALL_DIR/Voice.app"
bash "$PROJECT_ROOT/scripts/install-app.sh" "$PROJECT_ROOT/dist.noindex/Voice.app" "$INSTALL_DIR" \
  "$HOME/Library/Application Support/LocalVoice/App-backups.noindex"
echo "Installed Voice 0.6.1 at $DESTINATION"
echo 'Wait for Local editor ready in Dictation. Clean mode adds editing time; Fast skips it.'
echo 'If permission needs renewing: Privacy & Security > Device Control and Data Access (or Accessibility). Remove the old LocalVoice or Voice entry and add this installed Voice app.'
# Hide known generated bundles from Spotlight without deleting any backup.
for LEGACY_PROJECT in "$HOME/Downloads/LocalVoice-Start-Here" "$HOME/Downloads/LocalVoice-Upgrade" "$PROJECT_ROOT"; do
  if [[ -d "$LEGACY_PROJECT/dist/LocalVoice.app" ]]; then
    if [[ ! -e "$LEGACY_PROJECT/dist.noindex" ]]; then
      mv "$LEGACY_PROJECT/dist" "$LEGACY_PROJECT/dist.noindex" || true
    elif LEGACY_HIDDEN="$(mktemp -d "$LEGACY_PROJECT/dist.noindex/Previous.XXXXXX")"; then
      mv "$LEGACY_PROJECT/dist" "$LEGACY_HIDDEN/dist" || true
    fi
  fi
done
for LEGACY_BACKUP in "$HOME/Library/Application Support/LocalVoice"/App-backup.*; do
  if [[ -d "$LEGACY_BACKUP/LocalVoice.app" && "$LEGACY_BACKUP" != *.noindex && ! -e "$LEGACY_BACKUP.noindex" ]]; then
    mv "$LEGACY_BACKUP" "$LEGACY_BACKUP.noindex" || true
  fi
done
open "$DESTINATION"
