import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:elec/src/ui/media_scrim.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 白地の上に暗幕を敷いて、上から下へ 1px ずつの明るさを読む。
///
/// 255 が透けきり（白のまま）、小さいほど濃い。
Future<List<int>> _profile(
  WidgetTester tester, {
  required double barHeight,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.white),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopScrim(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: barHeight),
                    const SizedBox(height: TopScrim.fadeTail),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late final ui.Image image;
  late final ByteData? data;
  await tester.runAsync(() async {
    image = await boundary.toImage();
    data = await image.toByteData();
  });
  final width = image.width;
  return [
    for (var y = 0; y < (barHeight + TopScrim.fadeTail).round() + 12; y++)
      data!.getUint8((y * width + width ~/ 2) * 4),
  ];
}

void main() {
  testWidgets('暗幕は上が濃く、下へ向かって薄くなる一方', (tester) async {
    final profile = await _profile(tester, barHeight: 56);

    // 上端がいちばん濃く、そこから戻ることはない。
    expect(profile.first, lessThan(160));
    for (var y = 1; y < profile.length; y++) {
      expect(
        profile[y],
        greaterThanOrEqualTo(profile[y - 1]),
        reason: 'y=$y で濃くなり返している（絵の途中に線が入って見える）',
      );
    }
    // 最後は完全に透けきる。
    expect(profile.last, 255);
  });

  testWidgets('抜けきる手前は傾きが寝ていて、終わりが線に見えない', (tester) async {
    final profile = await _profile(tester, barHeight: 56);

    // 傾きは 8px の窓で測る。1px ごとの差は 0〜1 に丸められて、緩やかなところ
    // ほど量子化の誤差に埋もれてしまう。
    int slopeAt(int y) => profile[y] - profile[y - 8];

    var steepest = 0;
    for (var y = 8; y < profile.length; y++) {
      final slope = slopeAt(y);
      if (slope > steepest) steepest = slope;
    }
    expect(steepest, greaterThan(0));

    // 透けきる直前の 8px は、いちばん急なところよりずっと寝ている。**ここが同じ
    // 傾きのまま透明に着くと、傾きの折れ目が横一文字の線として見え、「境界が
    // いちばん濃い」ように読める。** 直線のグラデーションではここが最大になる。
    expect(
      slopeAt(profile.indexOf(255)),
      lessThan(steepest * 0.6),
      reason: '着地が急すぎる（終わりが線に見える）',
    );
  });
}
