import 'dart:typed_data';
import 'dart:ui';

import 'package:elec/src/ui/image_edit.dart';
import 'package:elec/src/ui/image_edit_render.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 左半分が黒・右半分が白の画像。境界を [split] にずらせるので、モザイクの
/// ブロックが境界をまたいで平均化されたかを見られる。
img.Image _splitImage({int width = 400, int height = 400, int split = 205}) {
  final image = img.Image(width: width, height: height);
  final black = img.ColorRgb8(0, 0, 0);
  final white = img.ColorRgb8(255, 255, 255);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixel(x, y, x < split ? black : white);
    }
  }
  return image;
}

/// 左上だけ赤い 4x2 の画像。回転・反転の向きを見るのに使う。
img.Image _cornerImage() {
  final image = img.Image(width: 4, height: 2);
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 4; x++) {
      image.setPixel(x, y, img.ColorRgb8(0, 0, 255));
    }
  }
  image.setPixel(0, 0, img.ColorRgb8(255, 0, 0));
  return image;
}

bool _isRed(img.Pixel p) => p.r > 200 && p.g < 60 && p.b < 60;

img.Image _render(img.Image source, ImageEdit edit, {bool png = true}) {
  final bytes = Uint8List.fromList(
    png ? img.encodePng(source) : img.encodeJpg(source, quality: 100),
  );
  return img.decodeImage(renderImageEdit((bytes, edit)))!;
}

