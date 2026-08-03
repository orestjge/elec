/// 複数枚を送る前の一覧画面の見た目を PNG に落とす確認用スクリプト。
///
/// **通常のテストでは走らない**（ファイル名が `_test.dart` で終わらない）。
///
/// ```
/// flutter test test/preview/image_set_preview.dart
/// ```
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:elec/src/ui/image_set_screen.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../support/preview_fonts.dart';

/// サムネイルは端末上のファイルを読むので、実際にファイルを書いてから渡す。
List<XFile> _tempImages(Directory dir, int count) {
  return [for (var i = 0; i < count; i++) _writeImage(dir, i)];
}

XFile _writeImage(Directory dir, int index) {
  const width = 600;
  const height = 450;
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final t = (x / width + y / height) / 2;
      image.setPixel(
        x,
        y,
        img.ColorRgb8(
          (30 + 200 * t).round(),
          (60 + 150 * ((index + 1) / 6)).round(),
          (200 - 120 * t).round(),
        ),
      );
    }
  }
  img.fillCircle(
    image,
    x: width ~/ 2,
    y: height ~/ 2,
    radius: 60 + index * 12,
    color: img.ColorRgb8(250, 220, 90),
  );
  final file = File('${dir.path}/pick$index.png')
    ..writeAsBytesSync(img.encodePng(image));
  return XFile(file.path);
}

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  required List<XFile> files,
}) async {
  tester.view.physicalSize = const Size(420 * 2, 900 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ImageSetScreen(files: files),
      ),
    ),
  );

  // ファイルの読み込みは実際の非同期処理なので fake async の外で待つ。
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $out');
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';
  late Directory temp;

  setUpAll(() async {
    await loadPreviewFonts();
    temp = Directory.systemTemp.createTempSync('elec_image_set');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  testWidgets('set', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_set.png',
      files: _tempImages(temp, 4),
    );
  });

  testWidgets('set full', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/image_set_full.png',
      files: _tempImages(temp, 6),
    );
  });

  testWidgets('set dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/image_set_dark.png',
      files: _tempImages(temp, 4),
    );
  });
}
