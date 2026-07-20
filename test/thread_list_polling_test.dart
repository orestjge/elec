import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:elec/src/ui/thread_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();
List<int> sjis(String s) => _win31j.encode(s);
List<int> datLine(String s) => [...sjis(s), 0x0A];

List<int> successBody() =>
    sjis('<html><!-- 2ch_X:true --><body>書きこみました</body></html>');

/// 呼ばれるたびに次の GET 応答を返すフェイク。使い切ったら最後の応答を返し続ける。
class QueueFetcher implements HttpFetcher, HttpPoster {
  QueueFetcher(this._responses);
  final List<FetchResponse> _responses;
  int calls = 0;
  int postCalls = 0;
  final List<Map<String, String>> getHeaders = [];

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    getHeaders.add(Map.of(headers));
    final i = calls < _responses.length ? calls : _responses.length - 1;
    calls++;
    return _responses[i];
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    postCalls++;
    return FetchResponse(statusCode: 200, bodyBytes: successBody());
  }
}

FetchResponse subjectOk(String body, String lm) => FetchResponse(
  statusCode: 200,
  bodyBytes: sjis(body),
  headers: {'last-modified': lm},
);
FetchResponse datOk(List<int> body) =>
    FetchResponse(statusCode: 200, bodyBytes: body, headers: const {});

