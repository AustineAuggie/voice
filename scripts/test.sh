#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build"
if [[ "$(uname -s)" == Darwin ]]; then COMPILER=(xcrun swiftc); else COMPILER=("${SWIFTC:-swiftc}"); fi
"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/TextProcessing.swift" "$PROJECT_ROOT/Sources/SpokenFormatting.swift" "$PROJECT_ROOT/Sources/SpokenCorrections.swift" "$PROJECT_ROOT/Sources/TextInsertion.swift" \
  "$PROJECT_ROOT/Sources/LocalMemory.swift" "$PROJECT_ROOT/Tests/TestPaths.swift" \
  "$PROJECT_ROOT/Tests/DomainTests.swift" -o "$PROJECT_ROOT/.build/domain-tests"
"$PROJECT_ROOT/.build/domain-tests"
"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/TextProcessing.swift" "$PROJECT_ROOT/Sources/SpokenFormatting.swift" "$PROJECT_ROOT/Sources/SpokenCorrections.swift" \
  "$PROJECT_ROOT/Tests/CorrectionTests.swift" -o "$PROJECT_ROOT/.build/correction-tests"
"$PROJECT_ROOT/.build/correction-tests"
"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/TextProcessing.swift" "$PROJECT_ROOT/Sources/SpokenFormatting.swift" "$PROJECT_ROOT/Sources/SpokenCorrections.swift" \
  "$PROJECT_ROOT/Tests/FormattingTests.swift" -o "$PROJECT_ROOT/.build/formatting-tests"
"$PROJECT_ROOT/.build/formatting-tests"
"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/RecordingAudioSilencer.swift" \
  "$PROJECT_ROOT/Tests/AudioFakes.swift" "$PROJECT_ROOT/Tests/AudioMuteTests.swift" -o "$PROJECT_ROOT/.build/audio-tests"
"$PROJECT_ROOT/.build/audio-tests"
"${COMPILER[@]}" -swift-version 5 -D LOCALVOICE_TESTING \
  "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/TextProcessing.swift" "$PROJECT_ROOT/Sources/SpokenFormatting.swift" "$PROJECT_ROOT/Sources/SpokenCorrections.swift" \
  "$PROJECT_ROOT/Sources/TextInsertion.swift" "$PROJECT_ROOT/Sources/LocalMemory.swift" \
  "$PROJECT_ROOT/Sources/AppState.swift" "$PROJECT_ROOT/Sources/RecordingAudioSilencer.swift" \
  "$PROJECT_ROOT/Tests/AudioFakes.swift" "$PROJECT_ROOT/Tests/AppStateFakes.swift" \
  "$PROJECT_ROOT/Tests/AppStateTests.swift" -o "$PROJECT_ROOT/.build/appstate-tests"
"$PROJECT_ROOT/.build/appstate-tests"
if command -v python3 >/dev/null; then
  "${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/Transcriber.swift" \
    "$PROJECT_ROOT/Tests/WorkerTests.swift" -o "$PROJECT_ROOT/.build/worker-tests"
  chmod +x "$PROJECT_ROOT/Tests/fake-worker.py"
  : > "$PROJECT_ROOT/.build/test-model"
  "$PROJECT_ROOT/.build/worker-tests" "$PROJECT_ROOT/Tests/fake-worker.py" "$PROJECT_ROOT/.build/test-model"
else
  echo 'Python 3 is unavailable; process tests skipped. App and text checks passed.'
fi

"${COMPILER[@]}" -swift-version 5 -D LOCALVOICE_MEETING_TESTING \
  "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
  "$PROJECT_ROOT/Sources/MeetingState.swift" "$PROJECT_ROOT/Sources/MeetingDetection.swift" \
  "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Sources/MeetingSpeakers.swift" \
  "$PROJECT_ROOT/Sources/TextInsertion.swift" "$PROJECT_ROOT/Tests/AppStateFakes.swift" \
  "$PROJECT_ROOT/Tests/MeetingTests.swift" -o "$PROJECT_ROOT/.build/meeting-tests"
"$PROJECT_ROOT/.build/meeting-tests"

"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
  "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Tests/SpeakerDomainTests.swift" -o "$PROJECT_ROOT/.build/speaker-domain-tests"
"$PROJECT_ROOT/.build/speaker-domain-tests"
"${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
  "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Sources/MeetingSpeakers.swift" \
  "$PROJECT_ROOT/Tests/SpeakerAudioTests.swift" -o "$PROJECT_ROOT/.build/speaker-audio-tests"
"$PROJECT_ROOT/.build/speaker-audio-tests"
"${COMPILER[@]}" -swift-version 5 -D LOCALVOICE_MEETING_TESTING \
  "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
  "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Sources/MeetingSpeakers.swift" \
  "$PROJECT_ROOT/Sources/MeetingState.swift" "$PROJECT_ROOT/Sources/TextInsertion.swift" \
  "$PROJECT_ROOT/Tests/AppStateFakes.swift" "$PROJECT_ROOT/Tests/SpeakerCoordinatorTests.swift" \
  -o "$PROJECT_ROOT/.build/speaker-coordinator-tests"
"$PROJECT_ROOT/.build/speaker-coordinator-tests"

"${COMPILER[@]}" -swift-version 5 -D LOCALVOICE_MEETING_TESTING \
  "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
  "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Sources/MeetingSpeakers.swift" \
  "$PROJECT_ROOT/Sources/MeetingState.swift" "$PROJECT_ROOT/Sources/MeetingDetection.swift" \
  "$PROJECT_ROOT/Sources/TextInsertion.swift" "$PROJECT_ROOT/Tests/AppStateFakes.swift" \
  "$PROJECT_ROOT/Sources/MeetingPresentation.swift" \
  "$PROJECT_ROOT/Tests/MeetingWorkspaceTests.swift" -o "$PROJECT_ROOT/.build/meeting-workspace-tests"
"$PROJECT_ROOT/.build/meeting-workspace-tests"

"${COMPILER[@]}" -swift-version 5 -D LOCALVOICE_MEETING_TESTING \
  "$PROJECT_ROOT/Sources/MeetingDetection.swift" "$PROJECT_ROOT/Tests/MeetingDetectionTests.swift" \
  -o "$PROJECT_ROOT/.build/meeting-detection-tests"
"$PROJECT_ROOT/.build/meeting-detection-tests"

if command -v python3 >/dev/null; then
  "${COMPILER[@]}" -swift-version 5 "$PROJECT_ROOT/Sources/Domain.swift" "$PROJECT_ROOT/Sources/MeetingDomain.swift" \
    "$PROJECT_ROOT/Sources/SpeakerDomain.swift" "$PROJECT_ROOT/Sources/MeetingSpeakers.swift" \
    "$PROJECT_ROOT/Tests/SpeakerProcessTests.swift" -o "$PROJECT_ROOT/.build/speaker-process-tests"
  chmod +x "$PROJECT_ROOT/Tests/fake-diarizer.py"
  "$PROJECT_ROOT/.build/speaker-process-tests" "$PROJECT_ROOT/Tests/fake-diarizer.py"
fi
