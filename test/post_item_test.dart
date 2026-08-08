import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/now_ticker.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/res_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Res postWithBody(String body) => Res(
  number: 1,
  name: '名無し',
  mail: '',
  dateText: '2025/11/03(月) 02:14:51.907',
  dateTime: null,
  id: 'aaa',
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

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

    expect(
      find.byWidgetPredicate((w) => w is IdIcon && w.id == 'aBc1De2f'),
      findsOneWidget,
    );
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
            PostItem(
              res: post(1, 'aaa'),
              idCount: 1,
              idOrdinal: 1,
              onTapId: (_) {},
            ),
            PostItem(
              res: post(2, 'bbb'),
              idCount: 3,
              idOrdinal: 2,
              onTapId: (_) {},
            ),
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
        PostItem(
          res: post(1, 'aaa'),
          idCount: 2,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
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

  testWidgets('画像は貼られた位置に挟まり、URL の文字列は出さない', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('これ見て<br>https://example.com/a.jpg<br>どう？'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    // 本文は画像の前後で分かれ、サムネイルはその間に入る。
    expect(find.byType(ResBody), findsNWidgets(2));
    final images = tester.getRect(find.byType(PostImages));
    expect(
      tester.getRect(find.byType(ResBody).first).bottom,
      lessThanOrEqualTo(images.top),
    );
    expect(
      tester.getRect(find.byType(ResBody).last).top,
      greaterThanOrEqualTo(images.bottom),
    );

    // サムネイルを置いた URL は本文から消える。
    expect(find.textContaining('a.jpg', findRichText: true), findsNothing);
    expect(find.textContaining('これ見て', findRichText: true), findsOneWidget);
    expect(find.textContaining('どう？', findRichText: true), findsOneWidget);
  });

  testWidgets('サムネイルにできないリンクは本文に残す', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('ソース https://example.com/page.html'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    expect(find.byType(PostImages), findsNothing);
    expect(
      find.textContaining('https://example.com/page.html', findRichText: true),
      findsOneWidget,
    );
  });

  group('レス時刻', () {
    Res at(DateTime? whenUtc) => Res(
      number: 1,
      name: '名無し',
      mail: '',
      dateText: '2025/11/03(月) 02:14:51.907',
      dateTime: whenUtc,
      id: 'aaa',
      beId: null,
      body: '本文',
      kind: ResKind.normal,
      threadTitle: null,
    );

    Widget item(Res res) =>
        wrap(PostItem(res: res, idCount: 1, idOrdinal: 1, onTapId: (_) {}));

    // 秒の端数で「4分前」に転ばないよう、境界から離した時刻で見る。
    const fiveMinutesAgo = Duration(minutes: 5, seconds: 30);

    testWidgets('直近のレスは「n分前」で出る', (tester) async {
      await tester.pumpWidget(
        item(at(DateTime.now().toUtc().subtract(fiveMinutesAgo))),
      );

      expect(find.text('5分前'), findsOneWidget);
      expect(find.text('02:14'), findsNothing);
    });

    testWidgets('共有の時計が進めば、操作しなくても表示が進む', (tester) async {
      final now = DateTime.now();
      await tester.pumpWidget(item(at(now.toUtc().subtract(fiveMinutesAgo))));
      expect(find.text('5分前'), findsOneWidget);

      // レス側は何も変わらないまま、時計だけが 1 分進んだとき。
      nowTicker.value = now.add(const Duration(minutes: 1));
      await tester.pump();

      expect(find.text('6分前'), findsOneWidget);
    });

    testWidgets('1 日以上前のレスは時刻表記のまま', (tester) async {
      final res = at(DateTime.now().toUtc().subtract(const Duration(days: 2)));
      await tester.pumpWidget(item(res));

      expect(find.text('02:14'), findsOneWidget);
    });

    testWidgets('時刻の分からないレスでも dat の表記から時刻を出す', (tester) async {
      await tester.pumpWidget(item(at(null)));

      expect(find.text('02:14'), findsOneWidget);
    });
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