void main() {
  testWidgets('ポーリング間隔ごとに subject.txt を取り、変化を反映する', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>最初のスレ (10)\n', 'LM1'),
      // 15 秒後: 新スレが増える
      subjectOk('1.dat<>最初のスレ (12)\n2.dat<>あとから来たスレ (3)\n', 'LM2'),
      // それ以降は 304（変化なし）
      const FetchResponse(statusCode: 304, bodyBytes: []),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    // 初回ロード完了を待つ。
    await tester.pumpAndSettle();
    expect(find.text('最初のスレ'), findsOneWidget);
    expect(find.text('あとから来たスレ'), findsNothing);
    expect(fetcher.calls, 1);

    // 15 秒進めてポーリングを 1 回発火させる。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(fetcher.calls, 2);
    expect(find.text('あとから来たスレ'), findsOneWidget);

    // さらに 15 秒。304 なので一覧は変わらない。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(fetcher.calls, 3);
    // 304 だったので一覧は 2 件のまま。
    expect(find.text('あとから来たスレ'), findsOneWidget);
  });

  testWidgets('自動更新では並び順を固定し、新スレは末尾に付く（ソート変更で貼り直す）', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>スレA (10)\n2.dat<>スレB (5)\n3.dat<>スレC (3)\n', 'LM1'),
      // ポーリング: C が最新レスで bump 先頭へ変化＋新スレ D が出現。
      subjectOk(
        '3.dat<>スレC (9)\n1.dat<>スレA (10)\n2.dat<>スレB (5)\n4.dat<>スレD (1)\n',
        'LM2',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    List<String> order() => tester
        .widgetList<ThreadTile>(find.byType(ThreadTile))
        .map((w) => w.thread.title)
        .toList();

    expect(order(), ['スレA', 'スレB', 'スレC']);

    // ポーリングで bump 順は C,A,B,D に変わるが、表示は固定のまま。新スレ D
    // だけ末尾に付く。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(order(), ['スレA', 'スレB', 'スレC', 'スレD']);

    // ソート変更（明示操作）では並び順を貼り直す。新着＝スレ番号の新しい順。
    await tester.tap(find.byIcon(Icons.swap_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新着'));
    await tester.pumpAndSettle();
    expect(order(), ['スレD', 'スレC', 'スレB', 'スレA']);
  });

  testWidgets('初回失敗時はエラー表示、再試行で回復する', (tester) async {
    final fetcher = QueueFetcher([
      const FetchResponse(statusCode: 500, bodyBytes: []),
      subjectOk('1.dat<>復活スレ (5)\n', 'LM1'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('読み込みに失敗しました'), findsOneWidget);

    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(find.text('読み込みに失敗しました'), findsNothing);
    expect(find.text('復活スレ'), findsOneWidget);
  });

  testWidgets('スレ立て後は強制更新して自分のスレとして表示する', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>既存スレ (10)\n', 'LM1'),
      subjectOk('2.dat<>立てたスレ (1)\n1.dat<>既存スレ (10)\n', 'LM2'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
          authStore: AuthStore(MemoryTokenStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('スレを立てる'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '立てたスレ');
    await tester.enterText(find.byType(TextField).at(1), '本文');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '立てる'));
    await tester.pumpAndSettle();

    expect(fetcher.postCalls, 1);
    expect(fetcher.getHeaders[1].containsKey('If-Modified-Since'), isFalse);
    expect(history.isOwnThread('2'), isTrue);
    expect(find.text('立てたスレ'), findsOneWidget);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('表示フィルタで履歴とお気に入りを切り替える', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead('1', 10);
    await history.setFavorite('2', true);
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>履歴スレ (10)\n2.dat<>お気に入りスレ (5)\n', 'LM1'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('履歴スレ'), findsOneWidget);
    expect(find.text('お気に入りスレ'), findsOneWidget);

    await tester.tap(find.text('現行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('お気に入り').last);
    await tester.pumpAndSettle();
    expect(find.text('履歴スレ'), findsNothing);
    expect(find.text('お気に入りスレ'), findsOneWidget);

    await tester.tap(find.text('お気に入り'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('履歴'));
    await tester.pumpAndSettle();
    expect(find.text('履歴スレ'), findsOneWidget);
    expect(find.text('お気に入りスレ'), findsNothing);
  });

  testWidgets('履歴は既定で最後に見た順に並ぶ', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final history = ReadHistory(MemoryReadHistoryStorage(), now: () => now);
    await history.markOpenedThread(
      const ThreadSummary(key: '1', title: 'スレ壱', resCount: 10, capName: null),
    );
    now = DateTime.fromMillisecondsSinceEpoch(2000);
    await history.markOpenedThread(
      const ThreadSummary(key: '2', title: 'スレ弐', resCount: 5, capName: null),
    );
    // subject では 1.dat（スレ壱）が先、2.dat（スレ弐）が後。
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>スレ壱 (10)\n2.dat<>スレ弐 (5)\n', 'LM1'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 履歴表示に切り替える。
    await tester.tap(find.text('現行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('履歴').last);
    await tester.pumpAndSettle();

    // 最後に開いたスレ弐が上（subject の並びとは逆）。
    final yLast = tester.getTopLeft(find.text('スレ弐')).dy;
    final yFirst = tester.getTopLeft(find.text('スレ壱')).dy;
    expect(yLast, lessThan(yFirst));
  });

  testWidgets('既読スレを長押しして履歴から消せる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead('1', 10);
    final fetcher = QueueFetcher([subjectOk('1.dat<>既読スレ (10)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(history.isRead('1'), isTrue);

    await tester.longPress(find.text('既読スレ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('履歴から消す'));
    await tester.pumpAndSettle();

    expect(history.isRead('1'), isFalse);
  });

  testWidgets('長押しメニューからお気に入りを追加・解除できる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final fetcher = QueueFetcher([subjectOk('1.dat<>対象スレ (10)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('対象スレ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('お気に入りに追加'));
    await tester.pumpAndSettle();
    expect(history.isFavorite('1'), isTrue);

    await tester.longPress(find.text('対象スレ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('お気に入りを解除'));
    await tester.pumpAndSettle();
    expect(history.isFavorite('1'), isFalse);
  });

  testWidgets('未読スレの長押しには履歴削除を出さない', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>未読スレ (10)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('未読スレ'));
    await tester.pumpAndSettle();
    expect(find.text('履歴から消す'), findsNothing);
  });

  testWidgets('履歴とお気に入りでは subject に無い保存済みスレも表示する', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.rememberThread(
      const ThreadSummary(
        key: '9',
        title: 'dat落ち履歴スレ',
        resCount: 100,
        capName: null,
      ),
    );
    await history.markRead('9', 100);
    await history.rememberThread(
      const ThreadSummary(
        key: '8',
        title: 'dat落ちお気に入りスレ',
        resCount: 80,
        capName: null,
      ),
    );
    await history.setFavorite('8', true);
    final fetcher = QueueFetcher([subjectOk('1.dat<>現行スレ (10)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('現行スレ'), findsOneWidget);
    expect(find.text('dat落ち履歴スレ'), findsNothing);
    expect(find.text('dat落ちお気に入りスレ'), findsNothing);

    await tester.tap(find.text('現行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('履歴'));
    await tester.pumpAndSettle();
    expect(find.text('dat落ち履歴スレ'), findsOneWidget);
    expect(find.text('dat落ち'), findsOneWidget);
    expect(find.text('dat落ちお気に入りスレ'), findsNothing);

    await tester.tap(find.text('履歴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('お気に入り'));
    await tester.pumpAndSettle();
    expect(find.text('dat落ち履歴スレ'), findsNothing);
    expect(find.text('dat落ちお気に入りスレ'), findsOneWidget);
    expect(find.text('dat落ち'), findsOneWidget);
  });

  testWidgets('1000 到達スレは完走として表示する', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>完走スレ (1000)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('完走スレ'), findsOneWidget);
    expect(find.text('完走'), findsOneWidget);
  });

  testWidgets('検索欄でスレタイを絞り込む', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>料理スレ (10)\n2.dat<>野球スレ (5)\n', 'LM1'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('料理スレ'), findsOneWidget);
    expect(find.text('野球スレ'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '料理');
    await tester.pumpAndSettle();

    expect(find.text('料理スレ'), findsOneWidget);
    expect(find.text('野球スレ'), findsNothing);
  });

  testWidgets('一覧を左に引っ張ると直近に見たスレを開く', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markLastViewedThread(
      const ThreadSummary(key: '1', title: '直近スレ', resCount: 1, capName: null),
    );
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>直近スレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>直近スレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('1レス'), findsOneWidget);
    expect(find.textContaining('本文', findRichText: true), findsOneWidget);
  });

  testWidgets('一覧で長押し後の左ドラッグでは直近スレを開かない', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markLastViewedThread(
      const ThreadSummary(key: '1', title: '直近スレ', resCount: 1, capName: null),
    );
    final fetcher = QueueFetcher([subjectOk('1.dat<>直近スレ (1)\n', 'LM1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveBy(const Offset(-500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('エッヂ'), findsWidgets);
    expect(find.text('直近スレ'), findsOneWidget);
    expect(find.text('1レス'), findsNothing);
  });

  testWidgets('一覧から開いたスレはすぐ履歴と既読扱いになる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>すぐ履歴スレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>すぐ履歴スレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('すぐ履歴スレ'));
    await tester.pump();

    expect(history.isRead('1'), isTrue);
    expect(history.lastSeen('1'), 0);
    expect(history.lastViewedThread?.toSummary().title, 'すぐ履歴スレ');
  });

  testWidgets('スレ画面を右に引っ張ると一覧に戻る', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>戻れるスレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>戻れるスレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('戻れるスレ'));
    await tester.pumpAndSettle();
    expect(find.text('1レス'), findsOneWidget);

    final gesture = await tester.startGesture(const Offset(240, 320));
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('エッヂ'), findsWidgets);
    expect(find.text('戻れるスレ'), findsOneWidget);
    expect(find.text('1レス'), findsNothing);
  });

  testWidgets('入力欄フォーカス中でも一覧側スワイプで戻れる', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>入力中スレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>入力中スレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('入力中スレ'));
    await tester.pumpAndSettle();

    // 入力欄にフォーカスを当てる（キーボード表示中を模す）。
    await tester.tap(find.widgetWithText(TextField, 'レスを書く'));
    await tester.pumpAndSettle();

    // 一覧側（本文付近）から右スワイプすると戻れる。
    final gesture = await tester.startGesture(const Offset(240, 200));
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('エッヂ'), findsWidgets);
    expect(find.text('1レス'), findsNothing);
  });

  testWidgets('スレ画面で長押し後の右ドラッグでは一覧に戻らない', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>選択できるスレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>選択できるスレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('選択できるスレ'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.textContaining('本文', findRichText: true)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('1レス'), findsOneWidget);
    expect(find.textContaining('本文', findRichText: true), findsOneWidget);
  });

  testWidgets('スレ本文の文字選択中は右ドラッグで一覧に戻らない', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>選択中スレ (1)\n', 'LM1'),
      datOk(datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>選択中スレ')),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: fetcher,
          pollInterval: const Duration(seconds: 15),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('選択中スレ'));
    await tester.pumpAndSettle();

    final bodyFinder = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.textSpan?.toPlainText().contains('本文') == true,
    );
    final body = tester.widget<SelectableText>(bodyFinder);
    body.onSelectionChanged?.call(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      SelectionChangedCause.longPress,
    );
    await tester.pump();

    await tester.drag(bodyFinder, const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(find.text('1レス'), findsOneWidget);
    expect(bodyFinder, findsOneWidget);
  });
}
