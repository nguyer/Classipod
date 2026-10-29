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

Settings > Downloads shows saved song count and storage use, the current
transfer and byte progress. Downloaded music opens a separate submenu for
saved, queued and failed songs. It includes:

- Download quality for newly queued songs: Original/raw, High/320 kbps MP3,
  Medium/192 kbps MP3, or Low/128 kbps MP3. Existing files and queued quality
  choices are not silently changed when the default changes.
- Wi-Fi only (on by default), or allow any active network including mobile data.
- Make entire library available offline.
- Pause/resume, retry failures, clear the queue, remove one download, or remove
  all downloaded audio. Destructive bulk actions require confirmation.

Completed audio is never deleted from the server, and playlist entries remain
unchanged. Removing an individual download while automatic library downloads
are enabled excludes it from future automatic downloads. Download it explicitly
again, or re-enable Make entire library available offline to include it again. Clearing the queue or removing all audio turns automatic
library downloads off, preventing immediate redownloads.

## Automatically keep the whole library offline

Enable **Make entire library available offline** in Settings > Downloads and confirm the
song count and quality. The app queues missing songs from the full server
catalog. Future library refreshes/scans queue newly discovered songs.
There is no timer or scheduled library check. Opening/resuming the app and
network changes only resume existing queued transfers. Previously completed
music is skipped, and server deletions do not automatically remove saved audio.

This is explicitly foreground-only: transfers pause when the app leaves the
foreground or the phone locks. No Android background worker or alarm is
registered. Reopening the app resumes the persistent queue; an interrupted
song restarts its transfer rather than resuming a partial byte range.
Transfers honor the network policy and pause setting.
Automatic failed jobs are retried after the next successful library scan;
manual failed jobs can be retried from Downloads. A full storage error pauses the queue so
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
failed jobs/retry, low-storage pausing, automatic additions after library
refreshes, exclusions/removal, and album/artist/playlist/settings UI actions.

## Future Sonos support

The download queue and storage service have no dependency on speaker discovery
or just_audio. `SubsonicController.resolveUri(song, allowLocal: false)` bypasses
phone-local files for remote outputs. Discovery, transport and grouping remain
separate future output services; a Sonos speaker must be able to reach the
server URI itself. Never send file: URIs or persist authenticated URLs for
remote speakers.

## APKs built by GitHub Actions

On a new fork, open the repository's **Actions** tab and select
**I understand my workflows, go ahead and enable them** once. GitHub disables
inherited workflows by default. If a PR was already opened while Actions was
disabled, push a new commit to its branch to trigger the checks.

Pull requests run **PR checks and Android APK** automatically. The workflow
analyzes the code and runs the full test suite with coverage, then builds a
signed dev/debug APK for ARM and ARM64 phones. The existing 1,000-track
stress check also runs independently. No release signing secrets are needed.

Open the pull request's Checks, choose **Build test APK**, and open the workflow
run. Its summary contains an APK download link; alternatively, choose
**Classipod-Android-APK-...** under Artifacts. Sign into GitHub, download and
extract the archive, then install `app-dev-debug.apk`. Artifacts and test
coverage are kept for 14 days. New commits cancel older runs on the same PR.
A manual **Run workflow** button is available once this workflow is on the
repository's default branch.

CI builds use a persistent, dedicated test signing key stored in the repository
Actions secret `CLASSIPOD_TEST_KEYSTORE_BASE64`. The build restores it only for
the job, checks its public certificate against `.github/test-signing.sha256`,
and removes the temporary file afterward. No private key is committed. A
missing or changed key stops the build instead of silently signing with a new
identity. APK builds run only for branches in this repository; PRs from other
forks run tests without receiving the signing key.

After installing the first APK signed with this key, later CI APKs install as
updates and preserve settings and downloaded music. Older builds used temporary
keys; moving from one of those may require one final uninstall, which removes
app data. The old CI keys cannot be recovered from the APK. Keep the test key
backed up and do not rotate it casually. Production release signing is unchanged.

To configure another fork, generate a dedicated Android debug keystore with
alias `androiddebugkey`, store/key password `android`, and a long validity.
Store its base64 contents in the Actions secret above. Export its DER certificate
with `keytool -exportcert` and put the certificate SHA-256 (lowercase hex) in
`.github/test-signing.sha256`. Never use a production release key for PR builds.
Local test builds can opt into the same key by setting
`CLASSIPOD_TEST_KEYSTORE_PATH` to an absolute keystore path outside the checkout.
