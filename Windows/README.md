# Voice for Windows

Voice is a local dictation and meeting-notes app. This Windows edition uses a native Windows interface and the same local speech, editing and speaker engines as the Mac edition. It does not require a cloud server, subscription or API key.

## Download and open

Open the [Windows preview release](https://github.com/AustineAuggie/voice/releases/tag/v0.7.0-windows-preview) and download **Voice-0.7.0-Windows-x64.zip** under Assets. GitHub's separate **Source code** archives are for developers and do not contain the built Windows application.

1. Right-click the downloaded ZIP and choose **Extract All**.
2. Open the extracted **Voice-0.7.0-Windows-x64** folder.
3. Double-click **Voice.exe**. Keep the entire folder together: the other files and the **engines** folder are required.
4. Open Settings and download the speech model. Download the optional editor model for Clean mode and meeting summaries, and the speaker models for meeting speaker analysis.
5. Test a short dictation in Notepad, then a short meeting before relying on a long recording.

The application includes its .NET desktop runtime. Your friend does not need Visual Studio, Python, CMake or .NET installed separately. The models are not inside the ZIP; first use needs internet access to download and verify the selected models. Processing then runs locally.

## Computer requirements

- **Intel or AMD 64-bit Windows**, with Windows 11 recommended. Windows on ARM and 32-bit Windows packages are not included.
- Windows 10 compatibility has not been established on a physical PC. The application uses .NET 10; Microsoft's supported Windows versions depend on the Windows edition and servicing status. See [Microsoft's Windows support table](https://learn.microsoft.com/dotnet/core/install/windows).
- **16 GB RAM is recommended** for the large speech and editor models. Actual memory needs depend on the selected models and the length of the recording.
- Several gigabytes of free storage for models, plus space for saved meeting audio. The default speech model together with the optional editor and speaker models uses approximately **6.34 GB**, separate from the application download. Additional speech models use more space.
- A microphone. For online meetings, select microphone plus system audio. Headphones help avoid capturing remote voices twice through the microphone.

This first Windows build uses CPU inference. It does not require an NVIDIA GPU. Older or low-power PCs may take considerably longer to transcribe, clean text or analyse a meeting. A successful build is not a performance benchmark.

## Dictation and meetings

Use **Ctrl+Alt+Space** to start and stop dictation, or use the Dictation page. Click the destination text field before using the shortcut. Voice pastes the completed text into that application. Elevated applications, password fields and applications with unusual editors may refuse automatic input; the last text remains available to copy manually.

Fast mode skips the local editor. Clean mode uses the optional editor model to improve punctuation and resolve explicit self-corrections. Add preferred names and terms in Dictionary. Corrections and model outputs can still be wrong; review important text.

Notetaker records an online meeting using microphone plus system audio, or an in-room meeting using the microphone. Recording only begins after you choose Start. Meeting detection is a heuristic and can miss a call; manual Start remains available. System audio can include other applications, so pause unrelated media before recording. Meeting capture does not mute call audio.

Speaker numbering is per meeting and does not have a fixed three-person limit. It is an estimate, not a way to identify real names. Similar voices, brief turns, overlapping speech and approximate word timing can result in incorrect or unclear labels. The original transcript and retained audio provide a way to review the result.

## Optional installation and shortcuts

You can keep using **Voice.exe** directly from the extracted folder. To add Start menu and desktop shortcuts, close Voice and double-click **install.cmd** in that same folder. It installs only for the current Windows user under:

```text
%LOCALAPPDATA%\Programs\Voice
```

No administrator access is requested. The installer verifies the package's file hashes before replacing an existing recognised installation and retains the previous app folder beside it. It does not overwrite an unrelated folder named Voice. If Windows or your organisation blocks PowerShell scripts, use the portable Voice.exe instead; changing security policy is not necessary.

This preview is not digitally signed. Download it from this repository and compare the ZIP checksum with its accompanying `.sha256` file if needed. A checksum checks the downloaded bytes; it is not a publisher signature.

## Data and removal

Models, settings, vocabulary and meeting records are stored separately from the application:

```text
%LOCALAPPDATA%\Voice
```

Closing or updating the app does not remove that folder. Removing an extracted app folder, or an old `Voice.previous-*` installation backup, does not remove your saved data. Keep the app folder you actually run. To remove a shortcut installation, close Voice, remove `%LOCALAPPDATA%\Programs\Voice` and its Start menu/desktop shortcuts. Keep `%LOCALAPPDATA%\Voice` if you want to retain models and meetings.

## Troubleshooting

- **No microphone audio:** open Windows Settings → Privacy & security → Microphone and allow desktop apps to use the microphone. Also check the selected/default recording device in Windows Sound settings.
- **No remote audio:** choose online meeting capture and use the intended Windows default playback device. Test a short call. Headphone/device changes during recording may interrupt capture.
- **Shortcut does nothing:** another app may already own Ctrl+Alt+Space. Use Voice's Dictation button and close the conflicting shortcut app before restarting Voice.
- **Text does not paste:** keep the destination text field active. Use Copy for editors or elevated programs that reject synthetic input.
- **Model download fails:** check storage/network access, then retry. A failed or cancelled download is not accepted as a ready model.
- **Slow editing:** use Fast mode; CPU-only cleanup and long meeting summaries can take time.
- **Speaker analysis is wrong:** speaker attribution is experimental. Retain the audio and review the transcript rather than treating the labels as verified identities.

## Building from source

Developers need a Windows x64 machine, .NET 10 SDK, Visual Studio 2022 Build Tools with the C++ desktop workload, CMake, Git, PowerShell 7 and Python 3 for the inference smoke test. Run from the repository root:

```powershell
pwsh -File .\Windows\build.ps1
```

The script builds native engines, runs core tests, performs native worker and real speech inference checks, publishes the self-contained WPF application, checks packaged startup, tests installer integrity/upgrades, and creates the ZIP with a SHA-256 file under `dist-windows.noindex`. It uses a small speech model only for the build's inference check. User model downloads remain separate.

The [Windows build workflow](../.github/workflows/windows.yml) runs on relevant pushes and pull requests. A maintainer can also run **Actions → Windows build and package → Run workflow**. The publish option creates a separate `v0.7.0-windows-preview` prerelease only after all build steps pass. It never replaces the existing Mac release. Re-running publication for an existing tag fails instead of silently replacing the download.

Automated Windows-runner checks do not prove physical microphone behaviour, real call capture, app-specific paste compatibility or speaker accuracy on your friend's PC. The first release is a preview and needs that hands-on check.

Source is MIT licensed; keep the bundled `LICENSE`, `THIRD-PARTY-NOTICES.txt` and `Licences` folder when redistributing a build.
