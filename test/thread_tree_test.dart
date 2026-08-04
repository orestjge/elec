import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/thread_tree.dart';
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
      final res = [
        post(1, 'OP'),
        post(2, 'ふつう'),
        post(3, '>>2 >>1 まとめて'),
      ];
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
      expect(shape(layout.arrivals), [
        '1:0:引用',
        '3:1',
        '5:1',
        '2:0:引用',
        '4:1',
      ]);
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

  test('flatThreadRows は dat の順のまま深さ 0', () {
    final res = [post(1, 'OP'), post(2, '>>1 レス')];
    expect(shape(flatThreadRows(res)), ['1:0', '2:0']);
  });
}
