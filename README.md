# Voice 0.6.1

**[Download, install and share Voice](DISTRIBUTION.md)** · Public repository: https://github.com/AustineAuggie/voice

A local Mac workspace for dictation and meeting notes. Formerly LocalVoice. Apple silicon, macOS 13 or newer.

**Local app, downloadable source.** Voice runs transcription, text editing, meeting summaries and speaker analysis on the user's Mac. GitHub can host this source and release downloads without hosting anyone's recordings. No server, account, subscription or API key is needed to use the app. Initial setup needs internet access to download tools and model files; ordinary processing then runs locally. There is no hosted web version in this project.

For sharing the project, see [Publishing and downloading through GitHub](docs/GITHUB.md). For missed meeting prompts or failed speaker analysis, see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Install

Finish any recording. Extract Voice-0.6.1.zip into Downloads, keep your older LocalVoice folders, and run this complete line in your existing Terminal:

```bash
bash "$HOME/Downloads/Voice-0.6.1/install.sh"
```

When it finishes, the installed app is **Voice.app**. The app opens its redesigned workspace. The old installed bundle is retained in a backup folder. Build failures leave the installed app in place. Existing models, vocabulary, preferences and meeting records are reused. The internal data folder and bundle identifier stay the same so renaming the app does not create an empty account or discard data.

The checked updater updates a recognised old source folder in place when possible to reuse its native build cache. Unknown edited source files are left untouched. If you intentionally changed source files, build this folder separately with `bash "$HOME/Downloads/Voice-0.6.1/setup.sh"`. If Finder appends a number to the extracted folder, or GitHub gives it a different name, type `bash ` with a space, drag install.sh from that folder into Terminal, then press Return once. Do not run a folder path or setup.sh alone: keep `bash ` before the dragged file path.

This is a source installer, not a precompiled or notarised app. Setup compiles the native Mac application and verifies its signature before installation. Apple Command Line Tools with macOS SDK 15 or newer are required; CMake is downloaded if needed. No sudo is required. If another unrelated application already occupies Voice.app at the destination, installation stops rather than replacing it.

From 0.5.0, no new models are required. Existing files are verified and reused. From 0.4.x, the speaker component adds about 42 MB of downloads (about 65 MB installed). The ZIP does not contain the multi-gigabyte Whisper or Qwen models.

A first installation downloads approximately 6.34 GB of model files, plus build tools and engine dependencies. Leave additional free space for the build and saved meetings. Each user downloads their own models; copying this small source ZIP does not include your model cache or meeting history.

## The redesigned workspace

- **Sidebar:** Dictation, Notetaker, Dictionary, History and Settings. The window is resizable and supports light and dark system appearances.
- **Notetaker:** searchable saved meetings with a preview beside the list. Open a meeting for the full reading view. A clear Start meeting button opens the audio and recording options.
- **My notes:** your own written meeting notes, stored separately from generated content.
- **Transcript:** timestamped passages with speaker labels, correction controls and speaker renaming/combining.
- **Summary:** a readable generated summary, decisions and action items, with the original supporting quotations. You can edit the summary without changing the transcript or your personal notes.

There are no calendar, account, team-sharing or cloud connections. Empty states use your actual saved meetings; no example meetings are inserted. Dictation keeps its compact listening/processing/done pill. The app name, menu, window title and Dock/Finder bundle are Voice.

## Notes and saving

Use Save in the editor. Dirty drafts also save before switching meetings, leaving the meeting page, changing sidebar sections, closing the main window, copying/exporting, or quitting. If a save fails, the draft remains and the navigation/close is blocked. Editors are disabled during meeting recording or processing. Starting/retrying a meeting first saves pending edits. Background transcription and summary updates do not overwrite dirty drafts.

Old edited meeting notes remain the edited summary; they are not silently reclassified as personal notes. The new My notes field begins empty for older meetings. Copy/export includes your saved personal notes, summary and transcript. Deleting a meeting still requires confirmation and removes its saved data; separate exported copies are independent.

## Record and identify speakers

In Notetaker, choose Start meeting. Online captures your microphone and Mac audio; In the room uses the microphone. Recording requires your explicit Start. Automatic meeting detection shows a compact “Meeting detected” banner with Start Notetaker, dismiss and an options menu. Enable “Suggest meeting notes” on the Notetaker page. Detection checks supported Zoom/Teams apps and browser meeting window titles, plus microphone activity metadata where macOS exposes it. It never records audio to detect a call and does not use a calendar. A likely meeting must stay detected for several seconds before a prompt appears. Detection can miss calls, particularly renamed browser windows and muted calls; Start meeting remains available manually. In-room meetings start manually. Dismissing suppresses repeats for that detected call. The banner expires after 30 seconds and offers a way to turn prompts off. Use headphones on calls to keep remote voices out of the microphone. Pause unrelated media because Mac audio capture can include other tabs and apps. Meeting mode does not mute Mac audio.

Speaker counting remains automatic, with no fixed three-speaker limit. Numbers are per meeting, not an identity system across meetings. Rename labels, change the speaker of a passage, create a new label or combine duplicate labels. Names are added by you, not inferred from voices. Speaker changes update the transcript and exports; already written summaries are not silently rewritten.

**Speaker attribution remains experimental.** Similar, brief or overlapping voices can be grouped incorrectly. Approximate word timings can leave parts of a sentence as Unclear speaker, even when the voice was detected. In the previous real 16-second integration fixture, 14 of 33 words remained unassigned. Successful engine execution does not by itself establish accurate speaker attribution. The original recognised text is retained.

Stop processing keeps captured audio and completed transcription for recovery. When Keep audio is off, raw audio is removed only after transcription and requested speaker analysis succeed. Speaker-analysis failure keeps audio for retry. There is a six-hour combined-source audio limit per analysis (roughly three hours for continuously recorded microphone plus call audio); this is a resource limit, not a speaker-count cap.

## Permissions and verification

If macOS requests renewed permission after the update, enable the installed Voice app for Microphone and Device Control and Data Access (Accessibility on older macOS). Online meetings may also need Screen & System Audio Recording. No screen video is recorded. Use the Settings page to locate the installed app.

TEST-RESULTS.md records executed checks and platform limits. Portable tests cover data, workflow and native inference; Swift syntax checks alone cannot establish that the native app builds with the Mac SDK. [The GitHub Actions Mac build](https://github.com/AustineAuggie/voice/actions/runs/42857630920) passed against that SDK on an Apple silicon runner, including app-signature verification and installer transaction tests. Real microphone capture, permissions, meeting detection and speaker quality still need checks on a Mac. After setup, confirm Voice 0.6.1 in the sidebar and test a short meeting before relying on a full recording.

## Development

Run `bash scripts/test.sh` from the project folder for portable checks. On Linux, set `SWIFTC` to an installed Swift compiler if it is not on PATH. On an Apple silicon Mac with CMake and the required Apple tools, `bash build.sh` builds `dist.noindex/Voice.app` without downloading the large speech/editor model weights or installing the app. `setup.sh` additionally downloads required models and installs the app.

The source licence is [MIT](LICENSE). Dependency and model notices are in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and Resources. Preserve those notices when redistributing the project or a built app.
