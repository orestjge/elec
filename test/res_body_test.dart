import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/res_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AA らしい複数行本文を検出する', () {
    const aa = '''
　　 ∧＿∧
　　（　´∀｀）
　　（　　　　）
''';

    expect(looksLikeAsciiArt(aa), isTrue);
    expect(looksLikeAsciiArt('これは普通の本文です（テスト）'), isFalse);
  });

  test('記号が多いだけの本文は AA 扱いしない', () {
    expect(looksLikeAsciiArt('これは（テスト）です。[] や () や -- が多くても普通の本文です。'), isFalse);
    expect(
      looksLikeAsciiArt('（1）まず本文です。\n（2）次も本文です。---- 区切りではありません。'),
      isFalse,
    );
  });

  test('URL は AA 判定の記号として数えない', () {
    expect(
      looksLikeAsciiArt('https://example.com/a/b/c/d/e/f/g/h/i/j?x=1&y=2'),
      isFalse,
    );
    expect(
      looksLikeAsciiArt(
        '動画\n'
        'https://example.com/a/b/c/d/e/f/g/h/i/j?x=1&y=2\n'
        'ttps://example.net/watch/abc_def-ghi?format=mp4',
      ),
      isFalse,
    );
  });

  test('普通のレスは前後の空白・空行を詰める', () {
    expect(trimUnlessAsciiArt('  前後に空白  '), '前後に空白');
    expect(trimUnlessAsciiArt('\n\n本文\n\n'), '本文');
    // 内部の改行は保持する。
    expect(trimUnlessAsciiArt('\n1行目\n2行目\n'), '1行目\n2行目');
  });

  test('AA はインデント・上下の余白をそのまま残す', () {
    const aa = '''
　　 ∧＿∧
　　（　´∀｀）
　　（　　　　）
''';
    expect(trimUnlessAsciiArt(aa), aa);
  });

  testWidgets('AA 本文は Monapo で横スクロール表示する', (tester) async {
    const aa = '''
　　 ∧＿∧
　　（　´∀｀）
　　（　　　　） >>1
''';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(text: aa, onTapRes: (_) {}, onTapUrl: (_) {}),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );

    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.textSpan?.style?.fontFamily, 'Monapo');
  });

  testWidgets('通常本文は通常表示のままにする', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            text: 'これは普通の本文です >>1',
            onTapRes: (_) {},
            onTapUrl: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsNothing);
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.textSpan?.style?.fontFamily, isNull);
  });

  testWidgets('貼られたレスの ID に identicon を添えてタップ可能にする', (tester) async {
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            text:
                '24 エッヂの名無し 2026/08/08(土) 00:00:00.000 ID:X9Jh576dp\n'
                'ゆめちゃんきたよぉ',
            onTapRes: (_) {},
            onTapUrl: (_) {},
            onTapId: tapped.add,
          ),
        ),
      ),
    );

    final icon = tester.widget<IdIcon>(find.byType(IdIcon));
    expect(icon.id, 'X9Jh576dp');

    await tester.tap(find.byType(IdIcon));
    expect(tapped, ['X9Jh576dp']);
  });

  testWidgets('ID を押せない場所でも identicon は出す', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            text: 'ID:X9Jh576dp',
            onTapRes: (_) {},
            onTapUrl: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(IdIcon), findsOneWidget);
  });

  testWidgets('ID らしくない ID: 表記は加工しない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            // 短すぎるもの、英数字に続くもの、URL の一部。
            text:
                'ID:me と GRID:X9Jh576dp と\n'
                'https://example.com/x?ID=X9Jh576dp',
            onTapRes: (_) {},
            onTapUrl: (_) {},
            onTapId: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(IdIcon), findsNothing);
  });
}
