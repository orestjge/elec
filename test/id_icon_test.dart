import 'package:elec/src/ui/id_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同じ ID からは必ず同じ絵と色が出る', () {
    expect(idIconCells('aBc1De2f'), idIconCells('aBc1De2f'));
    expect(
      idIconColor('aBc1De2f', Brightness.light),
      idIconColor('aBc1De2f', Brightness.light),
    );
  });

  test('1 文字違う ID は別の絵になる', () {
    expect(idIconCells('aaa'), isNot(idIconCells('aab')));
    expect(idIconCells('aaa'), isNot(idIconCells('aba')));
  });

  test('絵は左右対称', () {
    for (final id in ['aaa', 'ID12345678', 'zZ9', '']) {
      final cells = idIconCells(id);
      expect(cells, hasLength(idIconGridSize * idIconGridSize));
      for (var row = 0; row < idIconGridSize; row++) {
        for (var col = 0; col < idIconGridSize; col++) {
          expect(
            cells[row * idIconGridSize + col],
            cells[row * idIconGridSize + (idIconGridSize - 1 - col)],
            reason: '($row,$col) が鏡像と一致しない: $id',
          );
        }
      }
    }
  });

  test('全消し・全塗りは出ない', () {
    // 総当たりはできないので、ハッシュが散る程度の数を回して確認する。
    for (var i = 0; i < 5000; i++) {
      final cells = idIconCells('id$i');
      expect(cells.any((on) => on), isTrue, reason: 'id$i が全消し');
      expect(cells.any((on) => !on), isTrue, reason: 'id$i が全塗り');
    }
  });

  test('色相はテーマの明暗で変わらず、明度だけが変わる', () {
    final light = HSLColor.fromColor(idIconColor('aaa', Brightness.light));
    final dark = HSLColor.fromColor(idIconColor('aaa', Brightness.dark));

    expect(dark.hue, closeTo(light.hue, 0.5));
    expect(dark.lightness, greaterThan(light.lightness));
  });

  test('色と形は別のハッシュから決まる', () {
    // 同じ値を使い回していると、絵が同じ ID は色も同じになる。実用上は
    // 「色が近いのに形も近い」を避けたいので、独立していることを確かめる。
    final byCells = <String, String>{};
    var sameCellsDifferentColor = 0;
    for (var i = 0; i < 5000; i++) {
      final id = 'id$i';
      final key = idIconCells(id).map((on) => on ? '1' : '0').join();
      final other = byCells[key];
      if (other == null) {
        byCells[key] = id;
      } else if (idIconColor(id, Brightness.light) !=
          idIconColor(other, Brightness.light)) {
        sameCellsDifferentColor++;
      }
    }
    expect(sameCellsDifferentColor, greaterThan(0));
  });

  testWidgets('IdIcon は指定したサイズに収まる', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: IdIcon(id: 'aaa', size: 24)),
      ),
    );

    expect(tester.getSize(find.byType(IdIcon)), const Size(24, 24));
  });
}
