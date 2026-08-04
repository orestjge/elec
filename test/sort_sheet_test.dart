import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_sort_settings.dart';
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
  Widget app(ThreadSortSettings sortSettings) => MaterialApp(
    home: ThreadListScreen(
      fetcher: StubFetcher(),
      pollInterval: const Duration(seconds: 60),
      readHistory: ReadHistory(MemoryReadHistoryStorage()),
      sortSettings: sortSettings,
    ),
  );

  Future<ThreadSortSettings> settings([String? saved]) async {
    final s = ThreadSortSettings(MemoryThreadSortSettingsStorage(saved));
    await s.load();
    return s;
  }

  testWidgets('並べ替えシートに見出し・項目・説明が出る', (tester) async {
    await tester.pumpWidget(app(await settings()));
    await tester.pumpAndSettle();

    // AppBar の並べ替えボタンをタップ。
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();

    // シートの見出しと各項目・説明が見える。
    expect(find.text('並べ替え'), findsOneWidget);
    expect(find.text('レスが新しいスレ順'), findsOneWidget);
    expect(find.text('初めて見るスレ、新着レスのあるスレ、既読スレの順に優先して表示します。'), findsOneWidget);
    expect(find.text('1日あたりのレス数が多い順'), findsOneWidget);
    expect(find.text('レスの多い順'), findsOneWidget);
    expect(find.text('新しく立った順'), findsOneWidget);

    // 別の項目を選ぶとシートが閉じる。
    await tester.tap(find.text('レス数'));
    await tester.pumpAndSettle();
    expect(find.text('並べ替え'), findsNothing);
  });

  testWidgets('現行で選んだ並びは保存され、次に開いたときの既定になる', (tester) async {
    final store = MemoryThreadSortSettingsStorage();
    final sortSettings = ThreadSortSettings(store);
    await sortSettings.load();

    await tester.pumpWidget(app(sortSettings));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('勢い'));
    await tester.pumpAndSettle();

    expect(store.name, 'momentum');

    // 保存済みの並びで開き直すと、最初からそれが選ばれている。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(app(await settings(store.name)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    final selected = tester.widget<ListTile>(
      find.ancestor(of: find.text('勢い'), matching: find.byType(ListTile)),
    );
    expect(selected.selected, isTrue);
  });

  testWidgets('履歴で選んだ並びは覚えない', (tester) async {
    final store = MemoryThreadSortSettingsStorage();
    final sortSettings = ThreadSortSettings(store);
    await sortSettings.load();

    await tester.pumpWidget(app(sortSettings));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('勢い'));
    await tester.pumpAndSettle();

    expect(store.name, isNull);
  });
}