void main() {
  group('座標変換', () {
    test('時計回り 90 度で左上が右上へ移る', () {
      final p = orientedFromSource(
        const Offset(0, 0),
        quarterTurns: 1,
        flipHorizontal: false,
      );
      expect(p, const Offset(1, 0));
    });

    test('元画像座標へ戻すと往復する', () {
      for (final turns in [0, 1, 2, 3]) {
        for (final flip in [false, true]) {
          const p = Offset(0.25, 0.75);
          final oriented = orientedFromSource(
            p,
            quarterTurns: turns,
            flipHorizontal: flip,
          );
          final back = sourceFromOriented(
            oriented,
            quarterTurns: turns,
            flipHorizontal: flip,
          );
          expect(
            back.dx,
            closeTo(p.dx, 1e-9),
            reason: 'turns=$turns flip=$flip',
          );
          expect(
            back.dy,
            closeTo(p.dy, 1e-9),
            reason: 'turns=$turns flip=$flip',
          );
        }
      }
    });

    test('回転してもトリミング枠は画像の同じ場所を指す', () {
      // 左上 1/4 を切っている状態で右に 90 度回すと、その領域は右上へ来る。
      const edit = ImageEdit(crop: Rect.fromLTRB(0, 0, 0.5, 0.5));
      expect(edit.rotatedClockwise().crop, const Rect.fromLTRB(0.5, 0, 1, 0.5));
    });

    test('反転は回転の向きを反転させて表す', () {
      const edit = ImageEdit(quarterTurns: 1);
      final flipped = edit.flipped();
      expect(flipped.flipHorizontal, isTrue);
      expect(flipped.quarterTurns, 3);
    });
  });

  group('トリミング枠の操作', () {
    test('隅を引くと枠が広がり、画像の外へは出ない', () {
      final crop = resizeCrop(
        const Rect.fromLTRB(0.25, 0.25, 0.75, 0.75),
        CropCorner.topLeft,
        const Offset(-0.5, -0.5),
      );
      expect(crop, const Rect.fromLTRB(0, 0, 0.75, 0.75));
    });

    test('隅を引いて縮めると指の位置が枠の角になる', () {
      final crop = resizeCrop(
        const Rect.fromLTRB(0, 0, 1, 1),
        CropCorner.topLeft,
        const Offset(0.25, 0.4),
      );
      expect(crop, const Rect.fromLTRB(0.25, 0.4, 1, 1));
    });

    test('引きすぎても最小の一辺は残る', () {
      final crop = resizeCrop(
        const Rect.fromLTRB(0, 0, 1, 1),
        CropCorner.topLeft,
        const Offset(1, 1),
      );
      expect(crop.width, closeTo(minCropSide, 1e-9));
      expect(crop.height, closeTo(minCropSide, 1e-9));
    });

    test('枠の移動は画像の中に収まる', () {
      final moved = moveCrop(
        const Rect.fromLTRB(0.5, 0.5, 1, 1),
        const Offset(0.3, 0.3),
      );
      expect(moved, const Rect.fromLTRB(0.5, 0.5, 1, 1));
    });
  });

  group('出力サイズ', () {
    test('回転・トリミング・長辺上限を順に効かせる', () {
      const edit = ImageEdit(
        quarterTurns: 1,
        crop: Rect.fromLTRB(0, 0, 1, 0.5),
        maxLongSide: 100,
      );
      // 400x200 → 回転で 200x400 → 上半分で 200x200 → 上限 100 で 100x100。
      expect(editedPixelSize(const Size(400, 200), edit), const Size(100, 100));
    });

    test('無編集なら再エンコードしない', () {
      expect(const ImageEdit().isIdentity, isTrue);
      expect(const ImageEdit(quarterTurns: 1).isIdentity, isFalse);
    });
  });

  group('レンダリング', () {
    test('時計回りに回すと赤い角が左上から右上へ移る', () {
      final out = _render(_cornerImage(), const ImageEdit(quarterTurns: 1));
      expect(out.width, 2);
      expect(out.height, 4);
      expect(_isRed(out.getPixel(1, 0)), isTrue);
      expect(_isRed(out.getPixel(0, 0)), isFalse);
    });

    test('左右反転すると赤い角が右上へ移る', () {
      final out = _render(
        _cornerImage(),
        const ImageEdit(flipHorizontal: true),
      );
      expect(out.width, 4);
      expect(_isRed(out.getPixel(3, 0)), isTrue);
    });

    test('トリミングは指定した範囲だけを残す', () {
      final out = _render(
        _splitImage(),
        const ImageEdit(crop: Rect.fromLTRB(0.5, 0, 1, 1)),
      );
      expect(out.width, 200);
      expect(out.height, 400);
      // 境界（x=205）より右＝白だけが残る。
      expect(out.getPixel(10, 0).r, 255);
    });

    test('長辺の上限まで縮める', () {
      final out = _render(
        _splitImage(width: 400, height: 200),
        const ImageEdit(maxLongSide: 100),
      );
      expect(out.width, 100);
      expect(out.height, 50);
    });

    test('黒塗りはなぞった所だけを黒くする', () {
      final out = _render(
        _splitImage(),
        const ImageEdit(
          strokes: [
            MaskStroke(
              points: [Offset(0.75, 0.5)],
              width: 0.1,
              kind: MaskKind.fill,
            ),
          ],
        ),
      );
      // 中心（300,200）は黒。
      expect(out.getPixel(300, 200).r, 0);
      // 半径は長辺の 5%＝20px。そこから離れた所は白のまま。
      expect(out.getPixel(340, 200).r, 255);
    });

    test('モザイクは境界をブロックごとに平均して潰す', () {
      final out = _render(
        _splitImage(),
        const ImageEdit(
          strokes: [
            MaskStroke(
              points: [Offset(0.5, 0.5)],
              width: 0.2,
              kind: MaskKind.mosaic,
            ),
          ],
        ),
      );
      // 境界（x=205）を含むブロックは黒と白が混ざって中間色になる。
      final mixed = out.getPixel(202, 200).r;
      expect(mixed, greaterThan(20));
      expect(mixed, lessThan(235));
      // なぞっていない所は元のまま。
      expect(out.getPixel(202, 20).r, 0);
    });

    test('PNG は PNG のまま、それ以外は JPEG で出す', () {
      final source = _splitImage(width: 40, height: 40);
      const edit = ImageEdit(quarterTurns: 1);

      final fromPng = renderImageEdit((
        Uint8List.fromList(img.encodePng(source)),
        edit,
      ));
      expect(isPng(fromPng), isTrue);
      expect(editedExtension(Uint8List.fromList(img.encodePng(source))), 'png');

      final jpegBytes = Uint8List.fromList(img.encodeJpg(source));
      final fromJpeg = renderImageEdit((jpegBytes, edit));
      expect(fromJpeg[0], 0xFF);
      expect(fromJpeg[1], 0xD8);
      expect(editedExtension(jpegBytes), 'jpg');
    });

    test('読めない画像は例外にする', () {
      expect(
        () => renderImageEdit((
          Uint8List.fromList([1, 2, 3]),
          const ImageEdit(quarterTurns: 1),
        )),
        throwsA(isA<ImageEditException>()),
      );
    });
  });
}
