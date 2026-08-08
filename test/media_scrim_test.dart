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

    // 1px あたりの変化がいちばん大きいところ（抜けの中ほど）。
    var steepest = 0;
    for (var y = 1; y < profile.length; y++) {
      final step = profile[y] - profile[y - 1];
      if (step > steepest) steepest = step;
    }
    expect(steepest, greaterThan(0));

    // 透けきる直前の 8px は、そこよりずっと緩やかに着地している。**ここが急だと
    // 傾きの折れ目が横一文字の線として見え、「境界がいちばん濃い」ように読める。**
    final landed = profile.indexOf(255);
    for (var y = landed - 8; y < landed; y++) {
      expect(
        profile[y] - profile[y - 1],
        lessThan(steepest / 2),
        reason: 'y=$y の着地が急すぎる',
      );
    }
  });
}
