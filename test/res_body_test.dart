import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/res_body.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本文中の [label] という文字の span を返す（レス参照・URL の当たり判定用）。
TextSpan _linkSpan(WidgetTester tester, String label) {
  final root = tester.widget<SelectableText>(find.byType(SelectableText));
  TextSpan? found;
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text == label) found ??= span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child);
    }
  }

  walk(root.textSpan!);
  expect(found, isNotNull, reason: '「$label」の span が無い');
  return found!;
}

/// 本文の素の文字（リンクでない部分）をつなげたもの。
String _plainText(WidgetTester tester) {
  final root = tester.widget<SelectableText>(find.byType(SelectableText));
  final buffer = StringBuffer();
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.recognizer == null && span.text != null) buffer.write(span.text);
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child);
    }
  }

  walk(root.textSpan!);
  return buffer.toString();
}

void tapLink(WidgetTester tester, String label) {
  final recognizer = _linkSpan(tester, label).recognizer;
  (recognizer! as TapGestureRecognizer).onTap!();
}

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

  group('レス参照', () {
    Future<void> pump(
      WidgetTester tester,
      String text, {
      ValueChanged<int>? onTapRes,
      ValueChanged<List<int>>? onTapResRange,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            text: text,
            onTapRes: onTapRes ?? (_) {},
            onTapResRange: onTapResRange,
            onTapUrl: (_) {},
          ),
        ),
      ),
    );

    testWidgets('カンマ区切りのまとめ書きを 1 つの参照として開く', (tester) async {
      final ranges = <List<int>>[];
      await pump(tester, 'これ >>1,3,5 まとめて', onTapResRange: ranges.add);

      tapLink(tester, '>>1,3,5');
      expect(ranges, [
        [1, 3, 5],
      ]);
    });

    testWidgets('カンマと範囲の混在も開く', (tester) async {
      final ranges = <List<int>>[];
      await pump(tester, '>>1,4-6', onTapResRange: ranges.add);

      tapLink(tester, '>>1,4-6');
      expect(ranges, [
        [1, 4, 5, 6],
      ]);
    });

    testWidgets('dat のエスケープ越しでも >> 表記で出す', (tester) async {
      final ranges = <List<int>>[];
      await pump(tester, '&gt;&gt;2,4 テスト', onTapResRange: ranges.add);

      tapLink(tester, '>>2,4');
      expect(ranges, [
        [2, 4],
      ]);
    });

    testWidgets('一覧を出せない場所では先頭のレスへ飛ぶ', (tester) async {
      final tapped = <int>[];
      await pump(tester, '>>3,8', onTapRes: tapped.add);

      tapLink(tester, '>>3,8');
      expect(tapped, [3]);
    });

    testWidgets('読点は区切りに含めず地の文のまま残す', (tester) async {
      final tapped = <int>[];
      final ranges = <List<int>>[];
      await pump(
        tester,
        '>>1、2人ともありがとう',
        onTapRes: tapped.add,
        onTapResRange: ranges.add,
      );

      tapLink(tester, '>>1');
      expect(tapped, [1]);
      expect(ranges, isEmpty);
      expect(_plainText(tester), '、2人ともありがとう');
    });
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

  testWidgets('`.` や `/` で始まる・終わる ID もまるごと拾う', (tester) async {
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            text:
                '24 名無し 2026/08/08(土) 00:00:00.000 ID:.fNwf8r5\n'
                '25 名無し 2026/08/08(土) 00:00:01.000 ID:0.fNwf8.\n'
                '26 名無し 2026/08/08(土) 00:00:02.000 ID:/9Jh576/',
            onTapRes: (_) {},
            onTapUrl: (_) {},
            onTapId: tapped.add,
          ),
        ),
      ),
    );

    final icons = tester
        .widgetList<IdIcon>(find.byType(IdIcon))
        .map((i) => i.id)
        .toList();
    expect(icons, ['.fNwf8r5', '0.fNwf8.', '/9Jh576/']);

    await tester.tap(find.byType(IdIcon).first);
    expect(tapped, ['.fNwf8r5']);
  });

  testWidgets('ID らしくない ID: 表記は加工しない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResBody(
            // 短すぎるもの、英数字に続くもの、英数字を含まないもの、
            // ID に使わない字を含むもの、URL の一部。
            text:
                'ID:me と GRID:X9Jh576dp と ID:...... と\n'
                'ID:non-existent と\n'
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
