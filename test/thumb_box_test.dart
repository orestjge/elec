import 'package:elec/src/ui/post_images.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// レスの本文の幅。端末 400dp から左右の余白と ID の柱を引いたくらい。
const double _body = 340;

/// 升目の一辺（`post_images.dart` が本文の幅から決める値と同じ）。
const double _cell = 160;

Size box(double? ratio, {int count = 1, double cell = _cell}) =>
    thumbBox(cell: cell, maxWidth: _body, ratio: ratio, count: count);

void main() {
  group('読み込む前', () {
    test('比率が分からないうちは正方形で場所を取る', () {
      expect(box(null), const Size.square(_cell));
    });

    test('壊れた比率も正方形に倒す', () {
      expect(box(0), const Size.square(_cell));
      expect(box(-1), const Size.square(_cell));
    });
  });

  group('縦長は高さを伸ばす', () {
    test('3:4 はそのままの形', () {
      expect(box(3 / 4).width, _cell);
      expect(box(3 / 4).height, closeTo(_cell * 4 / 3, 0.01));
    });

    test('正方形は升目のまま', () {
      expect(box(1), const Size.square(_cell));
    });

    test('3:4 より縦長でも 3:4 で止める', () {
      // スマホのスクショ（9:19）。そのまま出すと 338dp になり、読み込みで
      // 下のレスが飛ぶ。
      expect(box(9 / 19).height, closeTo(_cell * 4 / 3, 0.01));
      expect(box(1 / 4).height, closeTo(_cell * 4 / 3, 0.01));
    });

    test('伸びるのは升目の 1/3 まで', () {
      // ここが「絵が届いた瞬間に下のレスが動く量」の上限。
      expect(box(9 / 19).height - _cell, closeTo(53.3, 0.1));
    });
  });

  group('横長 1 枚は高さを保って幅を伸ばす', () {
    test('16:9 は高さそのまま・幅だけ広がる', () {
      final size = box(16 / 9);
      expect(size.height, _cell);
      expect(size.width, closeTo(284.4, 0.1));
    });

    test('高さが変わらない＝読み込みで下のレスが動かない', () {
      for (final ratio in [1.0, 4 / 3, 16 / 9, 2.0]) {
        expect(box(ratio).height, _cell, reason: '比率 $ratio');
      }
    });

    test('本文の幅で頭打ちになったら、そのぶん高さを削って形を保つ', () {
      final size = box(4);
      expect(size.width, _body);
      expect(size.height, closeTo(_body / 4, 0.1));
    });

    test('薄くなりすぎる帯は底を打って左右を切る', () {
      final size = box(20);
      expect(size.width, _body);
      expect(size.height, _cell / 2);
    });
  });

  group('枚数', () {
    test('よく横長なものは 2 枚でも 1 行を明け渡して広く出す', () {
      // 2 つ並べると 160x90 になり、写っているものが分からない。
      final size = box(16 / 9, count: 2);
      expect(size.width, closeTo(284.4, 0.1));
      expect(size.height, _cell);
    });

    test('少しだけ横長なら 2 枚並べたまま', () {
      // 4:3 のすぐ手前。1 行に 2 つの方がまだ読みやすい。
      final size = box(1.3, count: 2);
      expect(size.width, _cell);
      expect(size.height, closeTo(123.1, 0.1));
    });

    test('1 枚なら少しの横長でも広げる（隣に並ぶものが無い）', () {
      final size = box(1.3);
      expect(size.width, closeTo(208, 0.1));
      expect(size.height, _cell);
    });

    test('2 枚の縦長は高さだけ伸びる', () {
      expect(box(3 / 4, count: 2).width, _cell);
      expect(box(3 / 4, count: 2).height, closeTo(_cell * 4 / 3, 0.01));
    });

    test('4 枚までは元の形のまま', () {
      expect(box(3 / 4, count: 4).height, closeTo(_cell * 4 / 3, 0.01));
      expect(box(16 / 9, count: 4).height, _cell);
      expect(box(16 / 9, count: 4).width, closeTo(284.4, 0.1));
    });

    test('5 枚以上は形を揃えて升目に落とす', () {
      for (final ratio in [3 / 4, 1.0, 16 / 9, 9 / 19]) {
        expect(
          box(ratio, count: 5),
          const Size.square(_cell),
          reason: '$ratio',
        );
        expect(
          box(ratio, count: 8),
          const Size.square(_cell),
          reason: '$ratio',
        );
      }
    });
  });

  group('切るか、縮めて全部見せるか', () {
    BoxFit fit(double? ratio, {int count = 1}) => thumbFit(
      ratio: ratio,
      box: box(ratio, count: count),
    );

    test('枠と形が合っているものはそのまま枠いっぱいに敷く', () {
      // 元の形で出せた絵は、そもそも切るところが無い。
      expect(fit(3 / 4), BoxFit.cover);
      expect(fit(1), BoxFit.cover);
      expect(fit(16 / 9), BoxFit.cover);
    });

    test('よくある横長の写真は升目でも切って出す', () {
      // 16:9 を正方形へ敷くと 0.56 残る＝半分より多く残るので切る。
      expect(fit(16 / 9, count: 5), BoxFit.cover);
    });

    test('スマホのスクショは 3:4 の枠に切って収める', () {
      // 9:19 は 3:4 の枠に 0.63 残る。上下は落ちるが何が写っているかは分かる。
      expect(fit(9 / 19), BoxFit.cover);
    });

    test('1 行だけのスクショは切らずに全部見せる', () {
      // 極端に横長。切ると真ん中の数文字しか残らず、何なのか分からなくなる。
      expect(fit(15), BoxFit.contain);
      expect(fit(15, count: 2), BoxFit.contain);
      expect(fit(15, count: 5), BoxFit.contain);
    });

    test('極端に縦長のものも全部見せる', () {
      expect(fit(1 / 6), BoxFit.contain);
    });

    test('比率が分からないうちは切る側に倒す', () {
      expect(thumbFit(ratio: null, box: box(null)), BoxFit.cover);
      expect(thumbFit(ratio: 1, box: Size.zero), BoxFit.cover);
    });
  });

  group('升目が縮む場所（ツリーの深い行・狭い端末）', () {
    test('上限も下限も一辺に対する比で効く', () {
      const small = 96.0;
      expect(box(9 / 19, cell: small).width, small);
      expect(box(9 / 19, cell: small).height, closeTo(small * 4 / 3, 0.01));
      expect(box(20, cell: small).height, small / 2);
    });

    test('横長 1 枚は狭い升目でも本文の幅までは伸びる', () {
      final size = box(16 / 9, cell: 96);
      expect(size.height, 96);
      expect(size.width, closeTo(170.7, 0.1));
    });
  });
}
