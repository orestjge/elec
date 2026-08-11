import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/net/image_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// [width]×[height] の実物を作る。手で組んだヘッダだけで通しても、実際に
/// 貼られる絵で通る保証にはならない。
Uint8List _encoded(int width, int height, {required bool jpeg}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(40, 90, 200));
  // 単色だと JPEG が極端に短くなるので、模様を入れて実物に近づける。
  img.fillCircle(
    image,
    x: width ~/ 3,
    y: height ~/ 2,
    radius: (width < height ? width : height) ~/ 4,
    color: img.ColorRgb8(250, 220, 90),
  );
  return Uint8List.fromList(
    jpeg ? img.encodeJpg(image, quality: 70) : img.encodePng(image),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('JPEG の原寸を読む', () {
    expect(
      imageSizeFromHeader(_encoded(320, 180, jpeg: true)),
      const Size(320, 180),
    );
    expect(
      imageSizeFromHeader(_encoded(180, 320, jpeg: true)),
      const Size(180, 320),
    );
  });

  test('PNG の原寸を読む', () {
    expect(
      imageSizeFromHeader(_encoded(640, 360, jpeg: false)),
      const Size(640, 360),
    );
  });

  test('デコードした実物と一致する', () async {
    // ヘッダの読み方が合っているかを、エンジンのデコード結果と突き合わせる。
    final bytes = _encoded(400, 225, jpeg: true);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(
      imageSizeFromHeader(bytes),
      Size(frame.image.width.toDouble(), frame.image.height.toDouble()),
    );
    frame.image.dispose();
    codec.dispose();
  });

  test('先頭だけで分かる（本文が途中で切れていても読める）', () {
    // 通信の途中でも比率が分かる、という前提が崩れていないか。
    final bytes = _encoded(320, 180, jpeg: true);
    expect(
      imageSizeFromHeader(Uint8List.sublistView(bytes, 0, 200)),
      const Size(320, 180),
    );
  });

  group('読めないもの', () {
    test('空・短すぎるものは null', () {
      expect(imageSizeFromHeader(Uint8List(0)), isNull);
      expect(imageSizeFromHeader(Uint8List.fromList([0xFF, 0xD8])), isNull);
    });

    test('画像でないものは null', () {
      expect(
        imageSizeFromHeader(Uint8List.fromList('not an image'.codeUnits)),
        isNull,
      );
    });

    test('JPEG の署名だけあって中身が無いものは null', () {
      expect(
        imageSizeFromHeader(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]),
        ),
        isNull,
      );
    });
  });
}
