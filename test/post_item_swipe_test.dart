/// レスの左スワイプ（返信）と、外側の横移動との住み分けの確認。
///
/// スレ画面は一覧と横に並ぶ [PageView] の 1 面なので、**右へのスワイプは一覧へ
/// 戻る操作**。レスの返信スワイプはそれより内側に居るぶん競り合いで先に勝って
/// しまうため、右へ動き始めたら自分から降りる作りにしてある。ここではその
/// 住み分けを、指とトラックパッドの両方で見る。
library;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Res post(int n, String body) => Res(
  number: n,
  name: '名無し',
  mail: '',
  dateText: '12:34',
  dateTime: null,
  id: 'x',
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

void main() {
  /// 一覧（左）とスレ（右）を横に並べた、スレ一覧画面と同じ形。スレ面を開いた
  /// 状態から始める。
  Widget pagedThread(PageController pages, {ValueChanged<int>? onReply}) =>
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: pages,
            physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
            children: [
              const Center(child: Text('一覧')),
              ListView(
                children: [
                  for (var i = 1; i <= 5; i++)
                    PostItem(
                      res: post(i, 'レス $i の本文'),
                      idCount: 1,
                      idOrdinal: 1,
                      onTapId: null,
                      onReply: onReply,
                      onLongPress: () {},
                      bodySelectable: false,
                    ),
                ],
              ),
            ],
          ),
        ),
      );

  Finder body(int n) => find.text('レス $n の本文');

  testWidgets('レスを左へ引くと返信になる', (tester) async {
    final pages = PageController(initialPage: 1);
    var replied = 0;
    await tester.pumpWidget(pagedThread(pages, onReply: (n) => replied = n));
    await tester.pumpAndSettle();

    await tester.drag(body(2), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(replied, 2);
    // 一覧へは動かない。
    expect(pages.page, 1);
  });

  testWidgets('レスの上で右へ引いても一覧へ戻れる', (tester) async {
    final pages = PageController(initialPage: 1);
    var replied = 0;
    await tester.pumpWidget(pagedThread(pages, onReply: (n) => replied = n));
    await tester.pumpAndSettle();

    // 指なりに付いてくることまで見る（弾かずに引ききって離す）。
    final gesture = await tester.startGesture(tester.getCenter(body(2)));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    expect(pages.page, lessThan(1));

    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(pages.page, 0);
    expect(replied, 0);
  });

  testWidgets('トラックパッドで右へ払っても一覧へ戻れる', (tester) async {
    final pages = PageController(initialPage: 1);
    var replied = 0;
    await tester.pumpWidget(pagedThread(pages, onReply: (n) => replied = n));
    await tester.pumpAndSettle();

    // トラックパッドの 2 本指スワイプはポインタ自体が動かず、動いた量が pan で
    // 来る。指とは別の経路なので、向きの判定もそちらを見ていないと素通しになる。
    final at = tester.getCenter(body(2));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(at);
    await gesture.panZoomUpdate(at, pan: const Offset(40, 0));
    await tester.pump();
    await gesture.panZoomUpdate(at, pan: const Offset(600, 0));
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();

    expect(pages.page, 0);
    expect(replied, 0);
  });
}
