#!/bin/bash
set -euo pipefail
umask 077
PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Run this installer on your Mac.'; exit 1; fi
TARGET_ROOT=""
for CANDIDATE in "$HOME/Downloads/LocalVoice-0.4.0" "$HOME/Downloads/LocalVoice-0.4.2" "$HOME/Downloads/LocalVoice-0.4.1" "$HOME/Downloads/LocalVoice-0.5.0" "$HOME/Downloads/Voice-0.6.0"; do
  if [[ -d "$CANDIDATE" && -f "$CANDIDATE/setup.sh" && -f "$CANDIDATE/Sources/MeetingState.swift" ]]; then
    TARGET_ROOT="$CANDIDATE"
    break
  fi
done
if [[ -z "$TARGET_ROOT" ]]; then
  echo 'Building Voice 0.6.1 from this package. Existing verified models will be reused.'
  exec bash "$PACKAGE_ROOT/setup.sh"
fi
if ! command -v python3 >/dev/null; then
  echo 'Python 3 is unavailable for the checked in-place update. Building this package instead.'
  exec bash "$PACKAGE_ROOT/setup.sh"
fi
python3 "$PACKAGE_ROOT/scripts/apply-update.py" "$TARGET_ROOT"
exec bash "$TARGET_ROOT/setup.sh"
