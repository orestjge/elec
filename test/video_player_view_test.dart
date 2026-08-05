import 'package:elec/src/ui/video_player_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player.dart';

/// プレーヤー単体を置く（ホストごしの挙動＝全画面・小窓の行き来は
/// `mini_player_test.dart` で見る）。
Widget _standalone({
  required Uri url,
  VoidCallback? onClose,
  VoidCallback? onMinimize,
  ValueChanged<Uri>? onOpenExternally,
}) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: VideoPlayerView(
      url: url,
      onClose: onClose ?? () {},
      onMinimize: onMinimize ?? () {},
      onOpenExternally: onOpenExternally,
    ),
  ),
);

void main() {
  final original = VideoPlayerPlatform.instance;

  tearDown(() {
    VideoPlayerPlatform.instance = original;
    VideoPlayerView.debugResetMuted();
  });

  testWidgets('タップは再生を止めず操作一式を出す。止めるのは中央ボタン', (tester) async {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();

    await tester.pumpWidget(
      _standalone(url: Uri.parse('https://example.com/a.mp4')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 操作を出していない間は映像に何も重ねない。下端の細い進捗線だけ。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    // タップで操作が出る。**再生は止まらない**ので中央ボタンは一時停止。
    await tester.tap(find.byType(AspectRatio));
    await tester.pump();

    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // ここが肝——**流したまま**閉じる・小さくするに手が届く。
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.repeat), findsOneWidget);

    // 中央ボタンで一時停止。止めている間は操作を引っ込めない。
    await tester.tap(find.byIcon(Icons.pause_circle_filled));
    await tester.pump();
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

    // 操作の無いところをもう一度タップすると引っ込む（再生状態は変えない）。
    // 中央は一時停止ボタンが乗っているので、そこは外して押す。
    await tester.tapAt(const Offset(600, 150));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('再生中に出した操作は数秒で引っ込む', (tester) async {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();

    await tester.pumpWidget(
      _standalone(url: Uri.parse('https://example.com/a.mp4')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byType(AspectRatio));
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);

    // 映像を隠し続けない。
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('上スワイプで終了、下スワイプは小窓へ（再生中でも抜けられる）', (tester) async {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    var closed = 0;
    var minimized = 0;

    await tester.pumpWidget(
      _standalone(
        url: Uri.parse('https://example.com/a.mp4'),
        onClose: () => closed++,
        onMinimize: () => minimized++,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ボタンを出さずに（＝見ている流れを止めずに）畳める近道。
    await tester.drag(find.byType(AspectRatio), const Offset(0, 160));
    await tester.pump(const Duration(milliseconds: 300));
    expect((closed, minimized), (0, 1));

    // 上は終了。指の向きと結果を合わせてある（下へ払うと下へ縮む）。
    await tester.drag(find.byType(AspectRatio), const Offset(0, -160));
    await tester.pump(const Duration(milliseconds: 300));
    expect((closed, minimized), (1, 1));

    // 届かない量では何も起きない。
    await tester.drag(find.byType(AspectRatio), const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 300));
    expect((closed, minimized), (1, 1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('小窓では操作を重ねず、進捗線だけを出す', (tester) async {
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 112,
            child: VideoPlayerView(
              url: Uri.parse('https://example.com/a.mp4'),
              mini: true,
              onClose: () {},
              onMinimize: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AspectRatio), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 小窓の操作（移動・全画面へ戻す・閉じる）はホスト側が持つので何も出さない。
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byType(Slider), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ミュートを切り替えられ、次に開く動画にも引き継ぐ', (tester) async {
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      _standalone(url: Uri.parse('https://example.com/movie.mp4')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ミュートは（ヘッダーではなく）タップで出る操作バーにある。
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
      _standalone(url: Uri.parse('https://example.com/next.mp4')),
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
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform(failOnCreate: true);
    final url = Uri.parse('https://example.com/broken.mp4');
    final opened = <Uri>[];

    await tester.pumpWidget(
      _standalone(url: url, onOpenExternally: opened.add),
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
