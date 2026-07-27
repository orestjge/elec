import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();
List<int> datLine(String s) => [..._win31j.encode(s), 0x0A];

class QueueFetcher implements HttpFetcher {
  QueueFetcher(this._responses);
  final List<FetchResponse> _responses;

  int calls = 0;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final i = calls < _responses.length ? calls : _responses.length - 1;
    calls++;
    return _responses[i];
  }
}

FetchResponse ok(List<int> body) =>
    FetchResponse(statusCode: 200, bodyBytes: body, headers: const {});

void main() {
  late QueueFetcher fetcher;

  Future<void> openThread(WidgetTester tester) async {
    fetcher = QueueFetcher([
      ok(_win31j.encode('1.dat<>スワイプスレ (1)\n')),
      ok(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>スワイプスレ')),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('スワイプスレ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文', findRichText: true), findsOneWidget);
  }

  /// スレ面の左端。0 なら全面がスレ、画面幅まで動けば一覧が全面。
  double threadLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byType(ThreadScreen)).dx;

  /// スレ面が全面に出ているか。
  bool onThread(WidgetTester tester) =>
      find.byType(ThreadScreen).evaluate().isNotEmpty &&
      threadLeft(tester) == 0;

  Finder body() => find.textContaining('本文', findRichText: true);

  /// 指で引く。実機の指と同じく、細かく動かしながら時間も進める。
  Future<TestGesture> drag(
    WidgetTester tester, {
    required Offset from,
    required double distance,
    required Duration total,
    bool release = true,
  }) async {
    final gesture = await tester.startGesture(from);
    const steps = 10;
    final step = Duration(microseconds: total.inMicroseconds ~/ steps);
    var elapsed = Duration.zero;
    for (var i = 0; i < steps; i++) {
      elapsed += step;
      await gesture.moveBy(Offset(distance / steps, 0), timeStamp: elapsed);
      await tester.pump(step);
    }
    if (release) {
      await gesture.up(timeStamp: elapsed);
      await tester.pumpAndSettle();
    }
    return gesture;
  }

  testWidgets('引いている間、スレ面が指に追従して一覧が覗く', (tester) async {
    await openThread(tester);
    expect(threadLeft(tester), 0);

    final gesture = await drag(
      tester,
      from: tester.getCenter(body()),
      distance: 200,
      total: const Duration(milliseconds: 300),
      release: false,
    );
    // 指を離す前から、引いた分だけスレ面が動いている（最初のわずかな移動は
    // ドラッグと判定されるまでに使われる）。
    expect(threadLeft(tester), greaterThan(150));
    // 下から一覧が覗いている。
    expect(find.text('スワイプスレ'), findsWidgets);

    // 少し戻せば付いてくる（途中でやめられる）。
    final before = threadLeft(tester);
    await gesture.moveBy(
      const Offset(-120, 0),
      timeStamp: const Duration(milliseconds: 330),
    );
    await tester.pump();
    expect(threadLeft(tester), lessThan(before - 100));

    await gesture.up(timeStamp: const Duration(milliseconds: 340));
    await tester.pumpAndSettle();
    // 半分も引いていないのでスレ面に戻る。
    expect(onThread(tester), isTrue);
  });

  testWidgets('半分を越えて離すと一覧に戻り、スレは控えに残る', (tester) async {
    await openThread(tester);
    final width = tester.getSize(find.byType(ThreadListScreen)).width;
    final callsWhileOpen = fetcher.calls;

    await drag(
      tester,
      from: tester.getCenter(body()),
      distance: width * 0.7,
      total: const Duration(milliseconds: 400),
    );

    // 一覧が全面に出ている。
    expect(find.text('エッヂ'), findsWidgets);
    expect(onThread(tester), isFalse);

    // 控えているので、戻すときに取り直さない（本文もそのまま）。
    await drag(
      tester,
      from: Offset(width * 0.8, 320),
      distance: -width * 0.7,
      total: const Duration(milliseconds: 400),
    );
    expect(onThread(tester), isTrue);
    expect(body(), findsOneWidget);
    // 表に戻ったときの取り直しは 1 回だけ。開き直し（初回取得）は起きない。
    expect(fetcher.calls, lessThanOrEqualTo(callsWhileOpen + 1));
  });

  testWidgets('一覧からさらに無い側へ引いても一覧面がずれない', (tester) async {
    await openThread(tester);
    final width = tester.getSize(find.byType(ThreadListScreen)).width;

    await drag(
      tester,
      from: tester.getCenter(body()),
      distance: width * 0.7,
      total: const Duration(milliseconds: 400),
    );
    expect(onThread(tester), isFalse);

    final list = find.byType(CustomScrollView).first;
    final before = tester.getTopLeft(list).dx;
    final gesture = await drag(
      tester,
      from: Offset(width * 0.35, 320),
      distance: 160,
      total: const Duration(milliseconds: 300),
      release: false,
    );

    expect(tester.getTopLeft(list).dx, before);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('弾けば半分に届かなくても一覧に戻る', (tester) async {
    await openThread(tester);

    await drag(
      tester,
      from: tester.getCenter(body()),
      distance: 150,
      total: const Duration(milliseconds: 60),
    );

    expect(onThread(tester), isFalse);
  });

  // 以前は指を置いてから 450ms でスワイプの追跡を打ち切っていたため、ゆっくり
  // 引くと戻れなかった。追従式では引いた距離と速さだけで決まる。
  testWidgets('1 秒かけて引いても一覧に戻る', (tester) async {
    await openThread(tester);
    final width = tester.getSize(find.byType(ThreadListScreen)).width;

    await drag(
      tester,
      from: tester.getCenter(body()),
      distance: width * 0.7,
      total: const Duration(milliseconds: 1000),
    );

    expect(onThread(tester), isFalse);
  });

  testWidgets('一覧へ戻ってまた開くと、読んでいた位置がそのまま', (tester) async {
    // 長めのスレを開き、下の方まで読む。
    final many = <int>[];
    for (var i = 1; i <= 60; i++) {
      many.addAll(
        datLine(
          '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文$i <>'
          '${i == 1 ? '長いスレ' : ''}',
        ),
      );
    }
    final fetcher = QueueFetcher([
      ok(_win31j.encode('1.dat<>長いスレ (60)\n')),
      ok(many),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('長いスレ'));
    await tester.pumpAndSettle();

    await tester.drag(
      find.textContaining('本文1', findRichText: true).first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    // 今見えているレスを覚えておく。
    final visible = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .where((t) => t.contains('本文'))
        .toList();
    expect(visible, isNotEmpty);

    // 一覧へ戻ってから、また開く。
    await drag(
      tester,
      from: const Offset(240, 320),
      distance: 600,
      total: const Duration(milliseconds: 300),
    );
    expect(onThread(tester), isFalse);
    await drag(
      tester,
      from: const Offset(600, 320),
      distance: -600,
      total: const Duration(milliseconds: 300),
    );
    expect(onThread(tester), isTrue);

    // 離れたときに見えていたレスがそのまま見えている（先頭へ戻らない）。
    final after = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .where((t) => t.contains('本文'))
        .toList();
    expect(after.first, visible.first);
  });

  testWidgets('縦スクロールでは戻らない', (tester) async {
    await openThread(tester);

    await tester.drag(body(), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(onThread(tester), isTrue);
  });
}
