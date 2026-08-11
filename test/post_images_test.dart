import 'dart:convert';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/gestures.dart';
import 'package:elec/src/ui/embed_urls.dart';
import 'package:elec/src/ui/media_url_panel.dart';
import 'package:elec/src/ui/mini_player.dart';
import 'package:elec/src/ui/nico_thumbnail.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/remote_image.dart';
import 'package:elec/src/ui/video_player_view.dart';
import 'package:elec/src/ui/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player.dart';

/// 全画面ビューアは Navigator の外（`MaterialApp.builder` の層）に載るので、
/// 実アプリと同じくホストを噛ませる（`mini_player.dart` 参照）。
Widget _host(BuildContext context, Widget? child) =>
    MiniPlayerHost(child: child ?? const SizedBox.shrink());

/// 1x1 の透過 PNG。Image.memory がデコードできる最小の有効画像。
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwAD'
  'hgGAWjR9awAAAABJRU5ErkJggg==',
);

/// [width]×[height] の JPEG。動画から切り出したフレームの代わり。
Uint8List _frame(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(40, 90, 200));
  return Uint8List.fromList(img.encodeJpg(image, quality: 70));
}

/// ニコニコのサムネ解決をテスト内で完結させるフェイク。
class _StubFetcher implements HttpFetcher {
  @override
  Future<FetchResponse> get(Uri url, {Map<String, String> headers = const {}}) {
    return Future.value(
      FetchResponse(
        statusCode: 200,
        bodyBytes: utf8.encode(
          '<thumbnail_url>https://nicovideo.cdn.nimg.jp/thumbnails/9/9'
          '</thumbnail_url>',
        ),
      ),
    );
  }
}

/// 最初のサムネイルからビューアを開き、**絵をタップして操作一式（題名バー・◀▶）を
/// 出す**。既定では何も重ならないので、題名やボタンを見るテストはこれで開ける。
Future<void> _openViewer(WidgetTester tester) async {
  await tester.tap(find.byType(GestureDetector).first);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(PageView));
  await tester.pumpAndSettle();
}

/// [finder] が指の届くところ（重なりのいちばん上）に出ているか。
///
/// 見えていること（`findsOneWidget`）だけでは足りない場面のための物差し。
/// 別の層に隠れていても組み立て自体はされるので、当たり判定まで見ないと
/// 「出ているのに押せない」を取り逃がす。
bool _isTappable(WidgetTester tester, Finder finder) {
  final render = tester.renderObject(finder);
  final hits = tester.hitTestOnBinding(tester.getCenter(finder));
  return hits.path.any((entry) => identical(entry.target, render));
}

/// 全画面ビューアの表示中の画像を2本指のピンチで拡大する。
Future<void> _pinchZoom(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(PageView));
  final left = await tester.startGesture(center - const Offset(20, 0));
  final right = await tester.startGesture(center + const Offset(20, 0));
  await tester.pump();
  await left.moveBy(const Offset(-60, 0));
  await right.moveBy(const Offset(60, 0));
  await tester.pump();
  await left.up();
  await right.up();
  await tester.pumpAndSettle();
}

/// 全画面ビューアの現在の拡大率。
double _viewerScale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

/// 全画面ビューアが今どれだけの大きさでデコードしようとしているか（物理ピクセル）。
Size _viewerDecodeTarget(WidgetTester tester) {
  final image = tester.widget<Image>(
    find.descendant(of: find.byType(PageView), matching: find.byType(Image)),
  );
  return (image.image as RemoteImage).target;
}

