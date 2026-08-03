import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/ui/format.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/remote_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本文を実際に流したかどうかを見られるフェイクのレスポンス。
class _FakeResponse extends Stream<List<int>> implements io.HttpClientResponse {
  _FakeResponse(
    this.body, {
    required this.contentLength,
    this.statusCode = 200,
  });

  final Uint8List body;

  @override
  final int contentLength;

  @override
  final int statusCode;

  /// 実際に呼び出し側へ渡ったバイト数。上限で弾いたなら 0 のまま。
  int delivered = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(body).listen(
      onData == null
          ? null
          : (chunk) {
              delivered += chunk.length;
              onData(chunk);
            },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements io.HttpClientRequest {
  _FakeRequest(this.response);
  final _FakeResponse response;

  @override
  Future<io.HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClient implements io.HttpClient {
  _FakeHttpClient(this.response);
  final _FakeResponse response;

  /// 何回取りに行ったか。二度落としていないかを見る。
  int requests = 0;

  @override
  Future<io.HttpClientRequest> getUrl(Uri url) async {
    requests += 1;
    return _FakeRequest(response);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [width]×[height] の PNG を作る。原寸のままデコードされていないかを見るため。
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF3355FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// provider を解決して、デコードされた画像（か例外）を返す。
Future<ImageInfo> _resolve(ImageProvider provider) {
  final completer = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(info);
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ImageLoadPolicy.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    RemoteImage.resetClient();
  });

  tearDown(RemoteImage.resetClient);

  test('大きすぎる画像は本文を読まずに諦める', () async {
    final url = Uri.parse('https://example.com/huge.jpg');
    final response = _FakeResponse(
      Uint8List(1024),
      contentLength: 40 << 20, // 40MB
    );

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await expectLater(
        _resolve(
          RemoteImage(url, target: const Size(480, 480), maxBytes: 8 << 20),
        ),
        throwsA(isA<ImageTooLargeException>()),
      );
    }, createHttpClient: (_) => _FakeHttpClient(response));

    // ヘッダだけで判断するので本文は 1 バイトも流れない。
    expect(response.delivered, 0);
    // 大きさは覚えていて、次からは通信せずにカードを出せる。
    expect(ImageLoadPolicy.knownBytes(url), 40 << 20);
    expect(ImageLoadPolicy.skipsAutoLoad(url), isTrue);
  });

  test('Content-Length が無くても受信中に上限で打ち切る', () async {
    final url = Uri.parse('https://example.com/unknown.jpg');
    final response = _FakeResponse(Uint8List(4096), contentLength: -1);

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await expectLater(
        _resolve(
          RemoteImage(url, target: const Size(480, 480), maxBytes: 1024),
        ),
        throwsA(isA<ImageTooLargeException>()),
      );
    }, createHttpClient: (_) => _FakeHttpClient(response));
  });

  test('同じ画像を別の大きさで開いても、落とすのは一度だけ', () async {
    final url = Uri.parse('https://example.com/photo.png');
    final bytes = await _png(400, 300);
    final client = _FakeHttpClient(
      _FakeResponse(bytes, contentLength: bytes.length),
    );

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      // サムネイル相当 → 全画面相当。目標サイズが違うので ImageCache には
      // 当たらないが、本文は使い回せる。
      final thumb = await _resolve(
        RemoteImage(url, target: const Size(160, 160), cover: true),
      );
      final full = await _resolve(
        RemoteImage(url, target: const Size(1200, 900)),
      );
      // デコードは表示サイズごとにやり直す（ここは使い回せない）。
      expect(thumb.image.width, lessThan(full.image.width));
    }, createHttpClient: (_) => client);

    expect(client.requests, 1);
  });

  test('大きい画像ほど覚える価値がある（置き場の合計を超えても捨てない）', () async {
    // 自動読み込みの上限（8MiB）を超える＝利用者がタップして読み込むと決めた
    // 大きさ。一番待たされるものなので、開き直しで落とし直さないこと。
    final huge = Uint8List(12 << 20);
    final client = _FakeHttpClient(
      _FakeResponse(huge, contentLength: huge.length),
    );
    final url = Uri.parse('https://example.com/huge.png');

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      ImageLoadPolicy.allow(url);
      // 中身は画像として読めないのでデコードは失敗するが、本文は覚えている。
      for (var i = 0; i < 2; i++) {
        await expectLater(
          _resolve(
            RemoteImage(
              url,
              target: Size.square(160.0 * (i + 1)),
              maxBytes: imageHardMaxBytes,
            ),
          ),
          throwsA(anything),
        );
      }
    }, createHttpClient: (_) => client);

    expect(client.requests, 1);
  });

  test('取得に失敗した画像は大きさを覚えない', () async {
    final url = Uri.parse('https://example.com/gone.jpg');
    final response = _FakeResponse(
      Uint8List(0),
      contentLength: 0,
      statusCode: 404,
    );

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await expectLater(
        _resolve(RemoteImage(url, target: const Size(480, 480))),
        throwsA(isA<NetworkImageLoadException>()),
      );
    }, createHttpClient: (_) => _FakeHttpClient(response));

    expect(ImageLoadPolicy.knownBytes(url), isNull);
  });

  test('大きい画像は表示サイズまで縮めてデコードする', () async {
    final url = Uri.parse('https://example.com/big.png');
    final bytes = await _png(800, 400);
    final response = _FakeResponse(bytes, contentLength: bytes.length);

    late final ImageInfo info;
    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      info = await _resolve(RemoteImage(url, target: const Size(200, 200)));
    }, createHttpClient: (_) => _FakeHttpClient(response));

    // 200×200 に収まるまで（縦横比はそのまま）縮む。原寸 800×400 のままではない。
    expect(info.image.width, 200);
    expect(info.image.height, 100);
    info.dispose();
  });

  test('小さい画像は引き伸ばさない', () async {
    final url = Uri.parse('https://example.com/small.png');
    final bytes = await _png(40, 40);
    final response = _FakeResponse(bytes, contentLength: bytes.length);

    late final ImageInfo info;
    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      info = await _resolve(RemoteImage(url, target: const Size(480, 480)));
    }, createHttpClient: (_) => _FakeHttpClient(response));

    expect(info.image.width, 40);
    expect(info.image.height, 40);
    info.dispose();
  });

  test('読み込むと決めた URL は上限が上がる', () {
    final url = Uri.parse('https://example.com/huge.jpg');
    ImageLoadPolicy.remember(url, 40 << 20);
    expect(ImageLoadPolicy.limitFor(url), imageAutoLoadMaxBytes);
    expect(ImageLoadPolicy.skipsAutoLoad(url), isTrue);

    ImageLoadPolicy.allow(url);
    expect(ImageLoadPolicy.limitFor(url), imageHardMaxBytes);
    expect(ImageLoadPolicy.skipsAutoLoad(url), isFalse);
  });

  test('バイト数は読める桁で出す', () {
    expect(formatBytes(900), '900B');
    expect(formatBytes(2048), '2KB');
    expect(formatBytes(1500 * 1024), '1.5MB');
    expect(formatBytes(20 << 20), '20MB');
  });

  testWidgets('大きすぎると分かっている画像は読み込まずカードを出す', (tester) async {
    final url = Uri.parse('https://example.com/huge.jpg');
    ImageLoadPolicy.remember(url, 20 << 20);
    addTearDown(ImageLoadPolicy.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostImages(urls: [url])),
      ),
    );

    expect(find.text('大きい画像 20MB'), findsOneWidget);
    expect(find.text('タップで読み込む'), findsOneWidget);
    // 通信していないので、この時点では読み込み中の表示も出ない。
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('タップで読み込む'));
    await tester.pump();

    // タップした URL は以後読み込む側に回る（カードは消える）。
    expect(ImageLoadPolicy.isAllowed(url), isTrue);
    expect(find.text('タップで読み込む'), findsNothing);
  });

  testWidgets('全画面ビューアでも大きい画像は読み込むまで待つ', (tester) async {
    final url = Uri.parse('https://example.com/huge.jpg');
    ImageLoadPolicy.remember(url, 20 << 20);
    addTearDown(ImageLoadPolicy.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openImageViewer(context, [url]),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    expect(find.text('20MB の大きい画像です'), findsOneWidget);

    await tester.tap(find.text('読み込む'));
    await tester.pump();

    expect(ImageLoadPolicy.isAllowed(url), isTrue);
    expect(find.text('読み込む'), findsNothing);
  });
}
