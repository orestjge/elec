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
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新着'));
    await tester.pumpAndSettle();
    expect(order(), ['スレD', 'スレC', 'スレB', 'スレA']);
  });

  testWidgets('一覧で見たスレは、次に開いたときは新顔でなくなる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());

    Future<void> openList(WidgetTester tester, String subject) async {
      // いったん画面を閉じてから開き直す（State を作り直させる）。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: ThreadListScreen(
            fetcher: QueueFetcher([subjectOk(subject, 'LM1')]),
            pollInterval: const Duration(seconds: 15),
            readHistory: history,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // スレ面が前に出ている間、一覧は生きたまま裏に控える（offstage）ので、
    // そこも拾えるようにしておく。
    ThreadSeen seenOf(String title) => tester
        .widget<ThreadTile>(
          find.widgetWithText(ThreadTile, title, skipOffstage: false),
        )
        .seen;

    // 初回。どれも一覧で見たことがない＝全部が新顔。
    await openList(tester, '1.dat<>スレA (10)\n2.dat<>スレB (5)\n');
    expect(seenOf('スレA'), ThreadSeen.fresh);
    expect(seenOf('スレB'), ThreadSeen.fresh);

    // 見ている間は点が変わらない（目の前で表示が動かない）。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(seenOf('スレA'), ThreadSeen.fresh);

    // 開き直すと、さっき目に入ったぶんは新顔でなくなる。新しく立った C だけ新顔。
    await openList(tester, '1.dat<>スレA (12)\n2.dat<>スレB (5)\n3.dat<>スレC (1)\n');
    expect(seenOf('スレA'), ThreadSeen.listed);
    expect(seenOf('スレB'), ThreadSeen.listed);
    expect(seenOf('スレC'), ThreadSeen.fresh);

    // 開いたスレは「開いた」状態になる（一覧は控えたまま生きている）。
    await tester.tap(find.text('スレA'));
    await tester.pumpAndSettle();
    expect(seenOf('スレA'), ThreadSeen.opened);
  });

  testWidgets('見るべき順は 初見 → 新着あり → 既読 → 見送ったスレ に並べる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    // 一覧で見たことがある＝初見ではない（4 は初見のまま）。
    await history.markListed(['1', '2', '3', '5']);
    // 開いたスレ。2 は開いた後にレスが増えた＝新着あり、3 は追いついている。
    await history.markOpenedThread(
      const ThreadSummary(key: '2', title: 'スレB', resCount: 8, capName: null),
    );
    await history.markRead('2', 8);
    await history.markOpenedThread(
      const ThreadSummary(key: '3', title: 'スレC', resCount: 5, capName: null),
    );
    await history.markRead('3', 5);

    final fetcher = QueueFetcher([
      subjectOk(
        // bump 順（サーバ順）。この中で 4 群に分かれる。
        '1.dat<>スレA (10)\n'
        '2.dat<>スレB (12)\n' // 開いた後に +4
        '3.dat<>スレC (5)\n' // 追いついている
        '4.dat<>スレD (2)\n' // 一覧でも初見
        '5.dat<>スレE (7)\n', // 一覧で見たが開いていない
        'LM1',
      ),
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

    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('見るべき順'));
    await tester.pumpAndSettle();

    final order = tester
        .widgetList<ThreadTile>(find.byType(ThreadTile))
        .map((w) => w.thread.title)
        .toList();
    // D=初見 → B=新着あり → C=既読 → A,E=見送った（各群は bump 順のまま）。
    expect(order, ['スレD', 'スレB', 'スレC', 'スレA', 'スレE']);
  });

  testWidgets('末尾に付いた新スレは、その後の自動更新で入れ替わらない', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>スレA (10)\n', 'LM1'),
      // 新スレ B・C が出現（サーバ順は C が先）。
      subjectOk('3.dat<>スレC (2)\n2.dat<>スレB (4)\n1.dat<>スレA (10)\n', 'LM2'),
      // 次の更新でサーバ順が入れ替わり、さらに D も出る。
      subjectOk(
        '2.dat<>スレB (9)\n1.dat<>スレA (11)\n4.dat<>スレD (1)\n3.dat<>スレC (2)\n',
        'LM3',
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

    expect(order(), ['スレA']);

    // 現れた順（サーバ順）に末尾へ積まれる。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(order(), ['スレA', 'スレC', 'スレB']);

    // サーバ順が変わっても、積んだ場所からは動かない。D だけがさらに末尾へ。
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(order(), ['スレA', 'スレC', 'スレB', 'スレD']);
  });

  testWidgets('自動更新で subject から落ちたスレは、dat落ちチップを付けて同じ場所に残す', (tester) async {
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>スレA (10)\n2.dat<>スレB (5)\n3.dat<>スレC (3)\n', 'LM1'),
      // ポーリング: B が subject.txt から消える。
      subjectOk('1.dat<>スレA (11)\n3.dat<>スレC (3)\n', 'LM2'),
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
    final beforeC = tester.getTopLeft(find.text('スレC')).dy;

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();

    // 行は残り、下の行も繰り上がらない。落ちたことはチップで分かる。
    expect(order(), ['スレA', 'スレB', 'スレC']);
    expect(tester.getTopLeft(find.text('スレC')).dy, beforeC);
    expect(find.text('dat落ち'), findsOneWidget);
    expect(
      tester
          .widget<ThreadTile>(find.widgetWithText(ThreadTile, 'スレB'))
          .thread
          .resCount,
      5, // 最後に見えていた姿のまま
    );

    // 手動更新（並べ替え直し）では消える。
    await tester.fling(find.text('スレA'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(order(), ['スレA', 'スレC']);
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

    await tester.tap(find.byTooltip('スレを立てる'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '立てたスレ');
    await tester.enterText(find.byType(TextField).at(1), '本文');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pumpAndSettle();

    expect(fetcher.postCalls, 1);
    expect(fetcher.getHeaders[1].containsKey('If-Modified-Since'), isFalse);
    expect(history.isOwnThread('2'), isTrue);
    expect(find.text('立てたスレ'), findsOneWidget);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('タイトルにエンティティ化される文字があっても自分のスレと判定する', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    // subject 上ではタイトルがエンティティ化される（A&B<C → A&amp;B&lt;C）。
    final fetcher = QueueFetcher([
      subjectOk('1.dat<>既存スレ (10)\n', 'LM1'),
      subjectOk('2.dat<>A&amp;B&lt;C (1)\n1.dat<>既存スレ (10)\n', 'LM2'),
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

    await tester.tap(find.byTooltip('スレを立てる'));
    await tester.pumpAndSettle();
    // 入力は生の文字列。
    await tester.enterText(find.byType(TextField).at(0), 'A&B<C');
    await tester.enterText(find.byType(TextField).at(1), '本文');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pumpAndSettle();

    expect(history.isOwnThread('2'), isTrue);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('スレ立て画面は右スワイプで戻り、下書きを維持する', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>既存スレ (10)\n', 'LM1')]);

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

    await tester.tap(find.byTooltip('スレを立てる'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '途中のタイトル');
    await tester.enterText(find.byType(TextField).at(1), '途中の本文');
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(24, 320));
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('既存スレ'), findsOneWidget);
    expect(find.text('スレッドタイトル'), findsNothing);

    await tester.tap(find.byTooltip('スレを立てる'));
    await tester.pumpAndSettle();

    final title = tester.widget<TextField>(find.byType(TextField).at(0));
    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(title.controller!.text, '途中のタイトル');
    expect(body.controller!.text, '途中の本文');
  });

  testWidgets('スレ立てボタンは中間サイズで表示する', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>既存スレ (10)\n', 'LM1')]);

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

    expect(tester.getSize(find.byTooltip('スレを立てる')), const Size.square(48));
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

    await tester.tap(find.byTooltip('お気に入り'));
    await tester.pumpAndSettle();
    expect(find.text('履歴スレ'), findsNothing);
    expect(find.text('お気に入りスレ'), findsOneWidget);

    await tester.tap(find.byTooltip('履歴'));
    await tester.pumpAndSettle();
    expect(find.text('履歴スレ'), findsOneWidget);
    expect(find.text('お気に入りスレ'), findsNothing);
  });

  testWidgets('狭い画面でも下部バーからはみ出さない', (tester) async {
    // 幅 320（小型端末）で、表示チップ 4 つ＋検索を並べてもはみ出さないこと。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.setFavorite('1', true);
    final fetcher = QueueFetcher([subjectOk('1.dat<>スレ (10)\n', 'LM1')]);

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

    await tester.tap(find.byTooltip('お気に入り'));
    await tester.pumpAndSettle();

    // 4 つのチップと検索が並んだままであること。
    for (final label in ['現行', '新着あり', '履歴', 'お気に入り']) {
      expect(find.byTooltip(label), findsOneWidget);
    }
    // レイアウトのオーバーフロー（黄黒の縞）が出ていないこと。
    expect(tester.takeException(), isNull);
  });

  testWidgets('表示を切り替えてもチップの位置は動かない', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>スレ (10)\n', 'LM1')]);

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

    const labels = ['現行', '新着あり', '履歴', 'お気に入り'];
    List<Rect> chipRects() => [
      for (final l in labels) tester.getRect(find.byTooltip(l)),
    ];

    final before = chipRects();
    // どれを選んでも、選択チップが伸び縮みして隣がズレたりしない。
    for (final l in labels.reversed) {
      await tester.tap(find.byTooltip(l));
      await tester.pumpAndSettle();
      expect(chipRects(), before, reason: '$l を選んだあと');
    }
  });

  testWidgets('新着あり表示は開いたスレのうち未読レスがあるものだけ残す', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    // 開いて 8 レスまで読んだスレ。subject では 10 レスなので新着 2。
    await history.markRead('1', 8);
    // 開いて全部読んだスレ。新着なし。
    await history.markRead('2', 5);
    // dat 落ちした保存済みスレ。保存時のレス数が既読を上回るので新着あり。
    await history.rememberThread(
      const ThreadSummary(
        key: '9',
        title: 'dat落ち新着スレ',
        resCount: 30,
        capName: null,
      ),
    );
    await history.markRead('9', 28);
    final fetcher = QueueFetcher([
      subjectOk(
        '1.dat<>新着ありスレ (10)\n2.dat<>読み切ったスレ (5)\n3.dat<>未読スレ (7)\n',
        'LM1',
      ),
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
    expect(find.text('新着ありスレ'), findsOneWidget);
    expect(find.text('未読スレ'), findsOneWidget);

    await tester.tap(find.byTooltip('新着あり'));
    await tester.pumpAndSettle();

    expect(find.text('新着ありスレ'), findsOneWidget);
    expect(find.text('dat落ち新着スレ'), findsOneWidget);
    // 読み切ったスレも、一度も開いていないスレも出ない。
    expect(find.text('読み切ったスレ'), findsNothing);
    expect(find.text('未読スレ'), findsNothing);
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
    await tester.tap(find.byTooltip('履歴'));
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

    await tester.tap(find.byTooltip('履歴'));
    await tester.pumpAndSettle();
    expect(find.text('dat落ち履歴スレ'), findsOneWidget);
    expect(find.text('dat落ち'), findsOneWidget);
    expect(find.text('dat落ちお気に入りスレ'), findsNothing);

    await tester.tap(find.byTooltip('お気に入り'));
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

  testWidgets('検索を開いても虫めがねと文言の開始位置は動かない', (tester) async {
    final fetcher = QueueFetcher([subjectOk('1.dat<>スレ (10)\n', 'LM1')]);

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

    // 閉じているとき＝検索チップの中のアイコン。
    final chipIcon = tester.getRect(find.byIcon(Icons.search));
    final chipLabel = tester.getRect(find.text('検索'));

    await tester.tap(find.byTooltip('スレ検索'));
    await tester.pumpAndSettle();

    // 開いたあと＝入力欄の先頭アイコンとヒント。左右の位置と縦中心が動かず、
    // ヒントも閉じている時の「検索」と同じ左端から始まること。
    final fieldIcon = tester.getRect(find.byIcon(Icons.search));
    expect(fieldIcon.left, chipIcon.left);
    expect(fieldIcon.right, chipIcon.right);
    expect(fieldIcon.center.dy, chipIcon.center.dy);
    expect(tester.getRect(find.text('スレタイ検索')).left, chipLabel.left);
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

    await tester.tap(find.byTooltip('スレ検索'));
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

  testWidgets('一覧を右にスワイプすると板一覧（ドロワー）が開く', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final fetcher = QueueFetcher([subjectOk('1.dat<>スレ (1)\n', 'LM1')]);

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

    // ドロワーは最初は閉じている。
    expect(find.text('URLで板を追加'), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(500, 0));
    await tester.pumpAndSettle();

    // 板追加の導線＝ドロワーが開いている。
    expect(find.text('URLで板を追加'), findsOneWidget);
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

    await tester.drag(
      find.textContaining('本文', findRichText: true),
      const Offset(500, 0),
    );
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
    await tester.drag(
      find.textContaining('本文', findRichText: true),
      const Offset(500, 0),
    );
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

    // 長押しはレスメニューを開く操作なので、そのまま横に引いても一覧には戻らない。
    expect(find.text('本文をコピー'), findsOneWidget);
    expect(find.text('1レス'), findsOneWidget);
    expect(find.text('エッヂ'), findsNothing);
  });

  // 本文の選択は一覧上ではなくレスメニューの中で行う（一覧側は bodySelectable:
  // false）。その選択中に横へ引いても一覧に戻らないことを見る。
  testWidgets('レスメニューで本文を選択中は右ドラッグで一覧に戻らない', (tester) async {
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

    // 本文長押しでレスメニューを開く。選択できる本文はこの中にある。
    await tester.longPress(find.textContaining('本文', findRichText: true));
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
    expect(find.text('エッヂ'), findsNothing);
    expect(bodyFinder, findsOneWidget);
  });
}
