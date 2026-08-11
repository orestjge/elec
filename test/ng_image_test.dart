import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/net/image_cache_store.dart';
import 'package:elec/src/net/image_fingerprint.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/remote_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// URL ごとに違う本文を返すフェイク。貼り直し（別 URL・同じ絵）を作るのに使う。
class _FakeHttpClient implements io.HttpClient {
  _FakeHttpClient(this.bodies);

  final Map<String, Uint8List> bodies;
  int requests = 0;

  @override
  Future<io.HttpClientRequest> getUrl(Uri url) async {
    requests += 1;
    final body = bodies[url.toString()];
    if (body == null) throw io.HttpException('unexpected url: $url');
    return _FakeRequest(_FakeResponse(body));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements io.HttpClientRequest {
  _FakeRequest(this.response);
  final io.HttpClientResponse response;

  @override
  Future<io.HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements io.HttpClientResponse {
  _FakeResponse(this.body);

  final Uint8List body;

  @override
  int get contentLength => body.length;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 同じ絵柄を [width]×[height] で描いた PNG。大きさを変えるとバイト列は変わる。
Future<Uint8List> _scenePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(width / 100, height / 100);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    const Rect.fromLTWH(5, 8, 40, 34),
    Paint()..color = const Color(0xFF101010),
  );
  canvas.drawCircle(
    const Offset(78, 72),
    18,
    Paint()..color = const Color(0xFF404040),
  );
  canvas.drawRect(
    const Rect.fromLTWH(8, 55, 26, 12),
    Paint()..color = const Color(0xFF808080),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 別の絵柄の PNG（巻き込まれていないかを見る側）。
Future<Uint8List> _otherPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(width / 100, height / 100);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..color = const Color(0xFF202020),
  );
  canvas.drawRect(
    const Rect.fromLTWH(55, 60, 40, 34),
    Paint()..color = const Color(0xFFF0F0F0),
  );
  canvas.drawCircle(
    const Offset(25, 25),
    18,
    Paint()..color = const Color(0xFFB0B0B0),
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

  late io.Directory dir;

  setUp(() {
    ImageLoadPolicy.reset();
    // 覚えた縦横比もテストごとに捨てる。持ち越すと、同じ URL を使う後続の
    // テストがサムネイルの形（＝置き場所）ごと変わる。
    ImageAspect.shared.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    RemoteImage.resetClient();
    dir = io.Directory.systemTemp.createTempSync('elec_ng_image');
    ImageCacheStore.shared = ImageCacheStore(directory: dir);
    ImageFingerprintIndex.shared = ImageFingerprintIndex(directory: dir);
    NgStore.shared = NgStore(MemoryNgStorage());
  });

  tearDown(() {
    RemoteImage.resetClient();
    ImageCacheStore.resetShared();
    ImageFingerprintIndex.resetShared();
    NgStore.resetShared();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('NG にした画像は、別の URL で貼り直されても伏せる', () async {
    final original = Uri.parse('https://img.example.com/1.png');
    final reposted = Uri.parse('https://img.example.com/2.png');
    final resized = Uri.parse('https://img.example.com/3.png');
    final unrelated = Uri.parse('https://img.example.com/4.png');
    final scene = await _scenePng(200, 150);
    final client = _FakeHttpClient({
      original.toString(): scene,
      // 同じファイルをそのまま貼り直したもの（完全一致で拾う）。
      reposted.toString(): scene,
      // 縮めて貼り直したもの（バイト列は別。dHash で拾う）。
      resized.toString(): await _scenePng(100, 75),
      unrelated.toString(): await _otherPng(200, 150),
    });

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await NgStore.shared.load();

      // まだ NG が無いので普通に出る。
      await _resolve(RemoteImage(original, target: const Size(160, 160)));

      // 見えている画像を NG にする。本文は手元にあるので通信しない。
      final requestsBefore = client.requests;
      final registered = await addNgImage(original);
      expect(registered, isNotNull);
      expect(client.requests, requestsBefore);
      expect(NgStore.shared.images.single.thumbnail, isNotNull);

      // 元の URL は、指紋を覚えているので通信せずに弾く。
      final requestsAfterNg = client.requests;
      await expectLater(
        _resolve(RemoteImage(original, target: const Size(320, 320))),
        throwsA(isA<ImageNgException>()),
      );
      expect(client.requests, requestsAfterNg);

      // 別 URL の貼り直しは、落としてから中身で弾く。
      await expectLater(
        _resolve(RemoteImage(reposted, target: const Size(160, 160))),
        throwsA(isA<ImageNgException>()),
      );
      await expectLater(
        _resolve(RemoteImage(resized, target: const Size(160, 160))),
        throwsA(isA<ImageNgException>()),
      );

      // 無関係な画像は巻き込まない。
      await _resolve(RemoteImage(unrelated, target: const Size(160, 160)));
    }, createHttpClient: (_) => client);
  });

  test('NG を解除すると出し直せる', () async {
    final url = Uri.parse('https://img.example.com/x.png');
    final client = _FakeHttpClient({url.toString(): await _scenePng(200, 150)});

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await NgStore.shared.load();
      await _resolve(RemoteImage(url, target: const Size(160, 160)));

      final registered = await addNgImage(url);
      expect(NgStore.shared.isNgImageUrl(url), isTrue);
      await expectLater(
        _resolve(RemoteImage(url, target: const Size(160, 160))),
        throwsA(isA<ImageNgException>()),
      );

      await removeNgImage(registered!);
      expect(NgStore.shared.isNgImageUrl(url), isFalse);
      await _resolve(RemoteImage(url, target: const Size(160, 160)));
    }, createHttpClient: (_) => client);
  });

  test('NG 画像が無い間は指紋を採らない', () async {
    final url = Uri.parse('https://img.example.com/plain.png');
    final client = _FakeHttpClient({url.toString(): await _scenePng(200, 150)});

    await io.HttpOverrides.runZoned(() async {
      RemoteImage.resetClient();
      await NgStore.shared.load();
      await _resolve(RemoteImage(url, target: const Size(160, 160)));
      // 1 枚も登録していない人に、全画像のハッシュ計算を負わせない。
      expect(ImageFingerprintIndex.shared.get(url), isNull);
    }, createHttpClient: (_) => client);
  });

  test('読み込んでいない画像は NG にできない', () async {
    expect(
      await addNgImage(Uri.parse('https://img.example.com/never.png')),
      isNull,
    );
    expect(NgStore.shared.images, isEmpty);
  });
}
