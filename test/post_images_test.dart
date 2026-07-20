import 'dart:convert';

import 'package:edge_core/edge_core.dart';
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

  testWidgets('動画URLは非対応プラットフォームでは再生カードにする', (tester) async {
    addTearDown(() => VideoThumbnails.debugTargetPlatform = null);
    VideoThumbnails.debugTargetPlatform = TargetPlatform.macOS;
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

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.text('movie.mp4'), findsOneWidget);
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

    // 生成フレームを Image.memory で敷きつつ、再生アイコンとファイル名は残す。
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.text('movie.mp4'), findsOneWidget);
  });

  testWidgets('YouTube/ニコニコは再生サムネイルとして表示しタップで外部を開く', (tester) async {
    NicoThumbnails.clearCache();
    NicoThumbnails.fetcher = _StubFetcher();
    final tapped = <Uri>[];
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

    await tester.tap(find.text('ニコニコ動画'));
    expect(tapped, [Uri.parse('https://www.nicovideo.jp/watch/sm9')]);
  });
}
