import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

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

void main() {
  group('replyCounts', () {
    test('>>N の参照を数える', () {
      final res = [
        post(1, 'OP です'),
        post(2, '>>1 そうだね'),
        post(3, '>>1 わかる'),
        post(4, '無関係'),
      ];
      expect(replyCounts(res), {1: 2});
    });

    test('dat 上の &gt;&gt; も数える', () {
      final res = [post(1, 'a'), post(2, '&gt;&gt;1 テスト')];
      expect(replyCounts(res), {1: 1});
    });

    test('1 レスが同じ番号を複数回参照しても 1', () {
      final res = [post(1, 'a'), post(2, '>>1 >>1 二回')];
      expect(replyCounts(res), {1: 1});
    });

    test('複数の対象を別々に数える', () {
      final res = [post(1, 'a'), post(2, 'b'), post(3, '>>1 >>2 まとめて')];
      expect(replyCounts(res), {1: 1, 2: 1});
    });

    test('範囲指定を展開して数える', () {
      final res = [
        post(1, 'a'),
        post(2, 'b'),
        post(3, 'c'),
        post(4, '>>1-3 まとめて'),
      ];
      expect(replyCounts(res), {1: 1, 2: 1, 3: 1});
    });

    test('返信が無ければ空', () {
      expect(replyCounts([post(1, 'a'), post(2, 'b')]), isEmpty);
    });
  });

  group('repliesTo', () {
    final res = [
      post(1, 'OP'),
      post(2, '>>1 はい'),
      post(3, '>>11 別のレス'), // >>1 と誤マッチしないこと
      post(4, '>>1 だね'),
    ];

    test('対象への返信レスだけ返す', () {
      final r = repliesTo(res, 1);
      expect(r.map((e) => e.number), [2, 4]);
    });

    test('>>11 は >>1 に含めない', () {
      expect(repliesTo(res, 1).any((e) => e.number == 3), isFalse);
      expect(repliesTo(res, 11).map((e) => e.number), [3]);
    });

    test('範囲指定の対象にも含める', () {
      final res = [
        post(1, 'a'),
        post(2, 'b'),
        post(3, 'c'),
        post(4, '>>1-3 まとめて'),
      ];
      expect(repliesTo(res, 2).map((e) => e.number), [4]);
    });
  });
}
