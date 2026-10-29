# Offline Subsonic / Navidrome audio

## Building a phone test APK on Windows

Run `./scripts/build_android_test.ps1` with Flutter on PATH, or pass
`-FlutterExecutable` with the path to `flutter.bat`. This generates Android
plugin registration before building the `dev` flavor using the normal app
entry point. It temporarily disables desktop targets only for that process,
so desktop symlink requirements cannot interrupt Android dependency setup.
The APK is `build/app/outputs/flutter-apk/app-dev-debug.apk` and installs as
Classipod Dev alongside the production app.

Do not continue with `--no-pub` after `flutter pub get` fails: an APK without
`GeneratedPluginRegistrant` can compile and pass signature verification but
cannot initialize native storage or audio plugins. The Android pre-build task
now rejects this condition. Verify the built app actually reaches its menu
on an Android device or emulator before sharing it.

## Downloading songs

On Android, open a Subsonic song's options and select **Offline audio**.
Choose Original (raw), High (320 kbps MP3), Medium (192 kbps MP3), or
Low (128 kbps MP3). The last choice is saved as the default. Choose
**Remove download** in the same dialog to free its storage.

Keep the app open until the dialog closes. This milestone downloads one
selected song at a time; it does not provide OS-managed background jobs,
resumable transfers, bulk album downloads, or a download queue.

## Quality and storage

Requests use `stream.view`, `format=raw` for Original, and `format=mp3`
with `maxBitRate=320`, `192`, or `128` for the MP3 choices. These are
server transcoding requests, not client encodes: the server must have
MP3 transcoding configured. Subsonic specifies a maximum bitrate, so a
lower-bitrate source may remain below the selected limit. Stored quality
describes the requested quality; it does not claim measured output bitrate.
See the [OpenSubsonic stream API](https://opensubsonic.netlify.app/docs/endpoints/stream/).

Audio is streamed into private application support storage, never buffered
in full in memory. A temporary file becomes visible to playback only after
the transfer completes, is nonempty, and matches Content-Length when given.
Non-audio API errors are rejected. Failed replacements retain the previous
download. Interrupted process termination can leave an unused file; partial
files have no playable metadata and cannot be resolved as completed audio.

The existing Hive box stores a separate record keyed by account identity
and song identity: metadata, relative filename, byte count, requested quality,
content type and completion timestamp. It stores no stream URL or password.
Downloaded metadata survives catalog refreshes even if the server removes
a song. Disabling the account hides its library; re-enabling restores access.
Removing or replacing the configured account removes its downloads.
Uninstalling the app removes its private audio.

Playback verifies the saved file exists and has the expected size before
using its file URI. A missing or changed file falls back to normal streaming.
Offline playback needs the account enabled, but no successful server ping.
Original formats still require support from the Android audio decoder.

## Future Sonos support

`SubsonicDownloads` has no dependency on just_audio or speaker discovery.
`SubsonicController.resolveUri(song, allowLocal: false)` explicitly bypasses
phone-local files for a future remote playback output. The existing local
queue/player boundary remains intact. Sonos discovery, device selection,
transport commands and grouping/ungrouping should be a separate output
service; a Sonos device must be able to reach the server URL itself.
Do not persist authenticated URLs or send `file:` URIs to remote speakers.

## Verification

Unit tests cover each quality request, persistence across Hive reopen,
metadata recovery, account isolation, replacement failures, HTTP/API errors,
empty audio, stream errors, cancellation, duplicate requests, cache-first
playback without credentials, missing files and remote-output cache bypass.

Android device smoke test: download each quality from a server with MP3
transcoding enabled, relaunch in airplane mode, play and seek the saved
track, remove it, then restore networking and confirm streaming fallback.
Also test storage exhaustion and switching/removing accounts during a
transfer. Web keeps streaming and does not expose download controls.
