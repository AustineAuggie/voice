# Share Voice through GitHub and keep it local

GitHub distributes the software. The person who downloads it runs the software on their own Mac. Publishing source code or a release ZIP does not move speech processing online.

| Arrangement | Where processing happens | What this project provides |
| --- | --- | --- |
| GitHub download, local app | Each person's Apple silicon Mac | Supported: download source, run the installer, grant Mac permissions |
| Hosted web service | A server receives audio and runs models | Not implemented; would need a separate service, authentication, storage and hosting |
| Self-hosted server | A server managed by the user | Not implemented; this is a native Mac desktop app, not a server package |

There is no need for your friends or family to run a local server. They need a compatible Mac. The app is not currently a Windows, Linux, iPhone or Chrome extension application.

## What to publish

Use the clean source package as the repository root. It contains Sources, Native, Resources, Tests, scripts, installer scripts, documentation, `.gitignore`, `.github`, the licence and dependency notices. Keep the repository outside `~/Library/Application Support/LocalVoice`.

Keep downloaded models, build caches, installed apps, meeting audio, transcripts, personal vocabulary, signing keys and credentials out of the repository. The included `.gitignore` excludes common generated and private file locations from normal `git add`; it cannot protect files manually uploaded through a browser or already tracked in Git. Review the actual file list before publishing.

The repository's existing licence is MIT, with copyright attributed to Sunday. That licence and all dependency notices remain included. Repository visibility is a separate choice: a public repository makes its code accessible publicly; a private repository limits access to the people you grant access to. The public repository is https://github.com/AustineAuggie/voice. See [Download and share Voice](../DISTRIBUTION.md) for the simplest installation and sharing steps.

## First upload

1. Create an empty GitHub repository under the intended account, with the chosen visibility. Keep its generated README, licence and `.gitignore` options off because this project already supplies those files.
2. Add the extracted project folder as a local repository using GitHub Desktop or Git. Include the project contents at the root, not the surrounding Downloads directory or older build folders.
3. Inspect the proposed commit. It should contain source, tests and documentation. It should not include model weights, recordings, `.build`, `dist.noindex` or your Mac's application data.
4. Commit and publish to the selected repository.
5. Run the Mac build check below and complete a short capture test on a real Mac before marking a release ready for general use.

GitHub's [release feature](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) lets a maintainer attach a versioned download and release notes. For this release, attach the clean **Voice-0.6.1.zip** source installer and describe it as a source build. GitHub's automatically generated source ZIP is also source code, not an installed app. Neither archive contains the large models.

## What another person does

1. Download and extract the release ZIP on their Apple silicon Mac.
2. Open Terminal. Type `bash ` including the trailing space, drag the extracted `install.sh` into Terminal, then press Return. This works even if the folder name differs from the example in README.
3. Complete any Apple Command Line Tools installation if requested, then run the same installer again.
4. Let setup download and verify the models, compile the app and install Voice.app. The first installation needs internet access and several gigabytes of free storage.
5. Open Voice, grant the requested Mac permissions and test a short dictation and meeting.

Their meeting audio, transcripts, personal notes and models are stored locally under `~/Library/Application Support/LocalVoice`. The legacy folder name is retained for compatibility. The app does not send those files to the GitHub repository. Shared exports, system backups or other software on their Mac are separate from Voice's processing.

## Mac build check on GitHub

`.github/workflows/checks.yml` is a **manual** check. After it is on the repository's default branch, use **Actions → Mac build check → Run workflow**. It uses an Apple silicon `macos-15` runner, runs the portable checks through `build.sh`, compiles the native Mac interface and three engine executables, checks the app signature, and runs the installer transaction tests. It downloads engine dependencies but does not download the multi-gigabyte speech/editor models, install Voice, capture a microphone or publish a release.

[The initial Mac build run](https://github.com/AustineAuggie/voice/actions/runs/42857630920) passed for source commit `27dc5d64b367ebeb6df0260534042068d6415c0b`, including native compilation, app-signature verification and installer transaction tests. Later source changes need their own build check. A successful run can catch SDK/compiler/linking errors; it cannot prove real meeting detection, audio capture or speaker accuracy. Private repository usage draws on the account's Actions allowance and can incur charges. GitHub documents the [runner options](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [manual workflow steps](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).

## Easier installation later

A future release can offer a prebuilt Mac installer so recipients do not compile the app. That needs a tested distribution package, reliable first-run model setup, and an appropriate signing/notarisation process. The current build uses an ad hoc signature and is not notarised. Do not describe this source ZIP as a ready-to-drag, notarised app.
