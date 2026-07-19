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
}
