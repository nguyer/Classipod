import 'dart:convert';
import 'dart:io';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/subsonic/download_quality.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

/// Durable local media, independent of the player and future remote outputs.
/// Records contain identities and metadata, never authenticated stream URLs.
class SubsonicDownloads {
  SubsonicDownloads(this.box, this.directory);
  final Box<dynamic> box;
  final Directory directory;
  final Set<String> _busy = {};
  final Map<String, Future<void>> _active = {};
  int _generation = 0;

  void cancel() => _generation++;

  DownloadQuality get quality => DownloadQuality.values.firstWhere(
    (value) => value.name == box.get('downloadQuality'),
    orElse: () => DownloadQuality.original,
  );

  Future<void> setQuality(DownloadQuality value) =>
      box.put('downloadQuality', value.name);

  String _key(MusicMetadata song) => 'download:${song.identity}';

  List<MusicMetadata> songs(String serverId) => [
    for (final key in box.keys.where(
      (key) => key.toString().startsWith('download:'),
    ))
      if (box.get(key) case final Map record)
        if (record['song'] case final MusicMetadata song)
          if (song.serverId == serverId) song,
  ];

  File? _file(MusicMetadata song) {
    final record = box.get(_key(song));
    if (record is! Map || record['file'] is! String) return null;
    final name = record['file'] as String;
    // Do not trust persisted paths outside our private directory.
    if (!RegExp(r'^[a-f0-9]+-[0-9]+\.(media|mp3)$').hasMatch(name)) {
      return null;
    }
    return File('${directory.path}/$name');
  }

  Future<Uri?> resolve(MusicMetadata song) async {
    final file = _file(song);
    if (file == null) return null;
    final record = box.get(_key(song)) as Map;
    try {
      if (!await file.exists() || await file.length() != record['bytes']) {
        return null;
      }
      return file.uri;
    } on FileSystemException catch (_) {
      return null;
    }
  }

  Future<void> download(
    SubsonicClient client,
    MusicMetadata song, {
    DownloadQuality? quality,
    void Function(int received, int? total)? onProgress,
  }) {
    if (_active.containsKey(song.identity)) {
      return Future.error(const SubsonicException('busy'));
    }
    final task = _download(
      client,
      song,
      quality: quality,
      onProgress: onProgress,
    );
    _active[song.identity] = task;
    return task.whenComplete(() => _active.remove(song.identity));
  }

  Future<void> _download(
    SubsonicClient client,
    MusicMetadata song, {
    DownloadQuality? quality,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!song.isSubsonic || song.serverId != client.config.id) {
      throw const SubsonicException('unavailable');
    }
    if (!_busy.add(song.identity)) {
      throw const SubsonicException('busy');
    }
    final selected = quality ?? this.quality;
    final generation = _generation;
    final hash = sha256.convert(utf8.encode(song.identity));
    final name =
        '$hash-${DateTime.now().microsecondsSinceEpoch}.'
        '${selected == DownloadQuality.original ? 'media' : 'mp3'}';
    final file = File('${directory.path}/$name');
    final partial = File('${file.path}.part');
    var committed = false;
    try {
      final previous = _file(song);
      await directory.create(recursive: true);
      final response = await client.audio(
        song.remoteSongId!,
        selected.parameters,
      );
      final sink = await partial.open(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (generation != _generation) {
            throw const SubsonicException('cancelled');
          }
          await sink.writeFrom(chunk);
          received += chunk.length;
          onProgress?.call(received, response.contentLength);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final bytes = await partial.length();
      if (generation != _generation) {
        throw const SubsonicException('cancelled');
      }
      if (bytes == 0 ||
          (response.contentLength != null && bytes != response.contentLength)) {
        throw const SubsonicException('download');
      }
      await partial.rename(file.path);
      await box.put(_key(song), {
        'song': song,
        'file': name,
        'bytes': bytes,
        'quality': selected.name,
        'contentType': response.headers['content-type'],
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await box.flush();
      committed = true;
      if (previous != null) {
        try {
          if (await previous.exists()) await previous.delete();
        } on FileSystemException catch (_) {
          // A stale previous file must not invalidate a completed download.
        }
      }
    } finally {
      _busy.remove(song.identity);
      if (await partial.exists()) await partial.delete();
      if (!committed && await file.exists()) await file.delete();
    }
  }

  Future<void> remove(MusicMetadata song) async {
    if (_busy.contains(song.identity)) {
      throw const SubsonicException('busy');
    }
    final file = _file(song);
    await box.delete(_key(song));
    await box.flush();
    if (file != null && await file.exists()) await file.delete();
  }

  Future<void> removeServer(String serverId) async {
    cancel();
    for (final task in _active.values.toList()) {
      try {
        await task;
      } catch (_) {
        // A failed or cancelled download has no completed record to remove.
      }
    }
    for (final song in songs(serverId)) {
      await remove(song);
    }
  }
}
