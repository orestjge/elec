import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();
List<int> datLine(String s) => [..._win31j.encode(s), 0x0A];

/// 取得のたびに次の応答を返し、呼ばれた回数を数える。
class CountingFetcher implements HttpFetcher {
  CountingFetcher(this._responses);
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
  List<int> res(int n) => datLine(
    '名無し<><>2025/11/03(月) 02:14:5$n.907 ID:aaa<> 本文$n <>'
    '${n == 1 ? 'スレタイ' : ''}',
  );

  /// [active] を外から切り替えられるスレ画面。
  Widget app({
    required HttpFetcher fetcher,
    required ReadHistory history,
    required bool active,
  }) => MaterialApp(
    home: ThreadScreen(
      threadKey: '1762103691',
      threadTitle: 'テストスレ',
      fetcher: fetcher,
      pollInterval: const Duration(seconds: 5),
      readHistory: history,
      active: active,
    ),
  );

  testWidgets('控えている間は更新を止め、表に戻ると取り直す', (tester) async {
    final fetcher = CountingFetcher([
      ok([...res(1), ...res(2)]),
    ]);
    final history = ReadHistory(MemoryReadHistoryStorage());
    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: true),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本文1', findRichText: true), findsOneWidget);

    // 表示中はポーリングが回る。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final whileActive = fetcher.calls;
    expect(whileActive, greaterThan(1));

    // 控えに回す。以降はポーリングしない。
    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: false),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(fetcher.calls, whileActive, reason: '控えている間は取りに行かない');

    // 本文は残ったまま（閉じていないので読み込み直しにならない）。
    expect(find.textContaining('本文1', findRichText: true), findsOneWidget);

    // 表に戻すと取り直し、ポーリングも再開する。
    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: true),
    );
    await tester.pumpAndSettle();
    expect(fetcher.calls, greaterThan(whileActive));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('本文1', findRichText: true), findsOneWidget);
  });

  testWidgets('控えに回った時点で既読位置を保存する', (tester) async {
    final fetcher = CountingFetcher([
      ok([...res(1), ...res(2)]),
    ]);
    final history = ReadHistory(MemoryReadHistoryStorage());
    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: true),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: false),
    );
    await tester.pumpAndSettle();

    // 画面ごと閉じたときと同じく、見たところまでが残る。
    expect(history.lastSeen('1762103691'), 2);
  });

  testWidgets('表に戻ると新着ラインを貼り直す', (tester) async {
    // 2 レス見た状態で控えに回し、その間に 2 レス増えている。
    final fetcher = CountingFetcher([
      ok([...res(1), ...res(2)]),
      ok([...res(1), ...res(2), ...res(3), ...res(4)]),
    ]);
    final history = ReadHistory(MemoryReadHistoryStorage());
    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('ここから新着'), findsNothing);

    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: false),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      app(fetcher: fetcher, history: history, active: true),
    );
    await tester.pumpAndSettle();

    // 開き直したときと同じく、控える前に見た位置から下が新着になる。
    expect(find.text('ここから新着'), findsOneWidget);
    expect(find.textContaining('本文3', findRichText: true), findsOneWidget);
  });
}
