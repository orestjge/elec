import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/now_ticker.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/res_body.dart';
import 'package:elec/src/ui/thread_tree.dart';
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

Res postNamed(String name) => Res(
  number: 1,
  name: name,
  mail: '',
  dateText: '2025/11/03(月) 02:14:51.907',
  dateTime: null,
  id: 'aaa',
  beId: null,
  body: '本文',
  kind: ResKind.normal,
  threadTitle: null,
);

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  // 絵で出す組み方（柱・ヘッダ）で成り立つ性質——絵が出る、押せる、ID の文字は
  // 出さない——を両方で確かめる。組み方を切り替えたときに片方だけ壊れるのを防ぐ。
  // クラシックは逆に「文字で出す」組み方なので、下に別のテストがある。
  for (final layout in [ResLayout.gutter, ResLayout.header]) {
    testWidgets('$layout でも identicon は出て、押すと ID を渡す', (tester) async {
      String? tapped;
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post(1, 'aBc1De2f'),
            idCount: 1,
            idOrdinal: 1,
            resLayout: layout,
            onTapId: (id) => tapped = id,
          ),
        ),
      );

      expect(
        find.byWidgetPredicate((w) => w is IdIcon && w.id == 'aBc1De2f'),
        findsOneWidget,
      );
      expect(find.textContaining('ID:'), findsNothing);
      // 時刻はどちらの組み方でも必ずどこかに出る（ヘッダか、レスの足元か）。
      expect(find.textContaining('02:14'), findsOneWidget);

      await tester.tap(find.byType(IdIcon));
      expect(tapped, 'aBc1De2f');
    });
  }

  group('クラシックの組み方', () {
    testWidgets('レス番号・名前・日時・ID を文字のまま並べ、絵は出さない', (tester) async {
      String? tapped;
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post(7, 'aBc1De2f'),
            idCount: 1,
            idOrdinal: 1,
            resLayout: ResLayout.classic,
            defaultName: '名無し',
            onTapId: (id) => tapped = id,
          ),
        ),
      );

      expect(find.byType(IdIcon), findsNothing);
      // 番号・ID の文字列・dat の日時表記（秒とコンマ以下まで）。
      expect(find.text('7'), findsOneWidget);
      expect(find.textContaining('ID:aBc1De2f'), findsOneWidget);
      expect(find.text('2025/11/03(月) 02:14:51.907'), findsOneWidget);
      // 名無しも省かない。他の組み方では板の既定名と同じ名前は落としている。
      expect(find.text('名無し'), findsOneWidget);

      await tester.tap(find.textContaining('ID:aBc1De2f'));
      expect(tapped, 'aBc1De2f');
    });

    testWidgets('その ID の何本目かは ID の直後に付ける', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post(1, 'aBc1De2f'),
            idCount: 15,
            idOrdinal: 2,
            resLayout: ResLayout.classic,
            onTapId: (_) {},
          ),
        ),
      );

      // ID と同じひとかたまりにする。離すと何の数字か読めない。
      expect(find.textContaining('ID:aBc1De2f (2/15)'), findsOneWidget);
    });

    testWidgets('名前の後ろのワッチョイだけ 1 段小さく出す', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: postNamed('エッヂの名無し (L20 ipkW-6PVw)'),
            idCount: 1,
            idOrdinal: 1,
            resLayout: ResLayout.classic,
            defaultName: 'エッヂの名無し',
            onTapWacchoi: (_) {},
            onTapId: (_) {},
          ),
        ),
      );

      // 名前は省かず全部出す。ただし括弧の中は名前より小さい字（ID や日時と
      // 同じ labelMedium）で、名乗りのほうが強く読めるようにする。
      final name = tester.widget<Text>(
        find.textContaining('エッヂの名無し', findRichText: false).first,
      );
      final root = name.textSpan! as TextSpan;
      final spans = root.children!.cast<TextSpan>();
      // 名前は根の字のまま、括弧の中だけ小さい字を持つ。
      expect(spans.first.style, isNull);
      expect(spans.first.toPlainText(), 'エッヂの名無し');
      expect(spans.last.toPlainText(), contains('ipkW-6PVw'));
      expect(spans.last.style!.fontSize, lessThan(root.style!.fontSize!));
    });

    testWidgets('返信数はレス番号の直後に置く', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post(3, 'aBc1De2f'),
            idCount: 1,
            idOrdinal: 1,
            resLayout: ResLayout.classic,
            replyCount: 5,
            onTapReplies: (_) {},
            onTapId: (_) {},
          ),
        ),
      );

      // 番号 → 返信数 → 名前 の順。専ブラが昔からこの位置に置いている。
      final number = tester.getTopLeft(find.text('3')).dx;
      final replies = tester.getTopLeft(find.text('5')).dx;
      final name = tester.getTopLeft(find.text('名無し')).dx;
      expect(number, lessThan(replies));
      expect(replies, lessThan(name));
    });
  });

  group('行を単独で占める >>N', () {
    Res quoted(int number) => Res(
      number: number,
      name: '名無し',
      mail: '',
      dateText: '2025/11/03(月) 02:14:51.907',
      dateTime: null,
      id: 'aaa',
      beId: null,
      body: '指されたレスの本文',
      kind: ResKind.normal,
      threadTitle: null,
    );

    testWidgets('書かれた位置に返信先を差し込む', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: postWithBody('&gt;&gt;1<br>それな'),
            idCount: 1,
            idOrdinal: 1,
            onTapId: (_) {},
            quotedRes: (n) => n == 1 ? quoted(n) : null,
            inlineQuotes: const {1},
          ),
        ),
      );

      // 番号の文字ではなく、指し先の中身が出る（柱の組み方なので番号は出ない）。
      expect(find.byType(QuotedResRow), findsOneWidget);
      expect(find.textContaining('指されたレスの本文'), findsOneWidget);
      expect(find.textContaining('>>1'), findsNothing);
      expect(find.textContaining('それな'), findsOneWidget);
    });

    testWidgets('指し先を引けない場所では、番号の文字のまま出す', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: postWithBody('&gt;&gt;1<br>それな'),
            idCount: 1,
            idOrdinal: 1,
            onTapId: (_) {},
          ),
        ),
      );

      expect(find.byType(QuotedResRow), findsNothing);
      expect(find.textContaining('それな'), findsOneWidget);
    });

    testWidgets('文の頭に付いているだけの >>N は差し替えない', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: postWithBody('&gt;&gt;1 それな'),
            idCount: 1,
            idOrdinal: 1,
            onTapId: (_) {},
            quotedRes: (n) => quoted(n),
            inlineQuotes: const {1},
          ),
        ),
      );

      // ここはレスの手前に引用行が出る形（一覧側が組む）なので、本文は本文のまま。
      expect(find.byType(QuotedResRow), findsNothing);
      expect(find.textContaining('それな'), findsOneWidget);
    });
  });

  testWidgets('ヘッダに出すものが無いレスでは、柱の組み方はヘッダの行を作らない', (tester) async {
    // 名無し・返信なし・スレ主でも自分でもないレス。板の既定名を渡すと名前が
    // 省かれ、ヘッダに出すものが何も無くなる。ヘッダの行を出すと、時刻だけが
    // 右端に浮いた空の行になる。
    final res = post(1, 'aBc1De2f');
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            PostItem(
              res: res,
              idCount: 1,
              idOrdinal: 1,
              defaultName: '名無し',
              onTapId: (_) {},
            ),
          ],
        ),
      ),
    );
    final gutterHeight = tester.getSize(find.byType(PostItem)).height;

    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            PostItem(
              res: res,
              idCount: 1,
              idOrdinal: 1,
              resLayout: ResLayout.header,
              defaultName: '名無し',
              onTapId: (_) {},
            ),
          ],
        ),
      ),
    );
    final headerHeight = tester.getSize(find.byType(PostItem)).height;

    // 柱の組み方のほうが絵は大きいのに、行が 1 本減るぶん高さは増えない。
    expect(gutterHeight, lessThanOrEqualTo(headerHeight));
  });

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

  /// スレ主の印。**組み方で見せ方が変わる**——柱では絵に重ねた★、ヘッダに
  /// まとめる組み方では単独の★、クラシックでは ID に添える★。どれも字は
  /// 出さず、読み上げにだけ「スレ主」を渡すので、そこで確かめる。
  testWidgets('スレ主のレスにだけ印を付ける', (tester) async {
    for (final layout in ResLayout.values) {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        wrap(
          Column(
            children: [
              PostItem(
                res: post(1, 'aaa'),
                idCount: 1,
                idOrdinal: 1,
                resLayout: layout,
                onTapId: (_) {},
                isThreadOwner: true,
              ),
              PostItem(
                res: post(2, 'bbb'),
                idCount: 1,
                idOrdinal: 1,
                resLayout: layout,
                onTapId: (_) {},
              ),
            ],
          ),
        ),
      );

      expect(
        find.bySemanticsLabel(RegExp('スレ主')),
        findsOneWidget,
        reason: '$layout',
      );
      // 字は出さない。読んでいる間じゅう目に入る場所に置くには強い言い方なので、
      // 記号だけにして、言葉は NG のメニューと NG 管理の画面に残してある。
      expect(find.text('スレ主'), findsNothing, reason: '$layout');
      handle.dispose();
    }
  });

  testWidgets('柱の組み方ではスレ主の印を絵に重ね、ヘッダの行を増やさない', (tester) async {
    Future<double> heightOf({required bool isThreadOwner}) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post(1, 'aaa'),
            idCount: 1,
            idOrdinal: 1,
            onTapId: (_) {},
            isThreadOwner: isThreadOwner,
          ),
        ),
      );
      return tester.getSize(find.byType(PostItem)).height;
    }

    // 文字の札はヘッダの行を 1 つ要求していた。印を絵へ移した今は、スレ主でも
    // 名無し・返信なしなら出すものが無く、行ごと消える＝高さが変わらない。
    expect(
      await heightOf(isThreadOwner: true),
      await heightOf(isThreadOwner: false),
    );
    expect(find.text('スレ主'), findsNothing);
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

  testWidgets('サムネイルの長押しは、レスの長押しに吸われない', (tester) async {
    // レスもサムネイルも長押しでメニューを出す。どちらが出るかは長押しの長さで
    // 決まるので（`long_press.dart`）、内側のサムネイルが勝つことを縛る。
    var resMenu = 0;
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('これ見て<br>https://example.com/a.jpg'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          onLongPress: () => resMenu += 1,
        ),
      ),
    );

    await tester.longPress(find.byType(PostImages));
    await tester.pumpAndSettle();

    expect(find.text('この画像をNG'), findsOneWidget);
    expect(resMenu, 0);

    // レスの本文側は今まで通りレスのメニューへ繋ぐ。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(ResBody).first);
    await tester.pumpAndSettle();
    expect(resMenu, 1);
  });

  testWidgets('サムネイルを押している間はレスではなく絵が沈む', (tester) async {
    // 開くのは絵のメニューなので、レス全体が広がると的が違って見える。
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('これ見て<br>https://example.com/a.jpg'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          onLongPress: () {},
        ),
      ),
    );

    // レスの沈み込みを描く層。
    final spread = find.byWidgetPredicate(
      (w) => w is CustomPaint && '${w.painter.runtimeType}'.contains('Spread'),
      description: 'レスの沈み込み',
    );
    final thumbScale = find.descendant(
      of: find.byType(PostImages),
      matching: find.byType(AnimatedScale),
    );

    // 本文を押せば、これまで通りレスが沈む。
    var press = await tester.startGesture(
      tester.getCenter(find.byType(ResBody).first),
    );
    // 1 回目で手応えが始まり、2 回目でその動きが進む。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    expect(spread, paints..circle());
    await press.up();
    await tester.pumpAndSettle();

    // サムネイルを押したときはレスを広げず、絵だけを沈める。
    press = await tester.startGesture(
      tester.getCenter(find.byType(PostImages)),
    );
    // 1 回目で手応えが始まり、2 回目でその動きが進む。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    expect(spread, isNot(paints..circle()));
    expect(tester.widget<AnimatedScale>(thumbScale).scale, lessThan(1));

    // 指が離れれば元に戻る（ここでは離さずに取り消す。長押しに届く前に離すと
    // タップ扱いになり、ビューアが開いてサムネイルごと画面から消えるため）。
    await press.cancel();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(thumbScale).scale, 1);
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

  testWidgets('名前のワッチョイをタップすると識別子が返る', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postNamed('エッヂの名無し </b>(L20 ipkW-6PVw)<b>'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          onTapWacchoi: tapped.add,
          defaultName: 'エッヂの名無し',
        ),
      ),
    );

    await tester.tap(find.text('(L20 ipkW-6PVw)'));
    await tester.pump();

    // 押して返るのは括弧の中身そのままではなく、人を指す識別子だけ。レベル
    // （L20）は同じ人でも上がるので、これが混じると同一人物を繋げなくなる。
    expect(tapped, ['ipkW-6PVw']);
  });

  testWidgets('コテハンでもワッチョイが付いていれば名前から辿れる', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postNamed('コテハン◆Ab12 </b>(L20 ZZZZ-1111)<b>'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          onTapWacchoi: tapped.add,
          defaultName: 'エッヂの名無し',
        ),
      ),
    );

    await tester.tap(find.text('コテハン◆Ab12 (L20 ZZZZ-1111)'));
    await tester.pump();

    expect(tapped, ['ZZZZ-1111']);
  });

  testWidgets('ワッチョイの無い名前は押しても何も起きない', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postNamed('コテハン'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          onTapWacchoi: tapped.add,
          defaultName: 'エッヂの名無し',
        ),
      ),
    );

    await tester.tap(find.text('コテハン'));
    await tester.pump();

    expect(tapped, isEmpty);
  });

  testWidgets('スレ立てコマンドは綴りを消して読める札にする', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('!metadent:vv - configured\n本文だよ'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    // 板への指示そのものは読む文ではないので本文から消える。
    expect(find.textContaining('!metadent', findRichText: true), findsNothing);
    // 代わりに、名前欄に何が出るスレなのかを言葉で残す。
    expect(find.text('ワッチョイ'), findsOneWidget);
    expect(find.textContaining('本文だよ', findRichText: true), findsOneWidget);
  });

  testWidgets('板が強制したコマンドはそう分かるように出す', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('!metadent:v - forced\n本文'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    expect(find.text('レベル（板の設定）'), findsOneWidget);
  });

  testWidgets('コマンドの無いレスには札を出さない', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: postWithBody('ただの本文'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );

    expect(find.byIcon(Icons.badge_outlined), findsNothing);
  });
}
