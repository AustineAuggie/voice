# Voice 0.6.1 validation

10 November 2026. This release repairs one reproduced speaker-engine failure, adds useful local error diagnostics, improves meeting prompt matching/rearming and prepares source distribution through GitHub. It does not replace the speech or speaker models.

## Speaker engine: actual inference

The previous worker exited with code 1 on real two-speaker speech amplified to a finite peak of 3.42456. The new worker normalises over-range samples in its private memory mapping, leaves the original audio bytes unchanged, and returns the same analysis as a separately normalised reference.

171 native checks passed with sherpa-onnx v2.0.1 on Linux x86_64 CPU. These cover real inference, finite over-range audio, malformed data, NaN/infinities, missing models, failure markers, cancellation, private output permissions and unchanged input bytes. Evidence is recorded in Tests/Fixtures/diarizer-repair-results.json. Four speech fixtures yielded 2, 4, 2 and 3 estimated speakers; their expected counts were 2, 4, 2 and 2. One fixture still over-splits. This is not an accuracy benchmark or a Mac performance measurement.

The user's screenshot showed only a generic code 1. The reproduced failure is a credible failure route, not a confirmed diagnosis of that particular recording. If it persists after retrying, the bounded local diagnostic log supplies the underlying native error. Unknown errors are not labelled with an invented cause.

## Swift regression and process checks

All 13 suites in scripts/test.sh passed: domain 90; correction 283; spoken formatting 100; audio lifecycle 16; dictation AppState 1,261; worker lifecycle 529; meeting coordinator 111; speaker domain 52; speaker audio 33; speaker coordinator 38; workspace 37; meeting detection 43; speaker process/diagnostics 25.

The 43 new detection checks cover supported helper ownership, independent candidate suppression, candidate ranking, short signal loss, back-to-back meetings, busy-state observation, opt-out/reset and obvious ended/landing titles. Detection remains a heuristic using process metadata and accessible window titles. It never records to detect a call. Hidden tabs, unfamiliar titles, permissions and muted calls can still lead to misses. In-room meetings are started manually.

The 25 new process checks run a real child-process fixture through MeetingSpeakerProcessor. They cover readable known failures, unknown nonzero exits, retained bounded diagnostics, redacted paths, private permissions, no transcript/title/dictionary in diagnostics, temporary audio cleanup, cancellation followed by immediate retry, and successful recovery clearing a stale diagnostic. Existing coordinator checks verify audio retention on failure and retry without re-recording. Simulated workers/devices do not establish real recording quality.

## Installer, source package and GitHub

17 checked-source updater tests and 13 installation transaction tests passed. Real unchanged 0.4.2, 0.5.0 and 0.6.0 source packages were used to verify accepted upgrades, cache preservation, unknown-edit refusal and rollback. Mac-only commands use test stand-ins in installation tests; real signing was not executed here.

Voice.app is version 0.6.1 build 12. The bundle identifier, internal LocalVoice executable and LocalVoice support directory remain unchanged. The sidebar reads the bundle version. Existing models are reused.

The clean package includes .gitignore and a manual-only Mac build workflow. YAML and embedded shell syntax were checked; the workflow has not run. No GitHub repository was created or published. Model weights, recordings, credentials and build outputs are not part of the source ZIP. Dependency licences remain included.

## Limits and Mac verification

All Swift sources pass syntax parsing, and portable Foundation paths compile with Swift 6.0.3 in Swift 5 mode. There is no macOS SDK or native Mac desktop here. These checks cannot establish Mac framework type-checking, actual permissions, live meeting detection, UI interactions or Apple silicon model performance. The installer compiles before replacing the installed app; the included manual GitHub Actions workflow can provide a genuine Mac build check after publication.

Speaker word attribution retains the prior timing limitation: in the earlier 16-second speech-to-speaker integration fixture, 14 of 33 word pieces were Unclear. This release does not claim to fix coarse Whisper timestamps, overlapping speech or similar-voice clustering.

After installation, confirm 0.6.1 in the sidebar. Open the saved failed meeting and select the three-dot menu, then Recover / retry. If analysis still fails, select Copy speaker diagnostics and review that text before sharing it. Test prompts with two consecutive short calls, including leaving and joining another call. Start manually if a prompt is missed.

## Reproduce

- Mac: `bash scripts/test.sh`. Linux: `SWIFTC=/path/to/swiftc bash scripts/test.sh`.
- `python3 Tests/UpdateTests.py /path/to/LocalVoice-0.4.2 /path/to/LocalVoice-0.5.0 /path/to/Voice-0.6.0`
- `python3 Tests/InstallTests.py`
- `python3 Tests/diarizer_smoke.py --help` for the native worker/model/fixture arguments.
