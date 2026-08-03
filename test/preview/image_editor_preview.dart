/// 画像編集画面の見た目を PNG に落とす確認用スクリプト。
///
/// **通常のテストでは走らない。** ファイル名が `_test.dart` で終わらないので
/// `flutter test`（`test/**_test.dart` を拾う）の対象外になる。撮るときだけ
/// パスを明示して実行する:
///
/// ```
/// flutter test test/preview/image_editor_preview.dart
/// ```
///
/// 出力先は既定で `notes/preview/`（.gitignore 対象）。`OUT` で変えられる。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/ui/image_editor_screen.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../support/preview_fonts.dart';

/// 写真らしく見えるダミー画像（斜めのグラデーションに図形と文字帯）。
/// トリミング枠・モザイクの効きが目で分かるように、細かい模様も入れる。
Uint8List _photoBytes({int width = 1200, int height = 900, bool jpeg = false}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final t = (x / width + y / height) / 2;
      image.setPixel(
        x,
        y,
        img.ColorRgb8(
          (40 + 180 * t).round(),
          (90 + 120 * (1 - t)).round(),
          (150 + 90 * t).round(),
        ),
      );
    }
  }
  img.fillCircle(
    image,
    x: width ~/ 3,
    y: height ~/ 2,
    radius: height ~/ 5,
    color: img.ColorRgb8(250, 220, 90),
  );
  // 「隠したい細かい情報」の代わり。モザイクの効きを見る。
  for (var i = 0; i < 22; i++) {
    img.fillRect(
      image,
      x1: width ~/ 2 + i * 24,
      y1: height ~/ 4,
      x2: width ~/ 2 + i * 24 + 12,
      y2: height ~/ 4 + 60,
      color: i.isEven
          ? img.ColorRgb8(20, 20, 20)
          : img.ColorRgb8(245, 245, 245),
    );
  }
  return Uint8List.fromList(
    jpeg ? img.encodeJpg(image, quality: 95) : img.encodePng(image),
  );
}

/// トリミング枠の左上を内側へ引く（比のプリセットは無いので手で縮める）。
/// [source] は表示中の画像のピクセルサイズ（回転後）。
Future<void> _dragCropCorner(WidgetTester tester, Size source) async {
  final preview = tester
      .getRect(find.byKey(const ValueKey('image-editor-preview')))
      .deflate(24);
  final scale = math.min(
    preview.width / source.width,
    preview.height / source.height,
  );
  // 画像は中央に収まる。左上のつまみはその左上にある。
  final image = Alignment.center.inscribe(
    Size(source.width * scale, source.height * scale),
    preview,
  );
  final gesture = await tester.startGesture(image.topLeft);
  await gesture.moveTo(image.topLeft + const Offset(30, 30));
  await gesture.moveTo(
    image.topLeft + Offset(image.width * 0.18, image.height * 0.22),
  );
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 実際の非同期処理（アイソレートでの書き出し）が終わるまで実時間で回す。
Future<void> _pumpRealAsync(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  bool jpeg = false,
  double width = 420,
  Future<void> Function(WidgetTester)? interact,
}) async {
  tester.view.physicalSize = Size(width * 2, 900 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final bytes = _photoBytes(jpeg: jpeg);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ImageEditorScreen(
          source: XFile.fromData(
            bytes,
            name: jpeg ? 'photo.jpg' : 'photo.png',
            path: jpeg ? 'photo.jpg' : 'photo.png',
          ),
          bytes: bytes,
        ),
      ),
    ),
  );

  // デコードはエンジン側の実際の非同期処理なので、fake async の外で待つ。
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }

  await interact?.call(tester);
  // チップの選択アニメーションが終わるまで進める（途中で撮ると ✓ が残る）。
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // 直前に描いたフレームがそのまま残ることがあるので、撮る前にもう一度描かせる。
  await tester.pump(const Duration(milliseconds: 100));

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  final file = File(out)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $out');
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  setUpAll(loadPreviewFonts);

  testWidgets('transform light', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/image_editor_transform.png');
  });

  testWidgets('transform dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/image_editor_transform_dark.png',
    );
  });

  // 右に回して枠を縮めた状態。つまみと三分割線の見え方を確認する。
  testWidgets('transform rotated', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_transform_rotated.png',
      interact: (tester) async {
        await tester.tap(find.byTooltip('右に回転'));
        await tester.pump(const Duration(milliseconds: 200));
        // 右に 90 度回した後なので縦横が入れ替わる。
        await _dragCropCorner(tester, const Size(900, 1200));
      },
    );
  });

  testWidgets('mask', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_mask.png',
      interact: (tester) => tester.tap(find.text('マスク')),
    );
  });

  // 切り抜いてからモザイクを引いた状態。枠の外が消えていること、なぞった所が
  // ブロックに潰れていることを見る。
  testWidgets('mask drawn', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_mask_drawn.png',
      interact: (tester) async {
        await _dragCropCorner(tester, const Size(1200, 900));
        await tester.tap(find.text('マスク'));
        await tester.pump(const Duration(milliseconds: 200));
        final preview = tester.getRect(
          find.byKey(const ValueKey('image-editor-preview')),
        );
        await tester.dragFrom(
          Offset(preview.left + preview.width * 0.3, preview.center.dy - 60),
          Offset(preview.width * 0.45, 0),
        );
      },
    );
  });

  // 2 本指で拡大した状態。細かい所を確かめながら塗る／枠を合わせるための操作。
  // 狭い端末。操作パネルの連結ボタンが溢れないかを見る（溢れると例外になる）。
  testWidgets('transform narrow', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_transform_narrow.png',
      width: 320,
    );
  });

  testWidgets('mask narrow', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_mask_narrow.png',
      width: 320,
      interact: (tester) => tester.tap(find.text('マスク')),
    );
  });

  testWidgets('mask zoomed', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_mask_zoomed.png',
      interact: (tester) async {
        await tester.tap(find.text('マスク'));
        await tester.pump(const Duration(milliseconds: 200));
        final preview = tester.getRect(
          find.byKey(const ValueKey('image-editor-preview')),
        );
        // 縞模様のあたりをつまんで広げる。
        final focal = Offset(preview.center.dx + 60, preview.center.dy - 60);
        final left = await tester.startGesture(focal - const Offset(30, 0));
        final right = await tester.startGesture(focal + const Offset(30, 0));
        await left.moveTo(focal - const Offset(90, 0));
        await right.moveTo(focal + const Offset(90, 0));
        await left.up();
        await right.up();
        await tester.pump(const Duration(milliseconds: 200));
        // 拡大したら 1 本指で動かせるように切り替える。
        await tester.tap(find.text('移動'));
        await tester.pump(const Duration(milliseconds: 200));
      },
    );
  });

  testWidgets('quality', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_quality.png',
      interact: (tester) => tester.tap(find.text('出力')),
    );
  });

  // JPEG を選んだとき（品質のつまみが出る側）。書き出し結果に差し替わるまで
  // 待ってから撮る（ファイルサイズのバッジもそこで確定する）。
  testWidgets('quality jpeg', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_editor_quality_jpeg.png',
      jpeg: true,
      interact: (tester) async {
        await tester.tap(find.text('出力'));
        await tester.pump(const Duration(milliseconds: 200));
        // 品質を下げて、書き出したものがプレビューに出るのを確かめる。
        final slider = tester.getRect(find.byType(Slider).last);
        await tester.tapAt(
          Offset(slider.left + slider.width * 0.05, slider.center.dy),
        );
        await _pumpRealAsync(tester);
      },
    );
  });
}
