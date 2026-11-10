# Download and share Voice

Share this public link with anyone:

**https://github.com/AustineAuggie/voice**

They can read the instructions and download the source without being invited to the repository. Downloading Voice from GitHub does not send their recordings to GitHub: transcription, text editing, meeting summaries and speaker analysis run on their own Mac. No local server or cloud account is needed to use Voice.

## What they need

- An **Apple silicon Mac** (M1 or newer), running macOS 13 or newer.
- Apple Command Line Tools with **macOS SDK 15 or newer** to compile the app. The installer explains missing requirements and downloads CMake if needed.
- Internet access for initial setup. The first installation downloads approximately **6.34 GB of model files**, plus tools and engine dependencies. Allow additional storage for the build and saved meetings.

This is a **source installer**. It builds Voice on the recipient's Mac; the download is not a precompiled app that can simply be dragged into Applications. Windows, Linux, iPhone and Chrome extension versions are not included.

## Download and install

1. Open the repository link above and choose **Code → Download ZIP**.
2. Open the downloaded ZIP to extract it. GitHub normally names the folder **voice-main**. Keep the files together in that folder.
3. Finish any recording in an existing Voice installation, then open **Terminal**.
4. Type `bash `, including the space after it. Drag **install.sh** from the extracted folder into Terminal, then press **Return**. Do not press Return after typing only `bash`.
5. Follow the installer messages. If Apple asks you to install Command Line Tools, finish that installation and run the same command again.
6. Wait for setup to download and verify the models, compile Voice and open the installed app. Grant the requested Mac permissions and test a short dictation and meeting.

For the usual Downloads folder and unchanged folder name, the complete command is:

```bash
bash "$HOME/Downloads/voice-main/install.sh"
```

If Finder added a number to the folder name, use the drag-and-drop method above. Existing verified models are reused during updates. Keep older source folders until an update succeeds because their build caches may be reused.

## What stays on the Mac

Models, recordings, transcripts, meeting notes and vocabulary are stored locally. The existing data location is `~/Library/Application Support/LocalVoice`; its older name is retained for compatibility. Do not delete this folder when removing old downloaded installers.

Automatic meeting detection suggests starting notes; recording starts only after the user chooses Start. In-room meetings start manually. Speaker labels are estimates and remain experimental: similar voices, overlapping speech and approximate word timing can produce incorrect or unassigned passages. Test the app before relying on it for an important meeting.

See [README](README.md) for full features and requirements, and [Troubleshooting](docs/TROUBLESHOOTING.md) for missed prompts, installation errors and speaker-analysis failures.
