import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/thread_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Res post(int n, String body) => Res(
  number: n,
  name: '名無し',
  mail: '',
  dateText: '',
  dateTime: null,
  id: 'x',
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

/// 行を `番号:深さ`（引用行は `番号:深さ:引用`）で表して比べやすくする。
List<String> shape(List<ThreadTreeRow> rows) => [
  for (final r in rows)
    r.quote ? '${r.res.number}:${r.depth}:引用' : '${r.res.number}:${r.depth}',
];

void main() {
  group('layOutThreadTree（ツリー側）', () {
    test('返信を親の下にぶら下げる', () {
      final res = [
        post(1, 'OP'),
        post(2, '>>1 レス'),
        post(3, '>>2 その返信'),
        post(4, '無関係'),
      ];
      final layout = layOutThreadTree(res, settledCount: 4);
      expect(shape(layout.settled), ['1:0', '2:1', '3:2', '4:0']);
      expect(layout.arrivals, isEmpty);
    });

    test('同じ親への返信は番号順に並ぶ', () {
      final res = [post(1, 'OP'), post(2, '>>1 a'), post(3, '>>1 b')];
      expect(shape(layOutThreadTree(res, settledCount: 3).settled), [
        '1:0',
        '2:1',
        '3:1',
      ]);
    });

    test('複数を指すレスは最初の指し先にぶら下がり、残りは引用で添える', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>2 >>1 まとめて')];
      // 2 の下へ入るのはツリーで表せる 1 人ぶんだけ。1 はどこにも現れないので、
      // 3 と同じ深さの引用行にして手前へ置く。
      expect(shape(layOutThreadTree(res, settledCount: 3).settled), [
        '1:0',
        '2:0',
        '1:1:引用',
        '3:1',
      ]);
    });

    test('ぶら下げた親は引用しない（すぐ上に本体がある）', () {
      final res = [post(1, 'OP'), post(2, '>>1 レス'), post(3, '>>2 >>1 両方へ')];
      // 3 の親は 2。その本体は 1 行上なので引用せず、離れている 1 だけ添える。
      expect(shape(layOutThreadTree(res, settledCount: 3).settled), [
        '1:0',
        '2:1',
        '1:2:引用',
        '3:2',
      ]);
    });

    test('自分より新しい番号しか指していないレスは根になる', () {
      final res = [post(1, 'OP'), post(2, '>>5 まだ無い番号')];
      expect(shape(layOutThreadTree(res, settledCount: 2).settled), [
        '1:0',
        '2:0',
      ]);
    });

    test('あぼーんの親でもぶら下がりは保つ', () {
      final res = [
        post(1, 'OP'),
        Res(
          number: 2,
          name: 'あぼーん',
          mail: '',
          dateText: '',
          dateTime: null,
          id: null,
          beId: null,
          body: 'あぼーん',
          kind: ResKind.abone,
          threadTitle: null,
        ),
        post(3, '>>2 消えたレスへの返信'),
      ];
      expect(shape(layOutThreadTree(res, settledCount: 3).settled), [
        '1:0',
        '2:0',
        '3:1',
      ]);
    });

    test('長い数珠つなぎでも深さが積み上がる', () {
      final res = [
        post(1, 'OP'),
        for (var n = 2; n <= 200; n++) post(n, '>>${n - 1} 続き'),
      ];
      final settled = layOutThreadTree(res, settledCount: 200).settled;
      expect(settled.length, 200);
      expect(settled.last.res.number, 200);
      expect(settled.last.depth, 199);
    });
  });

  group('layOutThreadTree（新着側）', () {
    test('新着は既読ぶんのツリーへは挿さず下に積む', () {
      final res = [
        post(1, 'OP'),
        post(2, '>>1 レス'),
        post(3, '無関係な新着'),
        post(4, '>>1 古いレスへの新着'),
      ];
      final layout = layOutThreadTree(res, settledCount: 2);
      expect(shape(layout.settled), ['1:0', '2:1']);
      // 3 はどこにも返信していないので引用無し。4 は指し先を薄く再掲してから。
      expect(shape(layout.arrivals), ['3:0', '1:0:引用', '4:1']);
    });

    test('新着どうしの返信は引用せず字下げでぶら下げる', () {
      final res = [
        post(1, 'OP'),
        post(2, '新着その1'),
        post(3, '>>2 新着への返信'),
        post(4, '>>3 さらに返信'),
      ];
      final layout = layOutThreadTree(res, settledCount: 1);
      expect(shape(layout.arrivals), ['2:0', '3:1', '4:2']);
    });

    test('あとから来た返信も、返信先が新着ならその直下へ入る', () {
      final res = [
        post(1, 'OP'),
        post(2, '新着その1'),
        post(3, '無関係な新着'),
        post(4, '>>2 だいぶ後から 2 への返信'),
        post(5, '>>4 さらにその返信'),
      ];
      final layout = layOutThreadTree(res, settledCount: 1);
      // 4・5 は末尾ではなく 2 の下で会話になり、3 はそのまま根に残る。
      expect(shape(layout.arrivals), ['2:0', '4:1', '5:2', '3:0']);
    });

    test('同じ引用先の新着は 1 つの引用行の下にまとめる', () {
      final res = [
        post(1, 'OP'),
        post(2, '既読'),
        post(3, '>>1 新着'),
        post(4, '>>1 新着その2'),
        post(5, '>>3 その返信'),
      ];
      final layout = layOutThreadTree(res, settledCount: 2);
      // 5 は 3 の下へ入る。4 は同じ 1 へのぶら下がりなので引用は繰り返さない。
      expect(shape(layout.arrivals), ['1:0:引用', '3:1', '5:2', '4:1']);
    });

    test('複数を指す新着は指し先の並びが同じものだけまとめる', () {
      final res = [
        post(1, 'OP'),
        post(2, '既読'),
        post(3, '>>1 >>2 両方へ'),
        post(4, '>>1 1 だけへ'),
        post(5, '>>1 >>2 また両方へ'),
      ];
      final layout = layOutThreadTree(res, settledCount: 2);
      // 3 と 5 は指し先がそっくり同じなので 1 つのまとまり。4 を混ぜると
      // 2 へも返したように読めるので別にする。
      expect(shape(layout.arrivals), [
        '1:0:引用',
        '2:0:引用',
        '3:1',
        '5:1',
        '1:0:引用',
        '4:1',
      ]);
    });

    test('ぶら下がった新着の、親以外の指し先も引用する', () {
      final res = [
        post(1, 'OP'),
        post(2, '既読'),
        post(3, '新着'),
        post(4, '>>3 >>2 新着と既読の両方へ'),
      ];
      final layout = layOutThreadTree(res, settledCount: 2);
      // 4 は 3 の下へ入る。ツリーに出てこない 2 は 4 と同じ深さで引用する。
      expect(shape(layout.arrivals), ['3:0', '2:1:引用', '4:1']);
    });

    test('引用先が違えば別のまとまりになる', () {
      final res = [
        post(1, 'OP'),
        post(2, '既読'),
        post(3, '>>1 新着'),
        post(4, '>>2 別の指し先'),
        post(5, '>>1 また 1 へ'),
      ];
      final layout = layOutThreadTree(res, settledCount: 2);
      // 5 は先に来た 3 と同じ >>1 のまとまりへ。4 は別の引用行を持つ。
      expect(shape(layout.arrivals), ['1:0:引用', '3:1', '5:1', '2:0:引用', '4:1']);
    });

    test('間に無関係な新着を挟んでも同じ引用先はまとめる', () {
      final res = [
        post(1, 'OP'),
        post(2, '>>1 新着'),
        post(3, '独り言'),
        post(4, '>>1 また 1 へ'),
      ];
      final layout = layOutThreadTree(res, settledCount: 1);
      expect(shape(layout.arrivals), ['1:0:引用', '2:1', '4:1', '3:0']);
    });

    test('境界が総数と同じならすべてツリー（未読スレ）', () {
      final res = [post(1, 'OP'), post(2, '>>1 レス')];
      final layout = layOutThreadTree(res, settledCount: 2);
      expect(shape(layout.settled), ['1:0', '2:1']);
      expect(layout.arrivals, isEmpty);
    });

    test('境界 0 ならすべて新着として組む', () {
      final res = [post(1, 'OP'), post(2, '>>1 レス')];
      final layout = layOutThreadTree(res, settledCount: 0);
      expect(layout.settled, isEmpty);
      expect(shape(layout.arrivals), ['1:0', '2:1']);
    });
  });

  group('quotedResBody（引用行の中身）', () {
    test('画像 URL は文章から落として画像に回す', () {
      final body = quotedResBody(
        post(1, 'これ見て<br>https://example.com/a.jpg<br>どう？'),
      );
      expect(body.excerpt, 'これ見て どう？');
      expect(body.images.map((u) => u.toString()), [
        'https://example.com/a.jpg',
      ]);
    });

    test('画像しか無いレスの文章は空になる', () {
      final body = quotedResBody(post(1, 'https://example.com/a.jpg'));
      expect(body.excerpt, '');
      expect(body.images, hasLength(1));
    });

    test('同じ画像を貼り直しても 1 枚', () {
      final body = quotedResBody(
        post(1, 'https://example.com/a.jpg https://example.com/a.jpg'),
      );
      expect(body.images, hasLength(1));
    });

    test('省略表記（ttps://）の画像も拾う', () {
      final body = quotedResBody(post(1, 'ttps://example.com/a.jpg'));
      expect(body.images.map((u) => u.toString()), [
        'https://example.com/a.jpg',
      ]);
    });

    test('画像以外のリンクは文章に残す', () {
      final body = quotedResBody(
        post(
          1,
          'ソース https://example.com/page.html と https://example.com/v.mp4',
        ),
      );
      expect(
        body.excerpt,
        'ソース https://example.com/page.html と https://example.com/v.mp4',
      );
      expect(body.images, isEmpty);
    });

    test('AA は 1 行に潰さず形のまま持つ', () {
      final body = quotedResBody(post(1, '　　 ∧＿∧<br>　　（　´∀｀）<br>　　（　　　　）'));
      expect(body.asciiArt, '　　 ∧＿∧\n　　（　´∀｀）\n　　（　　　　）');
      // 絵を出せない場所のために、1 行の抜粋も今まで通り持っておく。
      expect(body.excerpt, '∧＿∧ （ ´∀｀） （ ）');
    });

    test('AA の前後の空行は落とし、行頭の空白は残す', () {
      final body = quotedResBody(
        post(1, '<br><br>　　 ∧＿∧<br>　　（　´∀｀）<br>　　（　　　　）<br><br>'),
      );
      expect(body.asciiArt, '　　 ∧＿∧\n　　（　´∀｀）\n　　（　　　　）');
    });

    test('普通の本文は AA にしない', () {
      expect(quotedResBody(post(1, 'ふつうの返信です')).asciiArt, isNull);
    });

    test('あぼーんは文章だけ', () {
      final abone = Res(
        number: 1,
        name: '',
        mail: '',
        dateText: '',
        dateTime: null,
        id: null,
        beId: null,
        body: 'https://example.com/a.jpg',
        kind: ResKind.abone,
        threadTitle: null,
      );
      final body = quotedResBody(abone);
      expect(body.excerpt, 'あぼーん');
      expect(body.images, isEmpty);
    });
  });

  group('QuotedResRow（引用行）', () {
    testWidgets('画像は URL の文字列ではなく小さなサムネイルで出す', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuotedResRow(res: post(1, 'これ見て https://example.com/a.jpg')),
          ),
        ),
      );

      expect(find.textContaining('a.jpg'), findsNothing);
      expect(find.text('これ見て'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(QuotedResRow),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
    });

    testWidgets('画像が多いレスは先頭だけ出して残りは枚数で伝える', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuotedResRow(
              res: post(
                1,
                'https://example.com/a.jpg https://example.com/b.jpg '
                'https://example.com/c.jpg https://example.com/d.jpg '
                'https://example.com/e.jpg',
              ),
            ),
          ),
        ),
      );

      expect(find.byType(Image), findsNWidgets(3));
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('番号・ID の絵・抜粋・サムネイルを 1 行に並べる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuotedResRow(
              res: post(1, '返信先の本文 https://example.com/a.jpg'),
            ),
          ),
        ),
      );

      // 番号・抜粋・サムネイルの中心が同じ高さ＝折り返さず横一列に載っている。
      final number = tester.getCenter(find.text('1')).dy;
      expect(tester.getCenter(find.text('返信先の本文')).dy, number);
      expect(tester.getCenter(find.byType(Image)).dy, number);
    });

    testWidgets('どれだけ本文が長くても引用行は伸びない', (tester) async {
      // 引用行は「何への返信か」を思い出すための添え物で、そのために一覧の場所を
      // 食ってはいけない。長い本文は折り返さず 1 行で切る。
      Widget rowFor(String body) => MaterialApp(
        home: Scaffold(body: QuotedResRow(res: post(1, body))),
      );

      await tester.pumpWidget(rowFor('短い'));
      final plain = tester.getSize(find.byType(QuotedResRow)).height;

      await tester.pumpWidget(
        rowFor('長めの返信先の本文で、放っておけば二行にも三行にもなるくらいの分量を書いておく'),
      );
      expect(tester.getSize(find.byType(QuotedResRow)).height, plain);
    });

    testWidgets('AA の返信先は 1 行に潰さず縮めた絵で出す', (tester) async {
      // 1 行に潰すと記号の列にしかならず、何への返信かを思い出せない。形を保った
      // まま、行に収まる大きさへ縮めて出す。
      const aa = '　　 ∧＿∧\n　　（　´∀｀）\n　　（　　　　）\n　　｜　　　｜';
      Widget rowFor(String body) => MaterialApp(
        home: Scaffold(body: QuotedResRow(res: post(1, body))),
      );

      await tester.pumpWidget(rowFor('ふつうの返信です'));
      final plain = tester.getSize(find.byType(QuotedResRow)).height;

      await tester.pumpWidget(rowFor(aa.replaceAll('\n', '<br>')));
      expect(find.text(aa), findsOneWidget);
      final art = find.ancestor(
        of: find.text(aa),
        matching: find.byType(FittedBox),
      );
      expect(
        tester.getSize(find.byType(QuotedResRow)).height,
        greaterThan(plain),
      );
      expect(tester.getSize(art).height, lessThanOrEqualTo(48));
    });

    testWidgets('サムネイルは絵として読める大きさで出す', (tester) async {
      // 字の高さに揃えると行は静かになるが、何が写っているか分からない絵は
      // 手掛かりにならない。画像のある行だけは伸ばして、読める大きさを取る。
      Widget rowFor(String body) => MaterialApp(
        home: Scaffold(body: QuotedResRow(res: post(1, body))),
      );

      await tester.pumpWidget(rowFor('返信先の本文'));
      final plain = tester.getSize(find.byType(QuotedResRow)).height;

      await tester.pumpWidget(rowFor('返信先の本文 https://example.com/a.jpg'));
      expect(tester.getSize(find.byType(Image)), const Size(32, 32));
      expect(
        tester.getSize(find.byType(QuotedResRow)).height,
        greaterThan(plain),
      );
    });
  });

  group('layOutFlatRows（番号順表示）', () {
    /// 新着ライン無し（全部が「開いた時点まで」）で組んだ行。
    List<String> flat(List<Res> res) =>
        shape(layOutFlatRows(res, settledCount: res.length).settled);

    test('並べ替えずに dat の順のまま深さ 0', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>1 レス')];
      expect(flat(res), ['1:0', '2:0', '1:0:引用', '3:0']);
    });

    test('返信先の引用行を返信レスの手前に挟む', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>1 レス')];
      final rows = layOutFlatRows(res, settledCount: 3).settled;
      expect(rows[2].quote, isTrue);
      expect(rows[2].res.number, 1);
      expect(rows[3].res.number, 3);
    });

    test('返信先が直前のレスでも引用する（返信の見た目を揃える）', () {
      final res = [post(1, 'OP'), post(2, '>>1 レス'), post(3, '>>2 その返信')];
      expect(flat(res), ['1:0', '1:0:引用', '2:0', '2:0:引用', '3:0']);
    });

    test('同じ相手への連投でも毎回引用する', () {
      final res = [
        post(1, 'OP'),
        post(2, 'ふつう'),
        post(3, '>>1 a'),
        post(4, '>>1 b'),
      ];
      expect(flat(res), ['1:0', '2:0', '1:0:引用', '3:0', '1:0:引用', '4:0']);
    });

    test('複数を指すレスは指した順に全部引用する', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>2 >>1 まとめて')];
      expect(flat(res), ['1:0', '2:0', '2:0:引用', '1:0:引用', '3:0']);
    });

    test('引用は上限まで。まとめレスで引用ばかりにしない', () {
      final res = [
        for (var n = 1; n <= 5; n++) post(n, 'レス$n'),
        post(6, '>>1 >>2 >>3 >>4 >>5 みんなありがとう'),
      ];
      expect(flat(res), [
        '1:0',
        '2:0',
        '3:0',
        '4:0',
        '5:0',
        '1:0:引用',
        '2:0:引用',
        '3:0:引用',
        '6:0',
      ]);
      expect(maxQuotedResRows, 3);
    });

    test('同じ相手を二度指しても引用は 1 つ', () {
      final res = [post(1, 'OP'), post(2, '>>1 だけど >>1 について')];
      expect(flat(res), ['1:0', '1:0:引用', '2:0']);
    });

    test('無い番号・自分より新しい番号を指すレスには引用を付けない', () {
      final res = [post(1, 'OP'), post(2, '>>5 まだ無い番号')];
      expect(flat(res), ['1:0', '2:0']);
    });

    test('新着ラインをまたぐ返信も引用ごと新着側へ入る', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>1 新着')];
      final layout = layOutFlatRows(res, settledCount: 2);
      expect(shape(layout.settled), ['1:0', '2:0']);
      expect(shape(layout.arrivals), ['1:0:引用', '3:0']);
    });
  });

  group('ThreadTreeTier（字下げ帯）', () {
    testWidgets('目印を帯に乗せても本文の位置は動かない', (tester) async {
      // 帯の太さと本文までの隙間は足して一定。目印が付いた行だけ本文がずれると、
      // ツリーの縦の筋が折れて見える。
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ThreadTreeTier(depth: 1, child: Text('ふつう')),
                ThreadTreeTier(
                  depth: 1,
                  accent: Colors.red,
                  child: Text('目印つき'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        tester.getTopLeft(find.text('目印つき')).dx,
        tester.getTopLeft(find.text('ふつう')).dx,
      );
    });

    testWidgets('帯は 1 本だけ——レス側の目印は消して字下げ帯に移す', (tester) async {
      // 2 本並べると、数 px ずれた縦線が 2 本走って「揃っていない」に見える。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ThreadTreeTier(
                  depth: 1,
                  child: PostItem(
                    res: post(2, 'ふつうのレス'),
                    idCount: 1,
                    idOrdinal: 1,
                    onTapId: null,
                    bodySelectable: false,
                  ),
                ),
                ThreadTreeTier(
                  depth: 1,
                  accent: Colors.red,
                  child: PostItem(
                    res: post(3, '自分宛のレス'),
                    idCount: 1,
                    idOrdinal: 1,
                    onTapId: null,
                    bodySelectable: false,
                    isReplyToOwn: true,
                    showAccentBar: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 本文の左端が揃っている＝レス側は帯を描いていない（描くと 3px ぶん
      // 左パディングを詰めるので、ここがずれる）。
      expect(
        tester.getTopLeft(find.text('自分宛のレス')).dx,
        tester.getTopLeft(find.text('ふつうのレス')).dx,
      );
    });
  });
}
