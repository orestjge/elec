import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Res post(int number, String id) => Res(
  number: number,
  name: '名無し',
  mail: '',
  dateText: '2025/11/03(月) 02:14:51.907',
  dateTime: null,
  id: id,
  beId: null,
  body: '本文',
  kind: ResKind.normal,
  threadTitle: null,
);

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('ID は文字列ではなく identicon で出る', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: post(1, 'aBc1De2f'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    expect(find.byWidgetPredicate((w) => w is IdIcon && w.id == 'aBc1De2f'),
        findsOneWidget);
    expect(find.textContaining('ID:'), findsNothing);
  });

  testWidgets('ID なしの板では代わりの枠を出す', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: Res(
            number: 1,
            name: '',
            mail: '',
            dateText: '2025/11/03(月) 02:14:51.907',
            dateTime: null,
            id: null,
            beId: null,
            body: '本文',
            kind: ResKind.normal,
            threadTitle: null,
          ),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    // ID が無いと誰の書き込みかは分からないので identicon は出せない。それでも
    // 枠は出して、レスの切れ目とヘッダの左端を保つ。
    expect(find.byType(IdIcon), findsNothing);
    expect(find.byType(IdIconPlaceholder), findsOneWidget);
  });

  testWidgets('同一 ID が複数あるときだけ連番を添える', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            PostItem(res: post(1, 'aaa'), idCount: 1, idOrdinal: 1, onTapId: (_) {}),
            PostItem(res: post(2, 'bbb'), idCount: 3, idOrdinal: 2, onTapId: (_) {}),
          ],
        ),
      ),
    );

    // 単発の ID にはアイコンだけ。連投なら「何番目 / 合計」が付く。
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('1/1'), findsNothing);
  });

  testWidgets('アイコンには ID と連番を読み上げラベルとして持たせる', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrap(
        PostItem(res: post(1, 'aaa'), idCount: 2, idOrdinal: 1, onTapId: (_) {}),
      ),
    );

    // 絵そのものは読み上げられないので、元のチップの文言をラベルに残す。
    expect(find.bySemanticsLabel('ID:aaa (1/2)'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('スレ主のレスにだけ印を付ける', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            PostItem(
              res: post(1, 'aaa'),
              idCount: 1,
              idOrdinal: 1,
              onTapId: (_) {},
              isThreadOwner: true,
            ),
            PostItem(
              res: post(2, 'bbb'),
              idCount: 1,
              idOrdinal: 1,
              onTapId: (_) {},
            ),
          ],
        ),
      ),
    );

    expect(find.text('スレ主'), findsOneWidget);
  });

  testWidgets('アイコンをタップすると ID が返る', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: post(1, 'aaa'),
          idCount: 2,
          idOrdinal: 1,
          onTapId: tapped.add,
        ),
      ),
    );

    await tester.tap(find.byType(IdIcon));
    await tester.pump();

    expect(tapped, ['aaa']);
  });
}
