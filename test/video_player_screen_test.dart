import 'dart:async';

import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/video_player_screen.dart';
import 'package:elec/src/ui/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 動画プラグインの代わりにテスト内で完結するフェイク。
///
/// [failOnCreate] を立てるとネイティブ生成の失敗（非対応コーデック・到達不可）を
/// 再現する。成功時は購読と同時に initialized イベントを 1 度だけ流す。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  _FakeVideoPlayerPlatform({this.failOnCreate = false});

  final bool failOnCreate;

  /// setVolume に渡された値の履歴（ミュート操作の確認用）。
  final List<double> volumes = [];

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => 1;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (failOnCreate) throw _CreateFailure();
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
class _CreateFailure implements Exception {}

void main() {
  final original = VideoPlayerPlatform.instance;

  tearDown(() {
    VideoPlayerPlatform.instance = original;
    VideoThumbnails.debugTargetPlatform = null;
    VideoPlayerScreen.debugResetMuted();
  });

  testWidgets('動画サムネのタップはブラウザではなくアプリ内プレーヤーを開く', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    // サムネイル生成を挟まない（非対応プラットフォーム）状態でタップを見る。
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
            onOpenVideoExternally: opened.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(VideoPlayerScreen), findsOneWidget);
    // ブラウザへは飛ばさない（逃げ道は止めたときの操作バーに残す）。
    expect(opened, isEmpty);
    // 再生開始後は初期化スピナーが消え、再生面が出ている。
    expect(find.byType(AspectRatio), findsOneWidget);
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();
    expect(find.byIcon(Icons.open_in_browser), findsOneWidget);

    // 再生位置ポーリングのタイマーを止めるため、ツリーを畳んでから抜ける。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('再生中は進捗線だけ、タップで止めると操作一式を出す', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerScreen(url: Uri.parse('https://example.com/a.mp4')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 再生中は映像に何も重ねない。下端の細い進捗線だけ（閉じるも出さない）。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    // 映像のどこをタップしても一時停止する。
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // ヘッダーの代わりに、止めたときだけ閉じる・補助操作が出る。
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.repeat), findsOneWidget);

    // 中央ボタンで再生に戻ると、また進捗線だけになる。
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();

    expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('上下スワイプで閉じる（再生中でも抜けられる）', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(VideoPlayerScreen), findsOneWidget);

    // 再生中は閉じるボタンを出さないので、スワイプが唯一の逃げ道になる。
    await tester.drag(find.byType(AspectRatio), const Offset(0, 160));
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlayerScreen), findsNothing);
  });

  testWidgets('ミュートを切り替えられ、次に開く動画にも引き継ぐ', (tester) async {
    final platform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    final url = Uri.parse('https://example.com/movie.mp4');

    await tester.pumpWidget(MaterialApp(home: VideoPlayerScreen(url: url)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ミュートは（ヘッダーではなく）止めたときの操作バーにある。
    expect(platform.volumes.last, 1);
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(platform.volumes.last, 0);

    // 別の動画を開いてもミュートのままにする。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerScreen(url: Uri.parse('https://example.com/next.mp4')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(platform.volumes.last, 0);
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('再生できないときはブラウザで開く逃げ道を出す', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform(failOnCreate: true);
    final url = Uri.parse('https://example.com/broken.mp4');
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerScreen(url: url, onOpenExternally: opened.add),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('再生できませんでした'), findsOneWidget);
    await tester.tap(find.text('ブラウザで開く'));
    expect(opened, [url]);
  });

  test('再生時間は m:ss、1 時間以上は h:mm:ss で表す', () {
    expect(formatVideoTime(const Duration(seconds: 7)), '0:07');
    expect(formatVideoTime(const Duration(minutes: 3, seconds: 5)), '3:05');
    expect(
      formatVideoTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
