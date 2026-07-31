import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();

class StubFetcher implements HttpFetcher {
  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async => FetchResponse(
    statusCode: 200,
    bodyBytes: _win31j.encode('1.dat<>テスト (5)\n'),
    headers: const {'last-modified': 'LM'},
  );
}

void main() {
  testWidgets('並べ替えシートに見出し・項目・説明が出る', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: StubFetcher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar の並べ替えボタンをタップ。
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();

    // シートの見出しと各項目・説明が見える。
    expect(find.text('並べ替え'), findsOneWidget);
    expect(find.text('レスが新しいスレ順'), findsOneWidget);
    expect(
      find.text('初めて見るスレ、新着レスのあるスレ、既読スレの順に優先して表示します。'),
      findsOneWidget,
    );
    expect(find.text('1日あたりのレス数が多い順'), findsOneWidget);
    expect(find.text('レスの多い順'), findsOneWidget);
    expect(find.text('新しく立った順'), findsOneWidget);

    // 別の項目を選ぶとシートが閉じる。
    await tester.tap(find.text('レス数'));
    await tester.pumpAndSettle();
    expect(find.text('並べ替え'), findsNothing);
  });
}
