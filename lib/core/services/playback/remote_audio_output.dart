import 'package:classipod/core/models/music_metadata.dart';
import 'package:just_audio/just_audio.dart';

class RemotePlaybackState {
  const RemotePlaybackState({
    this.index = 0,
    this.position = Duration.zero,
    this.playing = false,
    this.loading = false,
    this.volume = 0,
    this.error,
  });
  final int index;
  final Duration position;
  final bool playing;
  final bool loading;
  final double volume;
  final String? error;
}

abstract class RemoteAudioOutput {
  RemotePlaybackState get current;
  Stream<RemotePlaybackState> get changes;
  void configure(List<MusicMetadata> songs, List<int> order, int index);
  Future<void> select(int index, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setOrder(List<int> order);
  Future<void> setRepeat(LoopMode mode);
  Future<void> setVolume(double volume);
}
