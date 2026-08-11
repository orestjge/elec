import 'package:elec/src/ui/collapsible.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [height] の中身を [CollapsingBody] に入れて出す。
Future<void> pumpBody(
  WidgetTester tester, {
  required double height,
  bool expanded = false,
  bool showLineCount = true,
  VoidCallback? onExpand,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CollapsingBody(
            expanded: expanded,
            showLineCount: showLineCount,
            onExpand: onExpand ?? () {},
            child: Container(
              height: height,
              width: 300,
              color: const Color(0xFF3355FF),
            ),
          ),
        ),
      ),
    ),
  );
  // 高さを測ってから「続きを読む」を出すので、1 フレーム余分に進める。
  await tester.pump();
}

/// 畳まれた後の見かけの高さ。
double heightOf(WidgetTester tester) =>
    tester.getSize(find.byType(CollapsingBody)).height;

void main() {
  testWidgets('短い中身はそのまま出す', (tester) async {
    await pumpBody(tester, height: 200);
    expect(heightOf(tester), 200);
    expect(find.textContaining('あと'), findsNothing);
  });

  testWidgets('ちょうど上限なら畳まない', (tester) async {
    await pumpBody(tester, height: collapsedPostMaxHeight);
    expect(heightOf(tester), collapsedPostMaxHeight);
    expect(find.textContaining('あと'), findsNothing);
  });

  testWidgets('少しでも切ったら必ず「続きを読む」を出す', (tester) async {
    // 頭打ちは測る前から効いている。ここで畳むのをやめる（＝手心を加える）と、
    // そのぶんが**ボタンも出ないまま黙って切れる**ことになる。
    await pumpBody(tester, height: collapsedPostMaxHeight + 10);
    expect(heightOf(tester), collapsedPostMaxHeight);
    expect(find.textContaining('あと'), findsOneWidget);
  });

  testWidgets('長い中身は上限で頭打ちにして続きを読ませる', (tester) async {
    await pumpBody(tester, height: 2000);
    expect(heightOf(tester), collapsedPostMaxHeight);
    expect(find.textContaining('あと'), findsOneWidget);
  });

  testWidgets('隠したぶんを行数で伝える', (tester) async {
    // 1 行 21dp。1000 - 560 = 440 → 21 行。
    await pumpBody(tester, height: 1000);
    expect(find.text('あと21行ほど'), findsOneWidget);
  });

  testWidgets('絵が混じるレスでは行数を言わない', (tester) async {
    await pumpBody(tester, height: 2000, showLineCount: false);
    expect(find.text('続きを読む'), findsOneWidget);
    expect(find.textContaining('行'), findsNothing);
  });

  testWidgets('押すと外へ知らせる', (tester) async {
    var expanded = 0;
    await pumpBody(tester, height: 2000, onExpand: () => expanded++);
    await tester.tap(find.textContaining('あと'));
    await tester.pump();
    expect(expanded, 1);
  });

  testWidgets('開いていれば畳まない', (tester) async {
    await pumpBody(tester, height: 2000, expanded: true);
    expect(heightOf(tester), 2000);
    expect(find.textContaining('あと'), findsNothing);
  });

  testWidgets('最初の 1 フレームから頭打ちになっている', (tester) async {
    // 測り終わるのを待って畳むと、伸びきった姿が一瞬出てから縮む。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CollapsingBody(
              expanded: false,
              onExpand: () {},
              child: const SizedBox(height: 2000, width: 300),
            ),
          ),
        ),
      ),
    );
    // pump を足さずに測る＝組み立て直後の高さ。
    expect(heightOf(tester), collapsedPostMaxHeight);
  });

  testWidgets('畳んだ中で中身が伸びても外の高さは変わらない', (tester) async {
    // サムネイルが読み込まれて比率が分かった瞬間に起きること。畳んでいる間は
    // 下のレスへ波及しない。
    Widget body(double height) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CollapsingBody(
            expanded: false,
            onExpand: () {},
            child: SizedBox(height: height, width: 300),
          ),
        ),
      ),
    );
    await tester.pumpWidget(body(1000));
    await tester.pump();
    final before = heightOf(tester);
    await tester.pumpWidget(body(1400));
    await tester.pump();
    expect(heightOf(tester), before);
  });
}
