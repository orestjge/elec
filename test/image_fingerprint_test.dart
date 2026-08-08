import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/net/image_fingerprint.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 同じ絵柄を [width]×[height] で描いた PNG。[mirrored] だと配置を左右に入れ替える
/// （別の画像として扱われてほしい方）。
Future<Uint8List> _scenePng(
  int width,
  int height, {
  bool mirrored = false,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // 100×100 の座標系で描いて、出力の大きさに合わせて伸ばす。
  canvas.scale(width / 100, height / 100);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    Rect.fromLTWH(mirrored ? 55 : 5, 8, 40, 34),
    Paint()..color = const Color(0xFF101010),
  );
  canvas.drawCircle(
    Offset(mirrored ? 25 : 78, 72),
    18,
    Paint()..color = const Color(0xFF404040),
  );
  canvas.drawRect(
    Rect.fromLTWH(mirrored ? 60 : 8, 55, 26, 12),
    Paint()..color = const Color(0xFF808080),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 一色で塗っただけの PNG。dHash が意味を持たない側。
Future<Uint8List> _flatPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF2244AA),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同じ本文なら SHA-256 も dHash も一致する', () async {
    final png = await _scenePng(120, 90);
    final a = await computeImageFingerprint(png);
    final b = await computeImageFingerprint(Uint8List.fromList(png));
    expect(a, isNotNull);
    expect(a!.dhash, isNotNull);
    expect(a, b);
  });

  test('大きさが違っても同じ絵柄なら dHash は近い', () async {
    final large = await computeImageFingerprint(await _scenePng(400, 300));
    final small = await computeImageFingerprint(await _scenePng(100, 75));
    // 貼り直しでバイト列は変わる＝完全一致では拾えない。
    expect(large!.sha256, isNot(small!.sha256));
    expect(large.distanceTo(small), lessThanOrEqualTo(ngImageMaxDistance));
  });

  test('別の絵柄は dHash が離れる', () async {
    final a = await computeImageFingerprint(await _scenePng(200, 150));
    final b = await computeImageFingerprint(
      await _scenePng(200, 150, mirrored: true),
    );
    expect(a!.distanceTo(b!), greaterThan(ngImageMaxDistance));
  });

  test('のっぺりした画像は dHash を採らない', () async {
    final flat = await computeImageFingerprint(await _flatPng(120, 90));
    expect(flat, isNotNull);
    expect(flat!.dhash, isNull);
    // 完全一致は効くので、同じファイルの貼り直しなら拾える。
    final same = await computeImageFingerprint(await _flatPng(120, 90));
    expect(flat.sha256, same!.sha256);
    // dHash が無い同士は「近い」とは見なさない。
    expect(flat.distanceTo(same), isNull);
  });

  test('画像として読めない本文でも SHA-256 だけは採れる', () async {
    final fingerprint = await computeImageFingerprint(
      Uint8List.fromList([1, 2, 3, 4, 5]),
    );
    expect(fingerprint, isNotNull);
    expect(fingerprint!.dhash, isNull);
    expect(fingerprint.sha256.length, 64);
  });

  test('空の本文には指紋が無い', () async {
    expect(await computeImageFingerprint(Uint8List(0)), isNull);
  });

  test('ハッシュの 16 進表記は往復する', () {
    final hash = Uint8List.fromList([0, 1, 0x0F, 0x80, 0xFF]);
    final hex = hashToHex(hash);
    expect(hex, '00010f80ff');
    expect(hexToHash(hex), hash);
    expect(hexToHash('abc'), isNull);
    expect(hexToHash('zz'), isNull);
    expect(hexToHash(''), isNull);
  });

  test('ハミング距離は違うビットの数', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);
    expect(hammingDistance(bytes([0, 0]), bytes([0, 0])), 0);
    expect(hammingDistance(bytes([0, 0]), bytes([0xFF, 0])), 8);
    expect(hammingDistance(bytes([0xFF, 0xFF]), bytes([0, 0])), 16);
    // 長さが違えば比べようがない。全ビットぶん離れているものとして扱う。
    expect(hammingDistance(bytes([0]), bytes([0, 0])), 16);
  });

  test('dHash は決めた長さになる', () async {
    final fingerprint = await computeImageFingerprint(
      await _scenePng(200, 150),
    );
    expect(fingerprint!.dhash!.length, imageHashBits ~/ 8);
  });

  test('見本の PNG は元より小さくなる', () async {
    final png = await _scenePng(400, 300);
    final thumbnail = await makeNgThumbnail(png, size: 72);
    expect(thumbnail, isNotNull);
    expect(thumbnail!.length, lessThan(png.length));
    // 出てきたものが PNG として読めること。
    final decoded = await decodeImageFromList(thumbnail);
    expect(decoded.width, 72);
    expect(decoded.height, 54);
  });

  group('指紋の覚え書き', () {
    late io.Directory dir;
    late ImageFingerprintIndex index;

    setUp(() {
      dir = io.Directory.systemTemp.createTempSync('elec_fingerprint');
      index = ImageFingerprintIndex(directory: dir);
    });

    tearDown(() {
      index.clear();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('書き出したものを読み直せる', () async {
      final url = Uri.parse('https://example.com/a.png');
      final fingerprint = await computeImageFingerprint(
        await _scenePng(120, 90),
      );
      index.put(url, fingerprint!);
      await index.flush();

      final reopened = ImageFingerprintIndex(directory: dir);
      await reopened.load();
      expect(reopened.get(url), fingerprint);
      reopened.clear();
    });

    test('覚えた URL は本文を採り直さない', () async {
      final url = Uri.parse('https://example.com/b.png');
      final png = await _scenePng(120, 90);
      final first = await index.resolve(url, png);
      // 中身が違っても、覚えている方を返す（同じ URL は同じ画像とみなす）。
      final second = await index.resolve(url, await _scenePng(200, 150));
      expect(second, first);
    });

    test('覚える数には上限があり、古い方から捨てる', () async {
      final fingerprint = await computeImageFingerprint(
        await _scenePng(120, 90),
      );
      for (var i = 0; i < ImageFingerprintIndex.maxEntries + 5; i++) {
        index.put(Uri.parse('https://example.com/$i.png'), fingerprint!);
      }
      expect(index.get(Uri.parse('https://example.com/0.png')), isNull);
      expect(
        index.get(
          Uri.parse(
            'https://example.com/${ImageFingerprintIndex.maxEntries + 4}.png',
          ),
        ),
        isNotNull,
      );
    });
  });
}
