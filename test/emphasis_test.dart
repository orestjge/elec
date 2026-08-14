import 'package:elec/src/ui/emphasis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('連投数の量', () {
    test('単発は 0（輪が出ない）', () {
      expect(idCountAmount(0), 0);
      expect(idCountAmount(1), 0);
    });

    test('増えるほど大きくなり、満杯で頭打ち', () {
      expect(idCountAmount(2), greaterThan(0));
      expect(idCountAmount(6), greaterThan(idCountAmount(2)));
      expect(idCountAmount(24), 1);
      // 満杯を超えても 1 のまま（40 連投でも輪は 1 周）。
      expect(idCountAmount(200), 1);
    });

    test('対数なので、少ない側で差が出る', () {
      // 2→6 の差が 20→24 の差より大きいこと（混み合うところを開く目的）。
      expect(
        idCountAmount(6) - idCountAmount(2),
        greaterThan(idCountAmount(24) - idCountAmount(20)),
      );
    });
  });

  group('勢いの量', () {
    test('下限（100 レス/日）以下は 0、満杯（100k レス/日）で 1', () {
      expect(momentumAmount(0), 0);
      expect(momentumAmount(100), 0);
      expect(momentumAmount(100000), 1);
      // 満杯を超えても 1 のまま。
      expect(momentumAmount(500000), 1);
    });

    test('実況板の実測分布が棒の伸びに散る', () {
      // 2026-08-15 の liveedge 実測。大半が 1k〜10k に固まるので、そこが
      // 半分前後の伸びに来て、上に伸びしろが残ること。
      expect(momentumAmount(1155), closeTo(0.35, 0.02)); // 上位 75%
      expect(momentumAmount(1721), closeTo(0.41, 0.02)); // 中央値
      expect(momentumAmount(6654), closeTo(0.61, 0.02)); // 上位 10%
      expect(momentumAmount(95212), closeTo(0.99, 0.02)); // 最速
    });
  });

  group('量 → 見せ方', () {
    test('5 段に丸める', () {
      expect(quantizeAmount(0), 0);
      expect(quantizeAmount(0.1), 0);
      expect(quantizeAmount(0.3), 0.25);
      expect(quantizeAmount(1), 1);
      // 範囲外は端に寄せる。
      expect(quantizeAmount(-1), 0);
      expect(quantizeAmount(2), 1);
    });

    test('多いほど濃く、太くなる', () {
      const scheme = ColorScheme.light();
      expect(
        emphasisFill(scheme, 1).a,
        greaterThan(emphasisFill(scheme, 0).a),
      );
      expect(emphasisWeight(1).value, greaterThan(emphasisWeight(0).value));
    });

    test('字は透かさず、色そのものを混ぜる', () {
      const scheme = ColorScheme.light();
      expect(emphasisText(scheme, 0), scheme.onSurfaceVariant);
      expect(emphasisText(scheme, 1), scheme.onSurface);
      expect(emphasisText(scheme, 1).a, 1);
    });
  });
}
