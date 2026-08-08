import 'package:elec/src/ui/now_ticker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // タイマーは testWidgets の疑似時計でしか進められないので widget test で書く。
  // ウィジェットは要らないので、時計に直接聞き手を付けて確かめる。
  testWidgets('聞き手が居る間だけ動き、居なくなれば止まる', (tester) async {
    final ticker = NowTicker();
    addTearDown(ticker.dispose);
    var ticks = 0;
    void listener() => ticks++;

    // 聞き手が付くまでタイマーは動かない（＝古いスレを開いただけでは回らない）。
    await tester.pump(NowTicker.interval * 2);
    expect(ticks, 0);

    ticker.addListener(listener);
    await tester.pump(NowTicker.interval);
    expect(ticks, 1);
    await tester.pump(NowTicker.interval);
    expect(ticks, 2);

    // 画面を閉じて聞き手が居なくなれば止まる（タイマーが残らない）。
    ticker.removeListener(listener);
    await tester.pump(NowTicker.interval * 2);
    expect(ticks, 2);
  });
}
