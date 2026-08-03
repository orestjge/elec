import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_edit.dart';

/// モザイクのブロック数（画像の長辺あたり）。
///
/// 固定にしているのは、隠したいのが「読めてしまう文字や顔」だからで、強さを
/// 選ばせるより常に潰れる方が事故が少ない。プレビュー側も同じ値でブロックを
/// 作るので、見えているモザイクと出力が一致する。
const int mosaicBlocksOnLongSide = 40;

/// 編集を適用して、アップロードするバイト列を作る。
///
/// デコードと再エンコードは重いのでアイソレート（[compute]）で回す。
Future<Uint8List> applyImageEdit(Uint8List bytes, ImageEdit edit) {
  if (edit.isIdentity) return Future.value(bytes);
  return compute(renderImageEdit, (bytes, edit));
}

/// [applyImageEdit] の本体。アイソレートへ渡すため最上位関数にしてある。
Uint8List renderImageEdit((Uint8List, ImageEdit) request) {
  final (bytes, edit) = request;
  // 壊れた・未対応の画像は decodeImage が null を返すこともあれば、途中で
  // 例外を投げることもある。どちらも同じ扱いにする。
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) {
    throw const ImageEditException('画像を読み込めませんでした');
  }

  // Exif の向きを画素に焼き込む。以降 Exif は捨てるので、ここで正しておかないと
  // 横倒しのまま出てしまう。
  var image = img.bakeOrientation(decoded);

  _paintMasks(image, edit.strokes);

  if (edit.flipHorizontal) image = img.flipHorizontal(image);
  if (edit.quarterTurns % 4 != 0) {
    image = img.copyRotate(image, angle: 90 * (edit.quarterTurns % 4));
  }

  final crop = edit.crop;
  if (crop != const Rect.fromLTRB(0, 0, 1, 1)) {
    final x = (crop.left * image.width).round().clamp(0, image.width - 1);
    final y = (crop.top * image.height).round().clamp(0, image.height - 1);
    final w = (crop.width * image.width).round().clamp(1, image.width - x);
    final h = (crop.height * image.height).round().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  final maxLongSide = edit.maxLongSide;
  final longSide = math.max(image.width, image.height);
  if (maxLongSide != null && longSide > maxLongSide) {
    final scale = maxLongSide / longSide;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  // PNG は文字入りのスクショが多く、JPEG に落とすと滲むので形式を保つ。
  // それ以外（JPEG・HEIC 等）は JPEG で出す。
  return isPng(bytes)
      ? img.encodePng(image)
      : img.encodeJpg(image, quality: edit.jpegQuality);
}

bool isPng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

/// 出力の拡張子（アップロード時のファイル名に使う）。
String editedExtension(Uint8List sourceBytes) =>
    isPng(sourceBytes) ? 'png' : 'jpg';

void _paintMasks(img.Image image, List<MaskStroke> strokes) {
  if (strokes.isEmpty) return;

  final longSide = math.max(image.width, image.height);
  final block = math.max(1, (longSide / mosaicBlocksOnLongSide).round());
  // モザイク元は筆を入れる前の画像から 1 度だけ作る。塗り重ねた色を拾って
  // 段々濃くなる、といったことが起きないようにする。
  final needsMosaic = strokes.any((s) => s.kind == MaskKind.mosaic);
  final small = needsMosaic
      ? img.copyResize(
          image,
          width: math.max(1, (image.width / block).ceil()),
          height: math.max(1, (image.height / block).ceil()),
          interpolation: img.Interpolation.average,
        )
      : null;
  final black = img.ColorRgb8(0, 0, 0);

  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final radius = math.max(1.0, stroke.width * longSide / 2);
    final points = [
      for (final p in stroke.points)
        Offset(p.dx * image.width, p.dy * image.height),
    ];
    // 1 点だけのタップは長さ 0 の線分＝円として塗る。
    final segments = points.length == 1
        ? [(points.first, points.first)]
        : [
            for (var i = 0; i < points.length - 1; i++)
              (points[i], points[i + 1]),
          ];

    for (final (a, b) in segments) {
      final left = math.max(0, (math.min(a.dx, b.dx) - radius).floor());
      final top = math.max(0, (math.min(a.dy, b.dy) - radius).floor());
      final right = math.min(
        image.width - 1,
        (math.max(a.dx, b.dx) + radius).ceil(),
      );
      final bottom = math.min(
        image.height - 1,
        (math.max(a.dy, b.dy) + radius).ceil(),
      );
      for (var y = top; y <= bottom; y++) {
        for (var x = left; x <= right; x++) {
          if (_distanceToSegment(x + 0.5, y + 0.5, a, b) > radius) continue;
          if (stroke.kind == MaskKind.fill) {
            image.setPixel(x, y, black);
          } else {
            final sx = math.min(x ~/ block, small!.width - 1);
            final sy = math.min(y ~/ block, small.height - 1);
            image.setPixel(x, y, small.getPixel(sx, sy));
          }
        }
      }
    }
  }
}

double _distanceToSegment(double px, double py, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final lengthSquared = dx * dx + dy * dy;
  var t = 0.0;
  if (lengthSquared > 0) {
    t = (((px - a.dx) * dx + (py - a.dy) * dy) / lengthSquared).clamp(0.0, 1.0);
  }
  final cx = a.dx + t * dx;
  final cy = a.dy + t * dy;
  return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

class ImageEditException implements Exception {
  const ImageEditException(this.message);
  final String message;

  @override
  String toString() => message;
}
