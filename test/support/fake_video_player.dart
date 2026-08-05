/// 動画プラグインの代わりにテスト内で完結するフェイク。
///
/// `video_player` はネイティブ実装を呼ぶので、widget テストでは
/// [VideoPlayerPlatform.instance] をこれに差し替える。
library;

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// [failOnCreate] を立てるとネイティブ生成の失敗（非対応コーデック・到達不可）を
/// 再現する。成功時は購読と同時に initialized イベントを 1 度だけ流す。
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  FakeVideoPlayerPlatform({this.failOnCreate = false});

  final bool failOnCreate;

  /// setVolume に渡された値の履歴（ミュート操作の確認用）。
  final List<double> volumes = [];

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => 1;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (failOnCreate) throw CreateFailure();
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(640, 360),
    );
  }

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      volumes.add(volume);

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.expand();

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

/// ネイティブ側の生成失敗を表す例外（プラグインの PlatformException 相当）。
class CreateFailure implements Exception {}
