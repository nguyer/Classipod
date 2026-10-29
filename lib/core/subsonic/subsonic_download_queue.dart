import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_downloads.dart';

class DownloadJob {
  const DownloadJob(
    this.song,
    this.quality, {
    this.failed = false,
    this.error,
    this.replace = false,
    this.automatic = false,
    this.order = 0,
  });
  final MusicMetadata song;
  final DownloadQuality quality;
  final bool failed;
  final String? error;
  final bool replace;
  final bool automatic;
  final int order;
}

/// Persistent identities and choices, with a single foreground transfer.
/// A killed process leaves unfinished jobs queued, never marked complete.
class SubsonicDownloadQueue {
  SubsonicDownloadQueue(this.downloads) {
    _subscription = downloads.box.watch().listen((_) => _notify());
  }
  final SubsonicDownloads downloads;
  final _events = StreamController<void>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  Future<void>? _running;
  Future<void> _enqueueTail = Future.value();
  int _enqueueEpoch = 0;
  int _automaticEpoch = 0;
  int _generation = 0;
  bool foreground = true;
  bool waitingForNetwork = false;
  bool _closed = false;
  int _editing = 0;
  final Map<String, String> _runtimeErrors = {};
  MusicMetadata? active;
  int received = 0;
  int? total;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  Stream<void> get changes => _events.stream;
  void _notify() {
    if (!_closed) _events.add(null);
  }

  String _key(MusicMetadata song) => 'downloadJob:${song.identity}';
  bool autoDownload(String id) => downloads.box.get('downloadAll:$id') == true;
  bool wifiOnly(String id) => downloads.box.get('downloadWifi:$id') != false;
  String? lastError(String id) => _runtimeErrors[id];
  bool paused(String id) =>
      downloads.box.get('downloadPaused:$id') == true ||
      _runtimeErrors[id] == 'storageFull';

  Future<void> setAutoDownload(String id, bool enabled) =>
      downloads.box.put('downloadAll:$id', enabled);
  Future<void> setWifiOnly(String id, bool enabled) =>
      downloads.box.put('downloadWifi:$id', enabled);
  Future<void> setPaused(String id, bool enabled) async {
    await downloads.box.put('downloadPaused:$id', enabled);
    if (!enabled) _runtimeErrors.remove(id);
    if (enabled) interrupt();
  }

  List<DownloadJob> jobs(String id) {
    final result = <DownloadJob>[
      for (final key in downloads.box.keys.where(
        (key) => key.toString().startsWith('downloadJob:'),
      ))
        if (downloads.box.get(key) case final Map record)
          if (record['song'] case final MusicMetadata song)
            if (song.serverId == id)
              DownloadJob(
                song,
                DownloadQuality.values.firstWhere(
                  (quality) => quality.name == record['quality'],
                  orElse: () => DownloadQuality.original,
                ),
                failed: record['failed'] == true,
                error: record['error'] as String?,
                replace: record['replace'] == true,
                automatic: record['automatic'] == true,
                order: (record['order'] as num?)?.toInt() ?? 0,
              ),
    ];
    result.sort((a, b) => a.order.compareTo(b.order));
    return result;
  }

