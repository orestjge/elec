import 'dart:convert';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/gestures.dart';
import 'package:elec/src/ui/embed_urls.dart';
import 'package:elec/src/ui/nico_thumbnail.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1x1 の透過 PNG。Image.memory がデコードできる最小の有効画像。
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwAD'
  'hgGAWjR9awAAAABJRU5ErkJggg==',
);

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

  testWidgets('同一レス内の複数画像をビューアで巡回できる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    expect(find.text('1/3  a.jpg'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('1/3  a.jpg'), findsOneWidget);
  });

  testWidgets('画像ビューアは上下スワイプで閉じられる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsNothing);
  });

  testWidgets('拡大中の上下ドラッグは閉じずに画像のパンへ回す', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

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

  testWidgets('拡大中の左右ドラッグは端まで画像を送り、はみ出したら隣の画像へ', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

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
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    await _pinchZoom(tester);

    // ひと続きのスクロールでは、慣性で流れ続けても1枚だけ送る。
    await _scroll(tester, const Offset(60, 0), times: 40);
    expect(find.text('2/3  b.png'), findsOneWidget);
  });

  testWidgets('等倍のトラックパッド縦スクロールで閉じる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);

    await _scroll(tester, const Offset(0, 40), times: 3);
    expect(find.text('a.jpg'), findsNothing);
  });

  testWidgets('拡大中の縦スクロールとホイールでは閉じない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(urls: [Uri.parse('https://example.com/a.jpg')]),
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

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
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
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
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

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
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump(const Duration(milliseconds: 40));
    await _pinchZoom(tester);
    expect(_viewerScale(tester), greaterThan(1));
  });

  testWidgets('動画URLは非対応プラットフォームでは再生カードにする', (tester) async {
    addTearDown(() => VideoThumbnails.debugTargetPlatform = null);
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

  testWidgets('YouTube/ニコニコは再生サムネイルとして表示しタップを通知する', (tester) async {
    NicoThumbnails.clearCache();
    NicoThumbnails.fetcher = _StubFetcher();
    final tapped = <EmbedVideo>[];
    await tester.pumpWidget(
      MaterialApp(
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
}
