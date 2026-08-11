import 'package:elec/src/ui/embed_player.dart';
import 'package:elec/src/ui/embed_urls.dart';
import 'package:elec/src/ui/mini_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugEmbedPlayerTargetPlatform = null);

  testWidgets('macOS では WebView を開かずブラウザへ回す', (tester) async {
    debugEmbedPlayerTargetPlatform = TargetPlatform.macOS;
    final video = embedVideosIn('https://youtu.be/dQw4w9WgXcQ').single;
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                openEmbedPlayer(context, video, onOpenExternally: opened.add),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(opened, [video.url]);
    expect(find.byType(EmbedPlayerView), findsNothing);
    // ミニプレーヤー側にも何も渡らない（小窓が空で残らないこと）。
    expect(MiniPlayerController.shared.media, isNull);
  });

  test('YouTube の WebView リクエストには Referer を付ける', () {
    final video = embedVideosIn('https://youtu.be/dQw4w9WgXcQ').single;

    expect(embedPlayerRequestHeaders(video), {
      'Referer': 'https://io.github.orestjge.elec/',
    });
  });

  test('ニコニコの WebView リクエストには追加ヘッダーを付けない', () {
    final video = embedVideosIn('https://www.nicovideo.jp/watch/sm9').single;

    expect(embedPlayerRequestHeaders(video), isEmpty);
  });

  group('上下スワイプ（EmbedSwipeArea）', () {
    late List<String> done;

    // 中身は WebView の代わり。指を取り合う相手として、タップと横ドラッグを
    // 受け取る子を置く（本物の WebView も同じように指を自分のものにする）。
    Widget host({required bool enabled, Widget? child}) => MaterialApp(
      home: EmbedSwipeArea(
        enabled: enabled,
        onMinimize: () => done.add('minimize'),
        onClose: () => done.add('close'),
        child:
            child ??
            const ColoredBox(color: Colors.black, child: SizedBox.expand()),
      ),
    );

    setUp(() => done = []);

    testWidgets('下へ払うと小窓へ落ちる', (tester) async {
      await tester.pumpWidget(host(enabled: true));

      await tester.drag(find.byType(EmbedSwipeArea), const Offset(0, 150));
      await tester.pumpAndSettle();

      expect(done, ['minimize']);
    });

    testWidgets('上へ払うと終わる', (tester) async {
      await tester.pumpWidget(host(enabled: true));

      await tester.drag(find.byType(EmbedSwipeArea), const Offset(0, -150));
      await tester.pumpAndSettle();

      expect(done, ['close']);
    });

    testWidgets('距離が足りなければ元に戻る', (tester) async {
      await tester.pumpWidget(host(enabled: true));

      await tester.drag(find.byType(EmbedSwipeArea), const Offset(0, 60));
      await tester.pumpAndSettle();

      expect(done, isEmpty);
    });

    testWidgets('距離が足りなくても速く払えば効く', (tester) async {
      await tester.pumpWidget(host(enabled: true));

      await tester.fling(
        find.byType(EmbedSwipeArea),
        const Offset(0, 60),
        1000,
      );
      await tester.pumpAndSettle();

      expect(done, ['minimize']);
    });

    testWidgets('横に滑り出した指は WebView に譲る', (tester) async {
      var dragged = 0;
      await tester.pumpWidget(
        host(
          enabled: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (_) => dragged++,
            child: const SizedBox.expand(),
          ),
        ),
      );

      // 横へ出てから縦にも振れる指。向きは滑り出しで決まるので畳まない。
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(0, 200));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(done, isEmpty);
      expect(dragged, 1);
    });

    testWidgets('タップは中身（WebView）にそのまま届く', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        host(
          enabled: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => tapped++,
            child: const SizedBox.expand(),
          ),
        ),
      );

      await tester.tap(find.byType(EmbedSwipeArea));
      await tester.pumpAndSettle();

      expect(tapped, 1);
      expect(done, isEmpty);
    });

    testWidgets('見張っていない（小窓・ニコニコ）ときは何も起きない', (tester) async {
      await tester.pumpWidget(host(enabled: false));

      await tester.drag(find.byType(EmbedSwipeArea), const Offset(0, 150));
      await tester.drag(find.byType(EmbedSwipeArea), const Offset(0, -150));
      await tester.pumpAndSettle();

      expect(done, isEmpty);
    });
  });
}
