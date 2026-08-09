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

    test('複数を指すレスは最初の指し先にぶら下がる', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>2 >>1 まとめて')];
      expect(shape(layOutThreadTree(res, settledCount: 3).settled), [
        '1:0',
        '2:0',
        '3:1',
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

  group('quotedResTime（引用行の日時）', () {
    Res at(String dateText, {DateTime? dateTime}) => Res(
      number: 1,
      name: '名無し',
      mail: '',
      dateText: dateText,
      dateTime: dateTime,
      id: 'x',
      beId: null,
      body: '本文',
      kind: ResKind.normal,
      threadTitle: null,
    );

    // JST 2025/11/03 10:00 = UTC 01:00。
    final now = DateTime.utc(2025, 11, 3, 1);

    test('24 時間以内なら相対表記', () {
      expect(
        quotedResTime(
          at(
            '2025/11/03(月) 09:55:00.000',
            dateTime: now.subtract(const Duration(minutes: 5)),
          ),
          now: now,
        ),
        '5分前',
      );
      expect(
        quotedResTime(
          at(
            '2025/11/03(月) 07:00:00.000',
            dateTime: now.subtract(const Duration(hours: 3)),
          ),
          now: now,
        ),
        '3時間前',
      );
    });

    test('24 時間より前は日付＋時刻に戻す', () {
      expect(
        quotedResTime(
          at(
            '2025/11/02(日) 09:00:00.000',
            dateTime: now.subtract(const Duration(hours: 25)),
          ),
          now: now,
        ),
        '11/02 09:00',
      );
    });

    test('時刻をパースできなくても dat の表記から日付＋時刻を出す', () {
      expect(
        quotedResTime(at('2025/11/02(日) 23:59:00.000'), now: now),
        '11/02 23:59',
      );
    });

    test('日時の分からないレスでは空', () {
      expect(quotedResTime(at(''), now: now), '');
      expect(quotedResTime(at('Over 1000 Thread'), now: now), '');
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

    test('複数を指すレスは最初の指し先を引用する', () {
      final res = [post(1, 'OP'), post(2, 'ふつう'), post(3, '>>2 >>1 まとめて')];
      expect(flat(res), ['1:0', '2:0', '2:0:引用', '3:0']);
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
