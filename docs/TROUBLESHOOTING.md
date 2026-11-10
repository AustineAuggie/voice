# Meeting prompts and speaker labels

## The meeting prompt did not appear

Open Voice and enable **Suggest meeting notes** in Notetaker. Ensure Voice has the required Mac accessibility permission; online recording additionally needs system audio access. Detection checks supported meeting apps, browser window titles and available process activity metadata. It does not listen to the microphone to recognise a meeting and has no calendar connection.

A prompt is a suggestion based on those signals. A renamed or inaccessible browser window, a brief call, unsupported software, or a call without an observable activity signal can be missed. Recording or processing another session also prevents a new recording prompt. Start a missed meeting manually from Notetaker. Conversations in the room start manually.

When reporting a miss, include the Voice version, macOS version, meeting app/browser, whether the microphone was muted, and whether Voice was recording or processing at the time. A screenshot of the relevant window title can help; redact private meeting details.

## Every passage says Microphone or Call audio

Those are **audio-source labels**, not estimates of how many people spoke. Look above the transcript for the speaker-analysis status. If it says analysis did not finish, the speaker stage failed; renaming Microphone to Speaker 1 would not recover the missing analysis.

Install Voice 0.6.1, reopen the saved meeting, and choose **… → Recover / retry**. The app keeps original audio when requested speaker analysis fails, even if Keep audio was off, so it can retry without recording the conversation again. Do not delete the saved meeting or its audio folder before retrying.

If retry fails, choose **… → Copy speaker diagnostics** and review the copied text before sharing it with support. When a worker exits with an error, Voice retains a local `speaker-diagnostic.txt` in that meeting's folder. It contains a bounded engine stderr excerpt (last 16 KiB), app/system version and error code, with private model/meeting/home paths redacted. It does not include the audio or transcript, is excluded from ordinary meeting exports and is removed after successful analysis. Nothing is uploaded automatically. If the copy action is absent, provide the full displayed error and Voice version instead.

The update fixes a reproduced failure where finite floating-point audio exceeded full scale: the engine now attenuates only its private working copy. Original recordings are preserved. This was reproduced on a real two-speaker fixture, but an earlier screenshot showing only `code 1` cannot prove that this was the cause of that specific recording's failure. General speaker accuracy still depends on the recording.

## Labels appear but the speakers are wrong

Speaker analysis estimates voices; it does not know participants' names. Labels are specific to one meeting, with automatic numbering for the voices detected. Short speech, similar voices, overlapping speech and coarse word timings can cause incorrect or unassigned passages.

Use the transcript's speaker controls to rename, reassign or combine labels. Headphones on an online call reduce remote audio leaking back into the microphone. Microphone placement and background noise matter for conversations in the room. Do not treat a completed analysis as proof that every passage has the right speaker.

## An update fails before installation

Keep the exact Terminal error. Setup leaves the installed app in place until the new build is ready to install. Keep the old source folder while diagnosing an in-place update; its build cache may be reused. Do not remove `~/Library/Application Support/LocalVoice`: it contains models and saved meeting data.

If Terminal says `No such file or directory`, locate the extracted installer in Finder and drag it after `bash ` into Terminal. If it says `Permission denied` when you ran setup.sh directly, use `bash ` before the file path. Do not add `sudo` to work around an installer error.
