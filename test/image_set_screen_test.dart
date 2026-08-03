import 'dart:typed_data';

import 'package:elec/src/ui/image_set_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// 一色の小さな PNG。サムネイルは実ファイルを読むので、ここでは中身を描けない
/// （`errorBuilder` の壊れアイコンが出る）。この画面の担当は枚数の管理なので、
/// 絵の中身までは見ない。
Uint8List _bytes(int r, int g, int b) {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

List<XFile> _files(int count) => [
  for (var i = 0; i < count; i++)
    XFile.fromData(
      _bytes(i * 40, 100, 200),
      name: 'pick$i.png',
      path: 'pick$i.png',
    ),
];

class _Harness {
  List<XFile>? result;
  bool closed = false;
}

Future<_Harness> _open(WidgetTester tester, List<XFile> files) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                harness.result = await Navigator.of(context).push<List<XFile>>(
                  MaterialPageRoute<List<XFile>>(
                    builder: (_) => ImageSetScreen(files: files),
                  ),
                );
                harness.closed = true;
              },
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開く'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('選んだ枚数だけ並び、そのまま送信できる', (tester) async {
    final files = _files(3);
    final harness = await _open(tester, files);

    expect(find.text('3 枚の画像'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-set-tile-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-set-tile-2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-set-send')));
    await tester.pumpAndSettle();

    expect(harness.closed, isTrue);
    expect(harness.result, files);
  });

  testWidgets('× で 1 枚外すと、その 1 枚は送られない', (tester) async {
    final files = _files(3);
    final harness = await _open(tester, files);

    await tester.tap(find.byTooltip('外す').first);
    await tester.pumpAndSettle();
    expect(find.text('2 枚の画像'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-set-send')));
    await tester.pumpAndSettle();

    expect(harness.result, [files[1], files[2]]);
  });

  testWidgets('全部外すと送信できない', (tester) async {
    final harness = await _open(tester, _files(2));

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('外す').first);
      await tester.pumpAndSettle();
    }

    final send = find.byKey(const ValueKey('image-set-send'));
    expect(tester.widget<ButtonStyleButton>(send).onPressed, isNull);
    expect(harness.closed, isFalse);
  });

  testWidgets('戻る（キャンセル）では何も返さない', (tester) async {
    final harness = await _open(tester, _files(2));

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(harness.closed, isTrue);
    expect(harness.result, isNull);
  });

  testWidgets('サムネイルをタップすると編集画面が開く', (tester) async {
    await _open(tester, _files(2));

    await tester.tap(find.byKey(const ValueKey('image-set-tile-0')));
    // 編集画面はデコード中に進捗インジケータを回すので pumpAndSettle は使えない。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('画像を編集'), findsOneWidget);
  });
}
