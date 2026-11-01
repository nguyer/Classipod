import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/models/playback_shuffle_mode.dart';
import 'package:classipod/core/services/playback/logical_queue.dart';
import 'package:classipod/core/services/playback/remote_audio_output.dart';
import 'package:classipod/core/utils/album_order.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class LibraryAudioHandler extends BaseAudioHandler {
  final AudioPlayer player;
  RemoteAudioOutput? _remote;
  StreamSubscription<RemotePlaybackState>? _remoteSubscription;
  bool get usingRemote => _remote != null;
  bool get isPlaying => _remote?.current.playing ?? player.playing;
  double get remoteVolume => _remote?.current.volume ?? player.volume;
  Future<void> setRemoteVolume(double value) =>
      _remote?.setVolume(value) ?? Future.value();

  Future<void> useRemoteOutput(RemoteAudioOutput? output) async {
    _sourceVersion++;
    _interruptSeek();
    _cancelRecovery();
    _wantPlayback = false;
    await _serialize(() async {
      await player.pause();
      if (_remote != null) {
        try {
          await _remote!.pause();
        } catch (_) {
          if (output != null) rethrow;
          // An unreachable speaker must not prevent returning to phone output.
        }
      }
      await _remoteSubscription?.cancel();
      _remote = output;
      _sourceLoaded = false;
      _error = null;
      if (output != null) {
        output.configure(_songs, logicalQueue.indices, logicalQueue.index);
        await output.setRepeat(logicalQueue.loopMode);
        _remoteSubscription = output.changes.listen((value) {
          if (_disposed || _remote != output) return;
          if (value.index >= 0 && value.index < _songs.length) {
            logicalQueue.index = value.index;
            _indices.add(value.index);
            _publishRemoteMetadata();
          }
          _wantPlayback = value.playing;
          _broadcast();
        });
      } else {
        _initialPosition = _lastPosition;
      }
      _broadcast();
    });
  }

  void _publishRemoteMetadata() {
    if (_songs.isEmpty) return;
    final song = _songs[logicalQueue.index];
    mediaItem.add(
      MediaItem(
        id: 'classipod-current',
        title: song.getTrackName,
        album: song.albumName,
        artist: song.getTrackArtistNames,
        duration: Duration(milliseconds: song.getTrackDuration),
        extras: {'songId': song.identity},
      ),
    );
  }

  final Duration retryDelay;
  Timer? _retryTimer;
  bool _disposed = false;
  bool restoringSession = false;
  VoidCallback? onCheckpoint;
  VoidCallback? onRestoreFailure;
  bool _restoredSongPending = false;
  Duration? _initialPosition;

  List<MusicMetadata> get songs => _songs;
  bool get loading => _loading;
  bool _wantPlayback = false;
  bool _recovering = false;
  int _retryAttempt = 0;
  Duration _lastPosition = Duration.zero;
  Duration _resumePosition = Duration.zero;
  Completer<void>? _pendingSeek;
  Duration? _seekTarget;

  void _interruptSeek() {
    final pending = _pendingSeek;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  bool get recovering => _recovering;
  bool get wantsPlayback => _wantPlayback;
  Duration get displayPosition =>
      _remote?.current.position ??
      (_recovering ? _resumePosition : _lastPosition);

  void _cancelRecovery() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _recovering = false;
    _retryAttempt = 0;
  }

  void _scheduleRetry() {
    if (_disposed || !_recovering || !_wantPlayback || _retryTimer != null) {
      return;
    }
    final multiplier = 1 << _retryAttempt.clamp(0, 3);
    _retryAttempt++;
    _retryTimer = Timer(retryDelay * multiplier, () {
      _retryTimer = null;
      unawaited(
        _serialize(() async {
          if (_disposed || !_recovering || !_wantPlayback || _songs.isEmpty) {
            return;
          }
          try {
            await _load(
              logicalQueue.index,
              startPlaying: true,
              recovering: true,
            );
          } catch (_) {}
        }),
      );
    });
  }

  final Future<UriAudioSource> Function(MusicMetadata)? resolveSource;
  bool _sourceLoaded = false;
  int _sourceVersion = 0;
  final LogicalQueue logicalQueue = LogicalQueue();
  final StreamController<int?> _indices = StreamController.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<MusicMetadata> _songs = [];
  Future<void> _pending = Future.value();
  bool _loading = false;
  String? _error;
  int _errorCode = 1;
  static const serverConnectionErrorCode = 2;

  LibraryAudioHandler(
    this.player, {
    this.resolveSource,
    this.retryDelay = const Duration(seconds: 3),
  }) {
    _subscriptions.add(
      player.positionStream.listen((position) {
        if (_remote == null &&
            !_loading &&
            _sourceLoaded &&
            _pendingSeek == null &&
            !_recovering &&
            player.processingState == ProcessingState.ready) {
          if (position > Duration.zero) {
            _lastPosition = position;
            _restoredSongPending = false;
          }
        }
        _broadcast();
      }),
    );
    _subscriptions.add(player.playbackEventStream.listen((_) => _broadcast()));
    _subscriptions.add(player.playingStream.listen((_) => _broadcast()));
    _subscriptions.add(
      player.processingStateStream.distinct().listen((processing) {
        if (_remote == null &&
            processing == ProcessingState.completed &&
            player.playing &&
            !_loading) {
          unawaited(
            _serialize(() async {
              if (!player.playing ||
                  player.processingState != ProcessingState.completed) {
                return;
              }
              final next = logicalQueue.next(automatic: true);
              if (next == null) {
                await player.pause();
              } else {
                await _load(next, startPlaying: true);
              }
            }).catchError(_reportError),
          );
        }
      }),
    );
    _subscriptions.add(player.errorStream.listen(_reportError));
  }

  Stream<int?> get indexStream => _indices.stream;
  int? get currentIndex => _songs.isEmpty ? null : logicalQueue.index;

  Future<void> _serialize(Future<void> Function() action) {
    final result = _pending.then((_) async {
      try {
        await action();
      } finally {
        onCheckpoint?.call();
      }
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  void _resetQueue({int initialIndex = 0}) {
    final albums = <Object, List<int>>{};
    for (var index = 0; index < _songs.length; index++) {
      final song = _songs[index];
      final Object key =
          (song.albumName?.trim().isNotEmpty ?? false) ||
              song.remoteAlbumId != null
          ? albumIdentityOf(song)
          : index;
      albums.putIfAbsent(key, () => []).add(index);
    }
    for (final album in albums.values) {
      album.sort((a, b) {
        final comparison = compareAlbumTracks(_songs[a], _songs[b]);
        return comparison == 0 ? a.compareTo(b) : comparison;
      });
    }
    logicalQueue.reset(
      _songs.length,
      albums: albums.values.toList(),
      initialIndex: initialIndex,
    );
  }

  Future<void> setSongs(List<MusicMetadata> songs, {bool preload = true}) {
    _restoredSongPending = false;
    _interruptSeek();
    _wantPlayback = false;
    _cancelRecovery();
    return _serialize(() async {
      final hadSongs = _songs.isNotEmpty;
      if (hadSongs) await player.pause();
      _songs = List.unmodifiable(songs);
      _resetQueue();
      _initialPosition = null;
      _lastPosition = Duration.zero;
      if (songs.isEmpty) {
        _error = null;
        if (hadSongs) await player.clearAudioSources();
        _sourceLoaded = false;
        mediaItem.add(null);
        _indices.add(null);
        _broadcast();
      } else {
        await _load(0, preload: preload);
      }
    });
  }

  Future<void> restoreSongs(
    List<MusicMetadata> songs, {
    required int index,
    required Duration position,
    bool resetOnFailure = false,
  }) async {
    await setSongs(songs, preload: false);
    if (songs.isEmpty) return;
    await _serialize(() async {
      logicalQueue.index = index;
      _restoredSongPending = resetOnFailure;
      _initialPosition = position;
      _lastPosition = position;
      _indices.add(index);
      _broadcast();
    });
  }

  Future<void> select(int index, {bool startPlaying = true}) {
    _restoredSongPending = false;
    if (index < 0 || index >= _songs.length) return Future.value();
    _interruptSeek();
    _wantPlayback = startPlaying;
    _cancelRecovery();
    _sourceVersion++;
    return _serialize(() async {
      if (index < 0 || index >= _songs.length) return;
      await _load(index, startPlaying: startPlaying);
    });
  }

  Future<void> reconcileSongs(List<MusicMetadata> songs) async {
    if (_remote != null) {
      await _remote!.stop();
      await setSongs(songs, preload: false);
      return;
    }
    final retainedIds = songs.map((song) => song.identity).toSet();
    final current = _songs.isEmpty ? null : _songs[logicalQueue.index];
    final removedCurrent =
        current != null && !retainedIds.contains(current.identity);
    final removedLoadingSource =
        _loading &&
        _songs.any(
          (song) => song.isSubsonic && !retainedIds.contains(song.identity),
        );
    if (removedCurrent || removedLoadingSource) {
      _interruptSeek();
      _wantPlayback = false;
      _cancelRecovery();
      _sourceVersion++;
      await player.stop();
    }
    await _serialize(() async {
      final identity = _songs.isEmpty
          ? null
          : _songs[logicalQueue.index].identity;
      final nextIndex = songs.indexWhere((song) => song.identity == identity);
      _songs = List.unmodifiable(songs);
      _resetQueue(initialIndex: nextIndex < 0 ? 0 : nextIndex);
      if (nextIndex >= 0) {
        _indices.add(nextIndex);
      } else {
        _initialPosition = null;
        _lastPosition = Duration.zero;
        await player.stop();
        await player.clearAudioSources();
        _sourceLoaded = false;
        mediaItem.add(null);
        _indices.add(songs.isEmpty ? null : 0);
      }
      _broadcast();
    });
  }

  Future<void> _load(
    int index, {
    bool startPlaying = false,
    bool preload = true,
    bool recovering = false,
    Duration initialPosition = Duration.zero,
  }) async {
    if (_remote != null) {
      logicalQueue.index = index;
      _error = null;
      _remote!.configure(_songs, logicalQueue.indices, index);
      _indices.add(index);
      _publishRemoteMetadata();
      if (preload) await _remote!.select(index, play: startPlaying);
      _broadcast();
      return;
    }
    if (!recovering) {
      _cancelRecovery();
      _initialPosition = null;
      _lastPosition = initialPosition;
    }
    _loading = true;
    final version = _sourceVersion;
    _error = null;
    try {
      if (!preload) {
        _sourceLoaded = false;
        logicalQueue.index = index;
        _indices.add(index);
        mediaItem.add(null);
        return;
      }
      await player.pause();
      // just_audio_web caches the playlist by ID, which setAudioSource reuses.
      // Release that backend before replacing its source to avoid replaying
      // the first track. https://github.com/ryanheise/just_audio/issues/1513
      if (kIsWeb) await player.stop();
      _sourceLoaded = false;
      // Commit identity before resolution, including failures on another track.
      logicalQueue.index = index;
      _indices.add(index);
      _initialPosition = recovering ? _resumePosition : initialPosition;
      final source = resolveSource == null
          ? _songs[index].toAudioSource() as UriAudioSource
          : await resolveSource!(_songs[index]);
      if (version != _sourceVersion) return;
      final item = source.tag as MediaItem;
      mediaItem.add(
        item.copyWith(
          id: 'classipod-current',
          extras: {...?item.extras, 'songId': item.id},
        ),
      );
      await player.setAudioSource(
        source,
        preload: preload,
        initialPosition: recovering ? _resumePosition : initialPosition,
      );
      if (version != _sourceVersion) return;
      _sourceLoaded = true;
      _initialPosition = null;
      if (recovering) _lastPosition = _resumePosition;
      _cancelRecovery();
      if (startPlaying && _wantPlayback) _startPlayer();
    } catch (error) {
      if (version != _sourceVersion) return;
      _reportError(error);
      throw StateError(_error ?? 'Playback failed');
    } finally {
      _loading = false;
      _broadcast();
    }
  }

  void _startPlayer() {
    _error = null;
    _broadcast();
    unawaited(player.play().catchError(_reportError));
  }

  @override
  Future<void> play() {
    if (_remote != null) return _serialize(() => _remote!.play());
    _wantPlayback = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    return _serialize(() async {
      if (_songs.isEmpty) return;
      if (_recovering) {
        await _load(logicalQueue.index, startPlaying: true, recovering: true);
        return;
      }
      if (!_sourceLoaded) {
        await _load(
          logicalQueue.index,
          startPlaying: true,
          initialPosition: _initialPosition ?? Duration.zero,
        );
        return;
      }
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
        _lastPosition = Duration.zero;
      }
      _startPlayer();
    });
  }

  @override
  Future<void> pause() {
    if (_remote != null) return _serialize(() => _remote!.pause());
    _interruptSeek();
    _wantPlayback = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    return _serialize(() async {
      await player.pause();
      _broadcast();
    });
  }

  @override
  Future<void> stop() {
    if (_remote != null) return _serialize(() => _remote!.stop());
    _interruptSeek();
    _wantPlayback = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _sourceVersion++;
    return _serialize(() async {
      await player.stop();
      _broadcast();
    });
  }

  @override
  Future<void> seek(Duration position) {
    if (_remote != null) return _serialize(() => _remote!.seek(position));
    _interruptSeek();
    final interrupted = Completer<void>();
    _pendingSeek = interrupted;
    return _serialize(() async {
      try {
        if (interrupted.isCompleted) return;
        _lastPosition = position;
        _seekTarget = position;
        if (_recovering) {
          _resumePosition = position;
          _broadcast();
        } else if (!_sourceLoaded) {
          _initialPosition = position;
          _broadcast();
        } else {
          await Future.any<void>([player.seek(position), interrupted.future]);
        }
      } catch (error) {
        if (!interrupted.isCompleted) _reportError(error);
      } finally {
        if (identical(_pendingSeek, interrupted)) {
          _pendingSeek = null;
          _seekTarget = null;
        }
      }
    });
  }

  @override
  Future<void> skipToNext() {
    final initialIndex = logicalQueue.index;
    var next = logicalQueue.next();
    if (_remote != null) {
      for (
        var count = 0;
        next != null && !_songs[next].isSubsonic && count < _songs.length;
        count++
      ) {
        logicalQueue.index = next;
        next = logicalQueue.next();
      }
      if (next != null && !_songs[next].isSubsonic) next = null;
      logicalQueue.index = initialIndex;
    }
    return next == null
        ? Future.value()
        : select(next, startPlaying: _wantPlayback);
  }

  @override
  Future<void> skipToPrevious() {
    if ((_remote == null && _sourceLoaded && !_recovering
            ? player.position
            : displayPosition) >
        const Duration(seconds: 3)) {
      return seek(Duration.zero);
    }
    final initialIndex = logicalQueue.index;
    var previous = logicalQueue.previous();
    if (_remote != null) {
      for (
        var count = 0;
        previous != null &&
            !_songs[previous].isSubsonic &&
            count < _songs.length;
        count++
      ) {
        logicalQueue.index = previous;
        previous = logicalQueue.previous();
      }
      if (previous != null && !_songs[previous].isSubsonic) previous = null;
      logicalQueue.index = initialIndex;
    }
    return previous == null
        ? Future.value()
        : select(previous, startPlaying: _wantPlayback);
  }

  @override
  Future<void> skipToQueueItem(int index) => select(index);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    logicalQueue.loopMode = switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => LoopMode.all,
      AudioServiceRepeatMode.none => LoopMode.off,
    };
    if (_remote != null) await _remote!.setRepeat(logicalQueue.loopMode);
    _broadcast();
    onCheckpoint?.call();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    logicalQueue.setShuffle(PlaybackShuffleMode.fromAudioService(shuffleMode));
    if (_remote != null) await _remote!.setOrder(logicalQueue.indices);
    _broadcast();
    onCheckpoint?.call();
  }

  void _reportError(Object error) {
    if (_remote != null) return;
    if (_restoredSongPending && onRestoreFailure != null) {
      _restoredSongPending = false;
      _sourceVersion++;
      _wantPlayback = false;
      _cancelRecovery();
      _interruptSeek();
      _sourceLoaded = false;
      _initialPosition = null;
      _lastPosition = Duration.zero;
      _error = null;
      onRestoreFailure!();
      _broadcast();
      return;
    }
    final remote = _songs.isNotEmpty && _songs[logicalQueue.index].isSubsonic;
    final message = error.toString().toLowerCase();
    final blockedHttp =
        message.contains('cleartext') ||
        message.contains('http playback is blocked') ||
        message.contains('app transport security');
    final connectionFailed =
        remote &&
        !blockedHttp &&
        ((error is PlayerException &&
                error.code == 0 &&
                message.contains('source error')) ||
            message.contains('connectexception') ||
            message.contains('failed to connect') ||
            message.contains('socketexception') ||
            message.contains('unknownhost') ||
            message.contains('failed host lookup') ||
            message.contains('network is unreachable') ||
            message.contains('network request failed') ||
            message.contains('network connection was lost') ||
            message.contains('internet connection appears to be offline') ||
            message.contains('timed out') ||
            message.contains('connection reset') ||
            message.contains('server connection lost') ||
            RegExp(r'(response code|status code|http)[^0-9]*5[0-9]{2}')
                .hasMatch(message) ||
            (error is PlayerException &&
                [-1001, -1003, -1004, -1005, -1009].contains(error.code)));
    _errorCode = connectionFailed ? serverConnectionErrorCode : 1;
    _error = connectionFailed
        ? 'Server connection lost. Reconnecting…'
        : blockedHttp
        ? 'HTTP playback is blocked by platform security. '
              'Use an HTTPS server URL in Library Settings.'
        : remote
        ? 'Subsonic playback failed. Check your connection '
              'and sign in from Library Settings.'
        : error.toString();
    if (connectionFailed) {
      if (!_recovering) {
        if (_seekTarget != null || _initialPosition != null) {
          _lastPosition = _seekTarget ?? _initialPosition!;
        } else if (player.position > _lastPosition) {
          _lastPosition = player.position;
        }
        _resumePosition = _lastPosition;
      }
      _recovering = true;
      _sourceLoaded = false;
      _scheduleRetry();
    } else {
      _cancelRecovery();
    }
    _interruptSeek();
    _broadcast();
  }

  void _broadcast() {
    final remote = _remote?.current;
    if (remote != null) {
      _lastPosition = remote.position;
      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            remote.playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: remote.error != null
              ? AudioProcessingState.error
              : remote.loading
              ? AudioProcessingState.loading
              : AudioProcessingState.ready,
          playing: remote.playing,
          updatePosition: remote.position,
          errorCode: remote.error == null ? null : 3,
          errorMessage: remote.error == null ? null : 'Sonos playback unavailable. Check the speaker connection and server address.',
          repeatMode: switch (logicalQueue.loopMode) {
            LoopMode.off => AudioServiceRepeatMode.none,
            LoopMode.one => AudioServiceRepeatMode.one,
            LoopMode.all => AudioServiceRepeatMode.all,
          },
          shuffleMode: logicalQueue.shuffleMode.audioServiceMode,
        ),
      );
      return;
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          (_recovering ? _wantPlayback : player.playing)
              ? MediaControl.pause
              : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _recovering
            ? (_wantPlayback
                  ? AudioProcessingState.buffering
                  : AudioProcessingState.ready)
            : _error != null
            ? AudioProcessingState.error
            : switch (player.processingState) {
                ProcessingState.idle => AudioProcessingState.idle,
                ProcessingState.loading => AudioProcessingState.loading,
                ProcessingState.buffering => AudioProcessingState.buffering,
                ProcessingState.ready => AudioProcessingState.ready,
                ProcessingState.completed => AudioProcessingState.completed,
              },
        errorCode: _recovering || _error == null ? null : _errorCode,
        errorMessage: _recovering ? null : _error,
        playing: _recovering ? _wantPlayback : player.playing,
        updatePosition: displayPosition,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        repeatMode: switch (logicalQueue.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: logicalQueue.shuffleMode.audioServiceMode,
      ),
    );
  }

  Future<void> dispose() async {
    onCheckpoint?.call();
    onCheckpoint = null;
    onRestoreFailure = null;
    _disposed = true;
    _interruptSeek();
    _wantPlayback = false;
    _sourceVersion++;
    _cancelRecovery();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _remoteSubscription?.cancel();
    await _indices.close();
  }
}
