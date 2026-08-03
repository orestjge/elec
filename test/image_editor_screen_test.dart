import 'dart:math' as math;
import 'dart:typed_data';

import 'package:elec/src/ui/image_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// 左上だけ赤、他は青の横長 PNG。回転・トリミングの結果を見分けられる。
Uint8List _sourceBytes({int width = 40, int height = 20}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixel(x, y, img.ColorRgb8(0, 0, 255));
    }
  }
  image.setPixel(0, 0, img.ColorRgb8(255, 0, 0));
  return Uint8List.fromList(img.encodePng(image));
}

/// 編集画面を push して、閉じたときに返ってきた XFile を受け取る。
class _Harness {
  _Harness(this.source);

  /// 編集画面へ渡した元ファイル。無編集ならこれがそのまま返る。
  final XFile source;
  XFile? result;
  bool closed = false;
}

Future<_Harness> _openEditor(WidgetTester tester, Uint8List bytes) async {
  final source = XFile.fromData(bytes, name: 'source.png', path: 'source.png');
  final harness = _Harness(source);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                harness.result = await Navigator.of(context).push<XFile>(
                  MaterialPageRoute<XFile>(
                    builder: (_) =>
                        ImageEditorScreen(source: source, bytes: bytes),
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
  // 画像のデコードは実際の非同期処理なので、fake async では進まない。
  await _settleAsync(tester);
  return harness;
}

/// デコードやアイソレートでの加工が終わるまで実時間で回す。
///
/// 待っている間は進捗インジケータが回り続けるので、pumpAndSettle は使えない。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<img.Image> _decodeResult(_Harness harness) async {
  expect(harness.closed, isTrue, reason: '編集画面が閉じていない');
  final file = harness.result;
  expect(file, isNotNull, reason: '画像が返っていない');
  return img.decodeImage(await file!.readAsBytes())!;
}

bool _isRed(img.Pixel p) => p.r > 200 && p.g < 60 && p.b < 60;

/// 画面に出ている画像の矩形。編集画面と同じ収め方（内側 24px を空けて中央）で
/// 求める。つまみを掴む位置を出すのに使う。
Rect _imageRect(WidgetTester tester, Size source) {
  final preview = tester
      .getRect(find.byKey(const ValueKey('image-editor-preview')))
      .deflate(24);
  final scale = math.min(
    preview.width / source.width,
    preview.height / source.height,
  );
  return Alignment.center.inscribe(
    Size(source.width * scale, source.height * scale),
    preview,
  );
}

void main() {
  testWidgets('何もせず「完了」すると元のファイルがそのまま返る', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await tester.pumpAndSettle();

    // 再エンコードしないので画質が落ちない。編集せず送る専用ボタンは要らない。
    expect(harness.closed, isTrue);
    expect(harness.result, same(harness.source));
  });

  testWidgets('戻る（キャンセル）では何も返さない', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(harness.closed, isTrue);
    expect(harness.result, isNull);
  });

  testWidgets('右に回転して完了すると縦横が入れ替わる', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.byTooltip('右に回転'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    expect(out.width, 20);
    expect(out.height, 40);
    // 左上にあった赤が右上へ来る。
    expect(_isRed(out.getPixel(19, 0)), isTrue);
  });

  testWidgets('枠の左上を引くとその位置から切り出される', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    final image = _imageRect(tester, const Size(40, 20));
    // 左上のつまみを内側へ 1/4 だけ動かす。
    final gesture = await tester.startGesture(image.topLeft);
    await gesture.moveTo(image.topLeft + const Offset(20, 20));
    await gesture.moveTo(
      image.topLeft + Offset(image.width * 0.25, image.height * 0.25),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    expect(out.width, 30);
    expect(out.height, 15);
    // 左上にあった赤は切り落とされている。
    expect(_isRed(out.getPixel(0, 0)), isFalse);
  });

  testWidgets('つまみから少し離れていても掴める', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    final image = _imageRect(tester, const Size(40, 20));
    // 角から斜めに 35px ほど内側。見えているつまみの腕（18px）より遠く、
    // 判定を広げる前は「枠ごと移動」になっていた場所。
    final grab = image.topLeft + const Offset(25, 25);
    final gesture = await tester.startGesture(grab);
    await gesture.moveTo(grab + const Offset(20, 20));
    await gesture.moveTo(
      image.topLeft + Offset(image.width * 0.25, image.height * 0.25),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    expect(out.width, 30, reason: 'つまみを掴めていれば切り抜かれる');
    expect(out.height, 15);
  });

  testWidgets('解像度のつまみを左へ動かすと縮小される', (tester) async {
    final bytes = _sourceBytes(width: 800, height: 400);
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('出力'));
    await tester.pumpAndSettle();

    // 元画像より大きい段階（中 1280・大 1920）は目盛りに無いので、
    // 段階は「小」と「原寸」の 2 つ。既定は右端＝原寸。
    expect(find.text('原寸 800×400'), findsOneWidget);

    // 解像度のつまみ（上の行）を左端へ。
    final slider = tester.getRect(find.byType(Slider).first);
    await tester.tapAt(Offset(slider.left + 4, slider.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('小 640×320'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    expect(out.width, 640);
    expect(out.height, 320);
  });

  testWidgets('出力タブでは書き出したファイルサイズが出る', (tester) async {
    final bytes = _sourceBytes(width: 800, height: 400);
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('出力'));
    await tester.pumpAndSettle();
    // 無編集なら元のバイト列がそのまま送られる。作り直さずに大きさが出る。
    expect(find.text('${(bytes.length / 1024).round()} KB'), findsOneWidget);

    // 縮小すると、実際に書き出したものの大きさへ変わる。
    final slider = tester.getRect(find.byType(Slider).first);
    await tester.tapAt(Offset(slider.left + 4, slider.center.dy));
    // 手が止まってから書き出す（デバウンス）ので、その分も待つ。
    await _settleAsync(tester);
    await _settleAsync(tester);

    final badge = tester.widget<Text>(
      find.byKey(const ValueKey('image-editor-output-size')),
    );
    expect(badge.data, isNot(contains('書き出し中')));
    final kb = int.parse(RegExp(r'\d+').firstMatch(badge.data!)!.group(0)!);
    expect(kb, lessThan((bytes.length / 1024).round()));

    // 書き出し済みなので、完了しても同じバイト列がそのまま返る。
    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);
    final out = await _decodeResult(harness);
    expect(out.width, 640);
  });

  testWidgets('PNG では品質のつまみが無効になる', (tester) async {
    final bytes = _sourceBytes(width: 800, height: 400);
    await _openEditor(tester, bytes);

    await tester.tap(find.text('出力'));
    await tester.pumpAndSettle();

    expect(find.text('設定不可'), findsOneWidget);
    // 品質は 2 本目のつまみ。PNG では動かせない。
    expect(tester.widget<Slider>(find.byType(Slider).last).onChanged, isNull);
  });

  testWidgets('黒塗りでなぞった所が塗りつぶされる', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('マスク'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黒塗り'));
    await tester.pumpAndSettle();

    // プレビューの中央付近を横になぞる。画像は中央に収まるので、中央＝画像の中央。
    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    await tester.dragFrom(
      preview.center - const Offset(40, 0),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    final center = out.getPixel(out.width ~/ 2, out.height ~/ 2);
    expect(center.r, 0);
    expect(center.b, 0, reason: '青のままなら塗れていない');
    // 上端は触っていないので青のまま。
    expect(out.getPixel(out.width ~/ 2, 0).b, 255);
  });

  testWidgets('拡大してから塗ると、狭い範囲だけが塗られる', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('マスク'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黒塗り'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    // 2 本指で中央を 2 倍に広げる。
    final left = await tester.startGesture(
      preview.center - const Offset(20, 0),
    );
    final right = await tester.startGesture(
      preview.center + const Offset(20, 0),
    );
    await left.moveTo(preview.center - const Offset(40, 0));
    await right.moveTo(preview.center + const Offset(40, 0));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    // 画面の端から端まで引いても、拡大しているので画像の中央付近しか塗れない。
    await tester.dragFrom(
      Offset(preview.left + 20, preview.center.dy),
      Offset(preview.width - 40, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await _settleAsync(tester);

    final out = await _decodeResult(harness);
    expect(out.getPixel(out.width ~/ 2, out.height ~/ 2).b, 0, reason: '中央は黒');
    expect(out.getPixel(2, out.height ~/ 2).b, 255, reason: '左端は青のまま');
  });

  testWidgets('出力タブの 1 本指ドラッグは移動で、絵は変わらない', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('出力'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    await tester.dragFrom(preview.center, const Offset(60, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await tester.pumpAndSettle();

    // 何も編集していないので元のファイルがそのまま返る。
    expect(harness.result, same(harness.source));
  });

  testWidgets('つまんで拡大しただけでは線が残らない', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('マスク'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    final left = await tester.startGesture(
      preview.center - const Offset(20, 0),
    );
    final right = await tester.startGesture(
      preview.center + const Offset(20, 0),
    );
    await left.moveTo(preview.center - const Offset(60, 0));
    await right.moveTo(preview.center + const Offset(60, 0));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await tester.pumpAndSettle();

    // つまむときは片方の指が先に着くが、それを線として残してはいけない。
    expect(harness.result, same(harness.source));
  });

  testWidgets('移動に切り替えると 1 本指で塗らなくなる', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('マスク'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移動'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    await tester.dragFrom(
      preview.center - const Offset(40, 0),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await tester.pumpAndSettle();

    expect(harness.result, same(harness.source), reason: '線が引かれてはいけない');
  });

  testWidgets('1 つ戻すでマスクを取り消せる', (tester) async {
    final bytes = _sourceBytes();
    final harness = await _openEditor(tester, bytes);

    await tester.tap(find.text('マスク'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黒塗り'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('image-editor-preview')),
    );
    await tester.dragFrom(
      preview.center - const Offset(40, 0),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('1 つ戻す'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-editor-done')));
    await tester.pumpAndSettle();

    // 編集が残っていなければ再エンコードせず元ファイルが返る。
    expect(harness.result, same(harness.source));
  });
}