/// 2本指スクロール（デスクトップではドラッグの代わりにこれが来る）を送る。
/// [kind] を mouse にするとホイール相当。
Future<void> _scroll(
  WidgetTester tester,
  Offset delta, {
  int times = 1,
  PointerDeviceKind kind = PointerDeviceKind.trackpad,
}) async {
  final center = tester.getCenter(find.byType(PageView));
  for (var i = 0; i < times; i++) {
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, kind: kind, scrollDelta: delta),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  final originalVideoGenerator = VideoThumbnails.generator;

  // ビューアは 1 つしかない（[MiniPlayerController.shared]）ので、テストごとに
  // 開きっぱなしを持ち越さない。
  tearDown(MiniPlayerController.shared.debugReset);

  // 覚えた縦横比も持ち越さない。残っているとサムネイルが正方形でなくなり、
  // 位置で拾うテストが取り違える。
  tearDown(ImageAspect.shared.reset);

  testWidgets('同一レス内の複数画像をビューアで巡回できる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);
    expect(find.text('1/3  a.jpg'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('1/3  a.jpg'), findsOneWidget);
  });

  testWidgets('画像ビューアの「ブラウザで開く」は表示中の画像を渡す', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
    ];
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: urls, onOpenImageExternally: opened.add),
        ),
      ),
    );

    await _openViewer(tester);

    await tester.tap(find.byIcon(Icons.open_in_browser));
    await tester.pump();
    expect(opened, [urls.first]);

    // ページを送ったら、その先の画像を渡す。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.open_in_browser));
    await tester.pump();
    expect(opened, [urls.first, urls.last]);
  });

  testWidgets('ビューアは既定で絵に何も重ねず、タップで出し入れする', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

    // ◀▶ を絵の左右に置きっぱなしにすると、送るのは一瞬なのに見ている間じゅう
    // 邪魔になる。開いた直後は絵だけ。
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.text('1/2  a.jpg'), findsNothing);

    // 絵をタップすると一式出る（動画のページと同じ規則）。
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('1/2  a.jpg'), findsOneWidget);

    // 送っても出したままにする。静止画には「流れている」状態が無いので、
    // 時間で引っ込めると見比べている最中に消えてしまう。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('2/2  b.png'), findsOneWidget);

    // もう一度タップで引っ込む。ビューアは開いたまま。
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(MiniPlayerController.shared.media, isNotNull);
  });

  testWidgets('題名をタップすると URL の全体が出て、写せる', (tester) async {
    // 題名に出るのはファイル名だけ。どこから来た画像かは URL を出さないと読めない。
    final urls = [
      Uri.parse('https://img.example.com/2026/08/a.jpg?size=large'),
      Uri.parse('https://example.com/b.png'),
    ];
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);
    expect(find.text(urls.first.toString()), findsNothing);

    await tester.tap(find.text('1/2  a.jpg'));
    await tester.pumpAndSettle();
    expect(find.text(urls.first.toString()), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pumpAndSettle();
    expect(copied, [urls.first.toString()]);
    // 知らせは押した場所で返す（SnackBar はアプリ側へ出るので、この黒い画面
    // には届かない）。
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 送ると、開けたまま次の URL に入れ替わる。写した印は前の URL のものなので
    // 残さない。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text(urls.last.toString()), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);

    // もう一度タップで畳む。
    await tester.tap(find.text('2/2  b.png'));
    await tester.pumpAndSettle();
    expect(find.text(urls.last.toString()), findsNothing);
  });

  testWidgets('操作一式を引っ込めると URL も畳む', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);
    await tester.tap(find.text('a.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('https://example.com/a.jpg'), findsOneWidget);

    // 絵をタップして一式を引っ込め、また出す。題名だけの姿から始まる。
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('https://example.com/a.jpg'), findsNothing);
  });

  testWidgets('画像ビューアは上下スワイプで閉じられる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);
    expect(find.text('a.jpg'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsNothing);
  });

  testWidgets('画像ビューアは×でも閉じられる', (tester) async {
    // ビューアはルートではなくなった（Navigator の外に載る）ので、AppBar の
    // 自動の戻る矢印は付かない。代わりに×を自前で置いてある。
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    // ステータスバーのぶんは自前で避ける（Scaffold が面倒を見てくれる位置に
    // 居ないので、AppBar 自身の primary 扱いに任せている）。
    tester.view.padding = const FakeViewPadding(top: 132);
    addTearDown(tester.view.reset);

    await _openViewer(tester);
    expect(find.text('a.jpg'), findsOneWidget);
    expect(tester.getTopLeft(find.text('a.jpg')).dy, greaterThan(44));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsNothing);
    expect(MiniPlayerController.shared.media, isNull);
  });

  testWidgets('ビューアのNGは確認を絵より上に出す', (tester) async {
    // ビューアは Navigator の外に載っている。確認を Navigator 側へ出すと絵の
    // 下へ潜り、絵を閉じるまで気づけない（押した手応えが無い）。
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);
    await tester.tap(find.byIcon(Icons.hide_image_outlined));
    await tester.pumpAndSettle();

    expect(find.text('この画像をNG'), findsOneWidget);
    expect(
      _isTappable(tester, find.widgetWithText(FilledButton, 'NGにする')),
      isTrue,
    );

    // 暗幕を押せば取り消せる。ビューアは開いたまま。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('この画像をNG'), findsNothing);
    expect(MiniPlayerController.shared.media, isNotNull);
  });

  testWidgets('ビューアを閉じるとNGの確認も片付ける', (tester) async {
    // 「戻る」はビューア（の下敷きルート）に届く。絵が消えたあとに問いだけ
    // 残ると、何に対する問いなのか分からなくなる。
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);
    await tester.tap(find.byIcon(Icons.hide_image_outlined));
    await tester.pumpAndSettle();
    expect(find.text('この画像をNG'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(MiniPlayerController.shared.media, isNull);
    expect(find.text('この画像をNG'), findsNothing);
  });

  testWidgets('サムネの長押しは、拡大せずにNGまで行ける', (tester) async {
    // 伏せたい画像ほど大きくは見たくない。ビューアを開かずに済ませる道を残す。
    final url = Uri.parse('https://example.com/a.jpg');
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: [url])),
      ),
    );

    await tester.longPress(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    expect(find.text('ブラウザで開く'), findsOneWidget);
    expect(find.text('URLをコピー'), findsOneWidget);
    // 一覧を出しただけでは絵は開かない。
    expect(MiniPlayerController.shared.media, isNull);

    await tester.tap(find.text('この画像をNG'));
    await tester.pumpAndSettle();
    // 確認はアプリ側（Navigator）へ出す。ビューアは出ていない。
    expect(
      find.text('同じ画像は、次から別の URL で貼られても隠します。貼り直しで多少変わった画像も隠します。'),
      findsOneWidget,
    );
    expect(
      _isTappable(tester, find.widgetWithText(FilledButton, 'NGにする')),
      isTrue,
    );

    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();
    expect(find.text('この画像をNG'), findsNothing);
  });

  testWidgets('サムネの長押しからブラウザとURLコピーへ回せる', (tester) async {
    final url = Uri.parse('https://img.example.com/2026/08/a.jpg?size=large');
    final opened = <Uri>[];
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [url], onOpenImageExternally: opened.add),
        ),
      ),
    );

    await tester.longPress(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    // 行き先は札にも出す（ファイル名だけでは素性が分からない）。
    expect(find.text(url.toString()), findsOneWidget);
    await tester.tap(find.text('URLをコピー'));
    await tester.pumpAndSettle();
    expect(copied, [url.toString()]);

    await tester.longPress(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブラウザで開く'));
    await tester.pumpAndSettle();
    expect(opened, [url]);
  });

  testWidgets('拡大中の上下ドラッグは閉じずに画像のパンへ回す', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);

    // 2本指のピンチで拡大する。
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final left = await tester.startGesture(center - const Offset(20, 0));
    final right = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await left.moveBy(const Offset(-60, 0));
    await right.moveBy(const Offset(60, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    // 拡大したまま上下にずらしてもビューアは開いたまま。
    await tester.drag(find.byType(PageView), const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);
  });

  testWidgets('拡大するとその分だけ細かくデコードし直し、戻せば元に戻る', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);

    final fit = _viewerDecodeTarget(tester);
    await _pinchZoom(tester);
    expect(_viewerScale(tester), greaterThan(1.01));
    // 画面ぴったりの 1 枚を拡げるだけでは粗くなる。倍率のぶん細かく取り直す。
    expect(_viewerDecodeTarget(tester).width, greaterThan(fit.width));

    // 等倍へ戻したら細かさも戻す（見えない分をメモリに抱えたままにしない）。
    tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value =
        Matrix4.identity();
    await tester.pumpAndSettle();
    expect(_viewerDecodeTarget(tester), fit);
  });

  testWidgets('拡大中の左右ドラッグは端まで画像を送り、はみ出したら隣の画像へ', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);

    // 等倍のうちは左右スワイプで隣の画像へ送る。
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);

    await _pinchZoom(tester);

    // 画像の中を見ている間は、左右にずらしてもページは変わらない。
    await tester.drag(find.byType(PageView), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);

    // 右端まで来てもなお左へ引っぱると、そのまま次の画像へ送る。
    await tester.drag(find.byType(PageView), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(find.text('3/3  c.webp'), findsOneWidget);

    // 送った先は等倍なので、左右スワイプがそのままページ送りに戻っている。
    await tester.fling(find.byType(PageView), const Offset(300, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);
  });

  testWidgets('拡大中でもトラックパッドの横スクロールは隣の画像へ送る', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);
    await _pinchZoom(tester);

    // ひと続きのスクロールでは、慣性で流れ続けても1枚だけ送る。
    await _scroll(tester, const Offset(60, 0), times: 40);
    expect(find.text('2/3  b.png'), findsOneWidget);
  });

  testWidgets('等倍のトラックパッド縦スクロールで閉じる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);
    expect(find.text('a.jpg'), findsOneWidget);

    await _scroll(tester, const Offset(0, 40), times: 3);
    expect(find.text('a.jpg'), findsNothing);
  });

  testWidgets('拡大中の縦スクロールとホイールでは閉じない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await _openViewer(tester);

    // ホイールは拡大縮小なので、等倍のうちに回しても閉じない。
    await _scroll(
      tester,
      const Offset(0, 40),
      times: 3,
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('a.jpg'), findsOneWidget);

    // 拡大中の縦スクロールは画像を上下にずらして見る操作なので閉じない。
    await _pinchZoom(tester);
    await _scroll(tester, const Offset(0, 40), times: 3);
    expect(find.text('a.jpg'), findsOneWidget);
  });

  testWidgets('拡大中に端からはみ出しても最初と最後で止まる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);
    expect(find.text('1/2  a.jpg'), findsOneWidget);

    await _pinchZoom(tester);

    // 1枚目の左端から更に右へ引っぱっても、最後の画像へは巻き戻らない。
    await tester.drag(find.byType(PageView), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(find.text('1/2  a.jpg'), findsOneWidget);
  });

  testWidgets('ページ送りが流れている最中でもピンチで拡大できる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);

    // 隣へ送り、まだ流れ着かないうちにピンチする。
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 800);
    await tester.pump(const Duration(milliseconds: 40));
    await _pinchZoom(tester);
    expect(_viewerScale(tester), greaterThan(1));

    // ピンチの2本指がページ送りへ流れていない。
    expect(find.text('3/3  c.webp'), findsNothing);
  });

  testWidgets('ボタンでのページ送りの最中でもピンチで拡大できる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await _openViewer(tester);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump(const Duration(milliseconds: 40));
    await _pinchZoom(tester);
    expect(_viewerScale(tester), greaterThan(1));
  });

  /// 画像と動画が混ざったレスを開けるようにして、動画の再生をテスト内で完結させる。
  void useFakeVideo() {
    final originalPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlayerPlatform();
    // サムネイル生成を挟まない（非対応プラットフォーム）。
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;
    addTearDown(() {
      VideoPlayerPlatform.instance = originalPlatform;
      VideoThumbnails.debugTargetPlatform = null;
      VideoPlayerView.debugResetMuted();
    });
  }

  /// 再生中は `video_player` が位置ポーリングのタイマーを回し続けて
  /// `pumpAndSettle` が落ち着かないので、送りきる（＋プレーヤーが初期化を
  /// 終える）ぶんだけ進める。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('画像と動画をひと続きに送れる', (tester) async {
    useFakeVideo();
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: [Uri.parse('https://example.com/a.jpg')],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );

    // 画像のサムネから開くと、動画も同じ並びに入っている。
    await tester.tap(find.byType(GestureDetector).first);
    await settle(tester);
    await tester.tap(find.byType(PageView));
    await tester.pump();
    expect(find.text('1/2  a.jpg'), findsOneWidget);

    // 隣へ送ると動画のページ。そこで初めてプレーヤーが立ち上がる。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await settle(tester);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    // 動画では見出しも ◀▶ も操作の一部なので、流している間は隠れている。
    expect(find.text('2/2  movie.mp4'), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);

    // タップで一式出る。◀▶ はプレーヤー側の出し入れに合わせて付いてくる。
    await tester.tap(find.byType(AspectRatio), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(find.text('2/2  movie.mp4'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);

    // 画像へ戻れば、プレーヤーは畳まれて元の見出しに戻る。
    await tester.tap(find.byIcon(Icons.chevron_left));
    await settle(tester);
    expect(find.byType(VideoPlayerView), findsNothing);
    expect(find.text('1/2  a.jpg'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('動画のページでも題名から URL の全体が出る', (tester) async {
    useFakeVideo();
    final video = Uri.parse('https://example.com/movie.mp4');
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(urls: const [], videoUrls: [video]),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await settle(tester);
    // 流している間は見出しも隠れている。タップで操作一式を出す。
    await tester.tap(find.byType(AspectRatio), warnIfMissed: false);
    await settle(tester);
    expect(find.text('movie.mp4'), findsOneWidget);

    // 題名は真ん中に置く（×のぶんだけ右へずれない）。画像のページの AppBar も
    // `centerTitle` にしてあり、送っても題名の位置は動かない。
    expect(
      tester.getCenter(find.byType(MediaTitleButton)).dx,
      closeTo(tester.getSize(find.byType(PageView)).width / 2, 1),
    );

    // 題名のタップは操作一式を引っ込めず、URL を開く（映像のタップとは別）。
    await tester.tap(find.text('movie.mp4'));
    await tester.pump();
    expect(find.text(video.toString()), findsOneWidget);

    // 開けている間は自動で引っ込めない（読んでいる最中に消えると困る）。
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(video.toString()), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(copied, [video.toString()]);
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 映像をタップして一式を引っ込めると URL も畳む（中央は再生ボタンが乗って
    // いるので、そこは外して押す）。
    await tester.tapAt(const Offset(600, 420));
    await settle(tester);
    expect(find.text(video.toString()), findsNothing);
    expect(find.text('movie.mp4'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ビューアの「ブラウザで開く」は画像と動画で行き先を分ける', (tester) async {
    useFakeVideo();
    final images = <Uri>[];
    final videos = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: [Uri.parse('https://example.com/a.jpg')],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
            onOpenImageExternally: images.add,
            onOpenVideoExternally: videos.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await settle(tester);
    await tester.tap(find.byType(PageView));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.open_in_browser));
    await tester.pump();
    expect(images, [Uri.parse('https://example.com/a.jpg')]);

    // 動画は動画側のハンドラへ。**画像側（アプリ内の URL 振り分け）へ渡すと、
    // 動画 URL はまたビューアへ送り返されて堂々巡りになる。**
    await tester.tap(find.byIcon(Icons.chevron_right));
    await settle(tester);
    await tester.tap(find.byType(AspectRatio), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.open_in_browser));
    await tester.pump();
    expect(videos, [Uri.parse('https://example.com/movie.mp4')]);
    expect(images, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('動画のサムネから開いても並びの中の位置から始まる', (tester) async {
    useFakeVideo();
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: [
              Uri.parse('https://example.com/a.jpg'),
              Uri.parse('https://example.com/b.png'),
            ],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await settle(tester);
    expect(find.byType(VideoPlayerView), findsOneWidget);

    // 3件目として開いているので、左へ送ると 2 枚目の画像に着く。
    await tester.tap(find.byType(AspectRatio), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await settle(tester);
    await tester.tap(find.byType(PageView));
    await tester.pump();
    expect(find.text('2/3  b.png'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('動画URLは非対応プラットフォームでは再生カードにする', (tester) async {
    addTearDown(() => VideoThumbnails.debugTargetPlatform = null);
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    // ファイル名(id)ではなくサイト（ここでは未知ホストなのでドメイン）を出す。
    expect(find.text('example.com'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('動画URLは対応プラットフォームで先頭フレームを敷く', (tester) async {
    addTearDown(() {
      VideoThumbnails.debugTargetPlatform = null;
      VideoThumbnails.generator = originalVideoGenerator;
      VideoThumbnails.clearCache();
    });
    VideoThumbnails.debugTargetPlatform = TargetPlatform.android;
    VideoThumbnails.clearCache();
    VideoThumbnails.generator = (url) async => _tinyPng;
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 生成フレームを Image.memory で敷きつつ、左下バッジ（▶＋サイト名）は残す。
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
  });

  testWidgets('動画サムネイルは映像の形で出す', (tester) async {
    addTearDown(() {
      VideoThumbnails.debugTargetPlatform = null;
      VideoThumbnails.generator = originalVideoGenerator;
      VideoThumbnails.clearCache();
    });
    VideoThumbnails.debugTargetPlatform = TargetPlatform.android;
    VideoThumbnails.clearCache();
    // 16:9 の映像。フレームのヘッダから形が分かるので、正方形に切らず横へ
    // 伸ばして出す（画像のサムネイルと同じ規則＝`thumbBox`）。
    VideoThumbnails.generator = (url) async => _frame(320, 180);
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.ancestor(of: find.byType(Image), matching: find.byType(InkWell)),
    );
    expect(card.height, 160);
    expect(card.width / card.height, moreOrLessEquals(16 / 9, epsilon: 0.01));
  });

  testWidgets('フレームを取れない間は正方形で場所を取る', (tester) async {
    addTearDown(() {
      VideoThumbnails.debugTargetPlatform = null;
      VideoThumbnails.generator = originalVideoGenerator;
      VideoThumbnails.clearCache();
    });
    VideoThumbnails.debugTargetPlatform = TargetPlatform.android;
    VideoThumbnails.clearCache();
    VideoThumbnails.generator = (url) async => null;
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.ancestor(
        of: find.byIcon(Icons.play_arrow_rounded),
        matching: find.byType(InkWell),
      ),
    );
    expect(card.width, card.height);
  });

  testWidgets('YouTube/ニコニコは再生サムネイルとして表示しタップを通知する', (tester) async {
    NicoThumbnails.clearCache();
    NicoThumbnails.fetcher = _StubFetcher();
    final tapped = <EmbedVideo>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: PostImages(
            urls: const [],
            embedVideos: embedVideosIn(
              'https://youtu.be/dQw4w9WgXcQ '
              'https://www.nicovideo.jp/watch/sm9',
            ),
            onTapEmbed: tapped.add,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.play_circle_fill), findsNWidgets(2));
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('ニコニコ動画'), findsOneWidget);
    final youtubeCard = tester.getRect(
      find.ancestor(of: find.text('YouTube'), matching: find.byType(InkWell)),
    );
    final niconicoCard = tester.getRect(
      find.ancestor(of: find.text('ニコニコ動画'), matching: find.byType(InkWell)),
    );
    expect(youtubeCard.width / youtubeCard.height, moreOrLessEquals(16 / 9));
    expect(niconicoCard.width / niconicoCard.height, moreOrLessEquals(1.25));

    await tester.tap(find.text('ニコニコ動画'));
    expect(tapped.single.url, Uri.parse('https://www.nicovideo.jp/watch/sm9'));
  });

  testWidgets('幅が足りないカードは高さも一緒に縮めて 16:9 を保つ', (tester) async {
    // ツリー表示の深いインデントや狭い端末では、カードの既定幅（160×16/9＝284）が
    // 入らない。高さを固定したままだと横長の動画が縦長のカードになる。
    await tester.pumpWidget(
      MaterialApp(
        builder: _host,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: PostImages(
                urls: const [],
                embedVideos: embedVideosIn('https://youtu.be/dQw4w9WgXcQ'),
              ),
            ),
          ),
        ),
      ),
    );

    final card = tester.getRect(
      find.ancestor(of: find.text('YouTube'), matching: find.byType(InkWell)),
    );
    expect(card.width, 120);
    expect(card.width / card.height, moreOrLessEquals(16 / 9));
  });
}
