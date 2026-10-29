# Subsonic / Navidrome downloads

## Download songs and collections

- Hold Select on a server song and choose **Download**, then choose a quality.
- Hold Select on an album and choose **Download** to queue the full album.
- Hold an artist name in Artists (touch long press or hold Select) to download
  all server songs by that track or album artist. The artist's All Songs album
  also offers Download from its album options.
- Hold a playlist name to download every server song in that playlist. Holding
  a playlist header action with Select also downloads the whole playlist.

Mixed collections skip local phone files and songs from a different server
account. Duplicate songs are queued once. Collections skip completed audio;
explicitly downloading a single song replaces its previous download. The
quality picker closes after the queue is saved, so you can continue using the
app while transfers run. Monitor them in **Settings > Downloads**.

## Manage downloads

Settings > Downloads shows saved song count and storage use, pending/failed
songs, the current transfer and byte progress. It includes:

- Download quality for newly queued songs: Original/raw, High/320 kbps MP3,
  Medium/192 kbps MP3, or Low/128 kbps MP3. Existing files and queued quality
  choices are not silently changed when the default changes.
- Wi-Fi only (on by default), or allow any active network including mobile data.
- Download all music once, or Keep entire library offline.
- Pause/resume, retry failures, clear the queue, remove one download, or remove
  all downloaded audio. Destructive bulk actions require confirmation.

Completed audio is never deleted from the server, and playlist entries remain
unchanged. Removing an individual download while automatic library downloads
are enabled excludes it from future automatic downloads. Download it explicitly
again, use Download all music, or re-enable Keep entire library offline to
include it again. Clearing the queue or removing all audio turns automatic
library downloads off, preventing immediate redownloads.

## Automatically keep the whole library offline

Enable **Keep entire library offline** in Settings > Downloads and confirm the
song count and quality. The app queues missing songs from the full server
catalog, refreshes the catalog at most once every five minutes while open,
then queues newly added songs. Opening/resuming the app also checks when a
refresh is due. A manual server refresh likewise picks up new songs for this
setting. Previously completed music is skipped, and server deletions do not
automatically remove saved audio.

This is explicitly foreground-only: transfers pause when the app leaves the
foreground or the phone locks. No Android background worker or alarm is
registered. Reopening the app resumes the persistent queue; an interrupted
song restarts its transfer rather than resuming a partial byte range.
Automatic checks and transfers honor the network policy and pause setting.
Automatic failed jobs are retried on the next scheduled check; manual failed
jobs can be retried from Downloads. A full storage error pauses the queue so
you can free space before resuming.

The queue survives process termination, deduplicates by account and song ID,
preserves collection/playlist selection order, and transfers one song at a
time. Paused state, quality, network preference, automatic-library selection,
and per-song automatic exclusions persist. Removing or replacing an account
clears that account's queue, preferences and downloaded files.

## Storage and quality

Requests use `stream.view`, `format=raw` for Original, and `format=mp3` with
`maxBitRate=320`, `192`, or `128` for MP3 choices. The server must have MP3
transcoding configured. Bitrate is a requested maximum, not a guarantee of a
measured output bitrate. See the [OpenSubsonic stream API](https://opensubsonic.netlify.app/docs/endpoints/stream/).

Audio streams into private application support storage. Temporary files become
playable only after a nonempty transfer completes and matches Content-Length
when given. API errors are rejected; failed replacements preserve the previous
file. Metadata and queue entries in Hive contain identities and relative file
names, never passwords or authenticated stream URLs. Local playback validates
saved files first and falls back to streaming if they are missing or changed.
Original formats still require a decoder supported by the phone.

## Building and testing on Windows

Run `./scripts/build_android_test.ps1` with Flutter on PATH, or supply
`-FlutterExecutable` with the path to flutter.bat. The script temporarily
disables desktop targets only for that process, completes Android plugin
registration, and builds the dev flavor with the normal app entry point.
The APK is `build/app/outputs/flutter-apk/app-dev-debug.apk` and installs as
Classipod Dev alongside the production app.

Do not continue with --no-pub after dependency generation fails: an APK without
GeneratedPluginRegistrant can compile but fail to start. The Android pre-build
task rejects that condition. Verify startup on an emulator or phone before
sharing an APK.

Tests cover the quality mapping, restart persistence, selection ordering,
deduplication, account isolation, network and lifecycle gating, cancellation,
failed jobs/retry, low-storage pausing, automatic additions after scheduled
refreshes, exclusions/removal, and album/artist/playlist/settings UI actions.

## Future Sonos support

The download queue and storage service have no dependency on speaker discovery
or just_audio. `SubsonicController.resolveUri(song, allowLocal: false)` bypasses
phone-local files for remote outputs. Discovery, transport and grouping remain
separate future output services; a Sonos speaker must be able to reach the
server URI itself. Never send file: URIs or persist authenticated URLs for
remote speakers.
