import 'package:elec/src/ui/mini_player.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/video_player_view.dart';
import 'package:elec/src/ui/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player.dart';

/// 実アプリと同じ組み方（`MaterialApp.builder` にホストを置く）で、下に
/// スレの代わりの画面を敷く。[taps] は「後ろの画面が触れるか」を測るための counter。
Widget _app(List<String> taps) => MaterialApp(
  builder: (context, child) =>
      MiniPlayerHost(child: child ?? const SizedBox.shrink()),
  home: Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () => taps.add('back'),
          child: const Text('後ろのボタン'),
        ),
        PostImages(
          urls: const [],
          videoUrls: [Uri.parse('https://example.com/movie.mp4')],
        ),
      ],
    ),
  ),
);

/// 映像そのもの（プレーヤーの中の再生面）。小窓化しても同じものが残る。
final _surface = find.descendant(
  of: find.byType(VideoPlayerView),
  matching: find.byType(AspectRatio),
);

/// 全画面⇔小窓の移動を終わらせる。`pumpAndSettle` は使わない——再生中は
/// `video_player` が位置ポーリングのタイマーを回し続けるので落ち着かない。
Future<void> _settleMove(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  final original = VideoPlayerPlatform.instance;

  setUp(() {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    // サムネイル生成を挟まない（非対応プラットフォーム）状態でタップを見る。
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;
  });

  tearDown(() {
    VideoPlayerPlatform.instance = original;
    VideoThumbnails.debugTargetPlatform = null;
    VideoPlayerView.debugResetMuted();
    MiniPlayerController.shared.debugReset();
  });

  testWidgets('動画サムネのタップはブラウザではなくアプリ内プレーヤーを開く', (tester) async {
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            MiniPlayerHost(child: child ?? const SizedBox.shrink()),
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
    await _settleMove(tester);

    expect(find.byType(VideoPlayerView), findsOneWidget);
    expect(MiniPlayerController.shared.mode, MiniPlayerMode.fullscreen);
    // ブラウザへは飛ばさない（逃げ道は止めたときの操作バーに残す）。
    expect(opened, isEmpty);
    // 再生開始後は初期化スピナーが消え、再生面が出ている。
    expect(_surface, findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('小窓へ落としてもプレーヤーは作り直されず、後ろのスレを触れる', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(_app(taps));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);

    // 全画面のプレーヤーが後ろを覆っているので、後ろのボタンは押せない。
    final playing = tester.element(find.byType(VideoPlayerView));
    expect(taps, isEmpty);

    // 下スワイプで小窓へ。
    await tester.drag(_surface, const Offset(0, 160), warnIfMissed: false);
    await _settleMove(tester);
    expect(MiniPlayerController.shared.mode, MiniPlayerMode.mini);

    // **ここが肝**: Element が同じ＝State も VideoPlayerController も同じもので、
    // 再生が頭に戻っていない。作り直していたら別の Element になる。
    expect(tester.element(find.byType(VideoPlayerView)), same(playing));

    // 小窓の外＝スレはそのまま触れる。
    await tester.tap(find.text('後ろのボタン'));
    await tester.pump();
    expect(taps, ['back']);

    // 小窓をタップすると全画面へ戻る（Element は変わらない）。
    await tester.tap(find.byType(VideoPlayerView), warnIfMissed: false);
    await _settleMove(tester);
    expect(MiniPlayerController.shared.mode, MiniPlayerMode.fullscreen);
    expect(tester.element(find.byType(VideoPlayerView)), same(playing));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('再生を止めずに▼で小窓へ落とせる', (tester) async {
    await tester.pumpWidget(_app([]));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);
    final playing = tester.element(find.byType(VideoPlayerView));

    // タップは再生を止めず操作を出すだけ。だから流したまま▼へ手が届く。
    await tester.tap(_surface, warnIfMissed: false);
    await tester.pump();
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await _settleMove(tester);

    expect(MiniPlayerController.shared.mode, MiniPlayerMode.mini);
    expect(tester.element(find.byType(VideoPlayerView)), same(playing));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('全画面で戻ると終了ではなく小窓になる', (tester) async {
    await tester.pumpWidget(_app([]));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);
    expect(MiniPlayerController.shared.mode, MiniPlayerMode.fullscreen);

    // 全画面の間だけ積んである「戻る」受け用のルートが外れる。
    await tester.binding.handlePopRoute();
    await _settleMove(tester);

    expect(MiniPlayerController.shared.mode, MiniPlayerMode.mini);
    expect(find.byType(VideoPlayerView), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('小窓の×で終わる', (tester) async {
    await tester.pumpWidget(_app([]));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);
    await tester.drag(_surface, const Offset(0, 160), warnIfMissed: false);
    await _settleMove(tester);

    // 小窓の×はホスト側が出している（プレーヤー本体は映像だけ）。
    await tester.tap(find.byIcon(Icons.close));
    await _settleMove(tester);

    expect(find.byType(VideoPlayerView), findsNothing);
    expect(MiniPlayerController.shared.media, isNull);
  });

  testWidgets('小窓はドラッグで動かせ、画面の外へは出ない', (tester) async {
    await tester.pumpWidget(_app([]));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);
    await tester.drag(_surface, const Offset(0, 160), warnIfMissed: false);
    await _settleMove(tester);

    final before = tester.getTopLeft(find.byType(VideoPlayerView));
    // 左下へ大きく引く。行き過ぎたぶんは画面内に丸められる。
    await tester.drag(
      find.byType(VideoPlayerView),
      const Offset(-400, 900),
      warnIfMissed: false,
    );
    await _settleMove(tester);

    final after = tester.getRect(find.byType(VideoPlayerView));
    expect(after.left, lessThan(before.dx));
    expect(after.left, greaterThanOrEqualTo(0));
    expect(
      after.bottom,
      lessThanOrEqualTo(tester.getSize(find.byType(MiniPlayerHost)).height),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('別の動画を開くと差し替わり、全画面から始まる', (tester) async {
    await tester.pumpWidget(_app([]));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);
    final first = tester.element(find.byType(VideoPlayerView));

    await tester.drag(_surface, const Offset(0, 160), warnIfMissed: false);
    await _settleMove(tester);
    expect(MiniPlayerController.shared.mode, MiniPlayerMode.mini);

    // 小窓のまま、スレ側でもう 1 本開く。
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _settleMove(tester);

    expect(MiniPlayerController.shared.mode, MiniPlayerMode.fullscreen);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    // 別のものになっている（前のプレーヤーは捨てられ、再生も止まる）。
    expect(tester.element(find.byType(VideoPlayerView)), isNot(same(first)));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