  Future<void> enqueue(
    Iterable<MusicMetadata> songs,
    DownloadQuality quality, {
    required String serverId,
    bool replace = false,
    bool automatic = false,
  }) {
    final epoch = _enqueueEpoch;
    final automaticEpoch = _automaticEpoch;
    final task = _enqueueTail.then(
      (_) => _enqueue(
        songs,
        quality,
        serverId: serverId,
        replace: replace,
        automatic: automatic,
        epoch: epoch,
        automaticEpoch: automaticEpoch,
      ),
    );
    _enqueueTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> _enqueue(
    Iterable<MusicMetadata> songs,
    DownloadQuality quality, {
    required String serverId,
    bool replace = false,
    bool automatic = false,
    required int epoch,
    required int automaticEpoch,
  }) async {
    if (_closed ||
        epoch != _enqueueEpoch ||
        (automatic && automaticEpoch != _automaticEpoch)) {
      return;
    }
    var order =
        (downloads.box.get('downloadQueueSequence') as num?)?.toInt() ?? 0;
    final records = <String, dynamic>{};
    final exclusions = <String>[];
    for (final song in songs) {
      if (_closed ||
          epoch != _enqueueEpoch ||
          (automatic && automaticEpoch != _automaticEpoch)) {
        return;
      }
      if (!song.isSubsonic || song.serverId != serverId) continue;
      final excludedKey = 'downloadExcluded:${song.identity}';
      if (automatic && downloads.box.get(excludedKey) == true) continue;
      if (!automatic && downloads.box.containsKey(excludedKey)) {
        exclusions.add(excludedKey);
      }
      final key = _key(song);
      final existing = downloads.box.get(key);
      if (records.containsKey(key)) continue;
      if (existing != null &&
          (automatic || existing is! Map || existing['failed'] != true)) {
        continue;
      }
      if (!replace && await downloads.resolve(song) != null) continue;
      records[key] = {
        'song': song,
        'quality': quality.name,
        'replace': replace,
        'automatic': automatic,
        'order': ++order,
      };
    }
    if (!_closed &&
        epoch == _enqueueEpoch &&
        (!automatic || automaticEpoch == _automaticEpoch) &&
        exclusions.isNotEmpty) {
      await downloads.box.deleteAll(exclusions);
    }
    if (!_closed &&
        epoch == _enqueueEpoch &&
        (!automatic || automaticEpoch == _automaticEpoch) &&
        records.isNotEmpty) {
      records['downloadQueueSequence'] = order;
      await downloads.box.putAll(records);
    }
  }

  Future<void> _waitForTransfer() async {
    try {
      await _running;
    } catch (_) {
      // Cancelling/removing work must still succeed after a failed transfer.
    }
  }

  Future<void> stopAutomatic(String id) async {
    _automaticEpoch++;
    await _enqueueTail;
    if (jobs(id)
        .any((job) => job.automatic && job.song.identity == active?.identity)) {
      interrupt();
      await _waitForTransfer();
    }
    await downloads.box.deleteAll(
      jobs(id).where((job) => job.automatic).map((job) => _key(job.song)),
    );
  }

  Future<void> retry(String id, {bool automaticOnly = false}) async {
    await downloads.box.putAll({
      for (final job in jobs(
        id,
      ).where((job) => job.failed && (!automaticOnly || job.automatic)))
        _key(job.song): {
          'song': job.song,
          'quality': job.quality.name,
          'replace': job.replace,
          'automatic': job.automatic,
          'order': job.order,
        },
    });
  }

  void interrupt() {
    _generation++;
    downloads.cancel();
  }

  void setForeground(bool value) {
    foreground = value;
    if (!value) interrupt();
    _notify();
  }

  Future<void> run(
    SubsonicClient client, {
    Future<bool> Function(bool wifiOnly)? networkAllowed,
  }) async {
    if (_closed || _editing > 0 || !foreground || paused(client.config.id)) {
      return;
    }
    final previous = _running;
    if (previous != null) {
      await previous;
      if (!_closed &&
          _editing == 0 &&
          foreground &&
          !paused(client.config.id) &&
          jobs(client.config.id).any((job) => !job.failed)) {
        await run(client, networkAllowed: networkAllowed);
      }
      return;
    }
    final task = _drain(client, networkAllowed: networkAllowed);
    _running = task;
    try {
      await task;
    } finally {
      if (identical(_running, task)) _running = null;
      _notify();
    }
  }

  Future<void> _drain(
    SubsonicClient client, {
    Future<bool> Function(bool wifiOnly)? networkAllowed,
  }) async {
    final generation = _generation;
    final id = client.config.id;
    waitingForNetwork = false;
    final pending = ListQueue<DownloadJob>();
    while (!_closed &&
        _editing == 0 &&
        foreground &&
        !paused(id) &&
        generation == _generation) {
      if (pending.isEmpty) pending.addAll(jobs(id).where((job) => !job.failed));
      if (pending.isEmpty) break;
      final job = pending.removeFirst();
      final savedJob = downloads.box.get(_key(job.song));
      if (savedJob is! Map || savedJob['failed'] == true) continue;
      if (job.automatic && !autoDownload(id)) {
        await downloads.box.delete(_key(job.song));
        continue;
      }
      if (networkAllowed != null && !await networkAllowed(wifiOnly(id))) {
        waitingForNetwork = true;
        _notify();
        break;
      }
      if (!foreground || paused(id) || generation != _generation) break;
      waitingForNetwork = false;
      active = job.song;
      received = 0;
      total = null;
      _notify();
      try {
        if (job.replace || await downloads.resolve(job.song) == null) {
          await downloads.download(
            client,
            job.song,
            quality: job.quality,
            onProgress: (bytes, length) {
              received = bytes;
              total = length;
              final now = DateTime.now();
              if (now.difference(_lastProgress).inMilliseconds >= 250) {
                _lastProgress = now;
                _notify();
              }
            },
          );
        }
        await downloads.box.delete(_key(job.song));
      } catch (error) {
        if (generation != _generation ||
            !foreground ||
            (error is SubsonicException && error.code == 'cancelled')) {
          break;
        }
        final storageFull =
            error is FileSystemException &&
            [28, 112].contains(error.osError?.errorCode);
        if (storageFull) _runtimeErrors[id] = 'storageFull';
        await downloads.box.put(_key(job.song), {
          'song': job.song,
          'quality': job.quality.name,
          'replace': job.replace,
          'automatic': job.automatic,
          'order': job.order,
          'failed': true,
          'error': storageFull
              ? 'storageFull'
              : error is SubsonicException
              ? error.code
              : 'download',
        });
        if (storageFull) {
          await setPaused(id, true);
          break;
        }
      } finally {
        active = null;
        _notify();
      }
    }
  }

  Future<void> remove(MusicMetadata song) async {
    final stopActive = active?.identity == song.identity;
    if (stopActive) _editing++;
    try {
      if (stopActive) {
        interrupt();
        await _waitForTransfer();
      }
      await downloads.box.delete(_key(song));
      if (song.serverId != null && autoDownload(song.serverId!)) {
        await downloads.box.put('downloadExcluded:${song.identity}', true);
      }
      await downloads.remove(song);
    } finally {
      if (stopActive) _editing--;
      _notify();
    }
  }

  Future<void> clear(String id, {bool removeFiles = true}) async {
    _editing++;
    _enqueueEpoch++;
    try {
      interrupt();
      await _enqueueTail;
      await _waitForTransfer();
      await downloads.box.deleteAll(jobs(id).map((job) => _key(job.song)));
      if (removeFiles) {
        await setAutoDownload(id, false);
        await downloads.removeServer(id);
        await setPaused(id, false);
      }
      waitingForNetwork = false;
    } finally {
      _editing--;
      _notify();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _enqueueEpoch++;
    interrupt();
    await _enqueueTail;
    await _waitForTransfer();
    await _subscription.cancel();
    await _events.close();
  }
}
