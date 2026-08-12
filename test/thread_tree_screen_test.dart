import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/settings_screen.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/src/ui/thread_tree.dart';
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
FetchResponse partial(List<int> body) =>
    FetchResponse(statusCode: 206, bodyBytes: body, headers: const {});

/// レス [n] 本ぶんの dat。[bodies] に無い番号は `レスN` になる。
List<int> resLine(int i, Map<int, String> bodies) => datLine(
  '名無し<><>2025/11/03(月) 02:14:5$i.907 ID:aaa<> '
  '${bodies[i] ?? 'レス$i'} <>${i == 1 ? 'スレタイ' : ''}',
);

List<int> dat(int n, [Map<int, String> bodies = const {}]) => [
  for (var i = 1; i <= n; i++) ...resLine(i, bodies),
];

void main() {
  const threadKey = '1762103691';

  Future<ThreadViewSettings> treeSettings() async {
    final settings = ThreadViewSettings(MemoryThreadViewSettingsStorage());
    await settings.setLayout(ThreadLayout.tree);
    return settings;
  }

  /// 番号順に切り替えた設定。既定はツリーなので、番号順は明示して作る。
  Future<ThreadViewSettings> numberSettings() async {
    final settings = ThreadViewSettings(MemoryThreadViewSettingsStorage());
    await settings.setLayout(ThreadLayout.number);
    return settings;
  }

  Widget app(
    HttpFetcher f, {
    required ReadHistory history,
    required ThreadViewSettings view,
  }) => MaterialApp(
    home: ThreadScreen(
      threadKey: threadKey,
      threadTitle: 'テストスレ',
      fetcher: f,
      pollInterval: const Duration(seconds: 5),
      readHistory: history,
      threadViewSettings: view,
    ),
  );

  /// 画面に上から並んでいるレス番号（引用行は含まない）。
  ///
  /// [ScrollablePositionedList] はウィジェット木の順が見た目の順とは限らない
  /// （着地位置より前は逆向きのリストに入る）ので、実際の縦位置で並べ直す。
  List<int> shownNumbers(WidgetTester tester) {
    final placed = [
      for (final w in tester.widgetList<PostItem>(find.byType(PostItem)))
        (top: tester.getTopLeft(find.byWidget(w)).dy, number: w.res.number),
    ]..sort((a, b) => a.top.compareTo(b.top));
    return [for (final p in placed) p.number];
  }

  /// 画面に上から並んでいる引用行のレス番号（[shownNumbers] と同じく縦位置順）。
  List<int> shownQuotedNumbers(WidgetTester tester) {
    final placed = [
      for (final w in tester.widgetList<QuotedResRow>(
        find.byType(QuotedResRow),
      ))
        (top: tester.getTopLeft(find.byWidget(w)).dy, number: w.res.number),
    ]..sort((a, b) => a.top.compareTo(b.top));
    return [for (final p in placed) p.number];
  }

  PostItem postItemFor(WidgetTester tester, int number) => tester
      .widgetList<PostItem>(find.byType(PostItem))
      .firstWhere((w) => w.res.number == number);

  testWidgets('未読スレはツリー順で並べる', (tester) async {
    final f = QueueFetcher([
      ok(dat(4, const {2: '>>1 レス1へ', 4: '>>2 レス2へ'})),
    ]);
    await tester.pumpWidget(
      app(
        f,
        history: ReadHistory(MemoryReadHistoryStorage()),
        view: await treeSettings(),
      ),
    );
    await tester.pumpAndSettle();

    // 4 は 2 の返信なので 2 の直下へ。返信していない 3 は根のまま後ろに残る。
    expect(shownNumbers(tester), [1, 2, 4, 3]);
    expect(find.byType(QuotedResRow), findsNothing);
  });

  testWidgets('番号順設定ではこれまで通り dat の順で並べる', (tester) async {
    final f = QueueFetcher([
      ok(dat(4, const {2: '>>1 レス1へ', 4: '>>2 レス2へ'})),
    ]);
    await tester.pumpWidget(
      app(
        f,
        history: ReadHistory(MemoryReadHistoryStorage()),
        view: await numberSettings(),
      ),
    );
    await tester.pumpAndSettle();

    expect(shownNumbers(tester), [1, 2, 3, 4]);
  });

  testWidgets('番号順でも返信レスの手前に返信先を再掲する', (tester) async {
    final f = QueueFetcher([
      ok(dat(4, const {4: '>>1 レス1へ'})),
    ]);
    await tester.pumpWidget(
      app(
        f,
        history: ReadHistory(MemoryReadHistoryStorage()),
        view: await numberSettings(),
      ),
    );
    await tester.pumpAndSettle();

    // 並びは dat のまま。4 の指し先（1）は画面のずっと上なので手前に再掲する。
    expect(shownNumbers(tester), [1, 2, 3, 4]);
    final quote = tester.widget<QuotedResRow>(find.byType(QuotedResRow));
    expect(quote.res.number, 1);
    expect(
      find.descendant(
        of: find.byType(QuotedResRow),
        matching: find.textContaining('レス1'),
      ),
      findsOneWidget,
    );
    // 引用行は 4 のすぐ上（返信の手前）。
    expect(
      tester.getTopLeft(find.byType(QuotedResRow)).dy,
      lessThan(tester.getTopLeft(find.byWidget(postItemFor(tester, 4))).dy),
    );
  });

  testWidgets('番号順では返信先がすぐ上にあっても毎回再掲する', (tester) async {
    final f = QueueFetcher([
      ok(dat(4, const {2: '>>1 レス1へ', 3: '>>2 レス2へ'})),
    ]);
    await tester.pumpWidget(
      app(
        f,
        history: ReadHistory(MemoryReadHistoryStorage()),
        view: await numberSettings(),
      ),
    );
    await tester.pumpAndSettle();

    // 返信レスは 2 と 3 の 2 つ。返信でないレスには引用行が付かない。
    expect(shownNumbers(tester), [1, 2, 3, 4]);
    expect(shownQuotedNumbers(tester), [1, 2]);
  });

  testWidgets('既読ぶんだけツリーにし、新着は下へ積む', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 3);
    final f = QueueFetcher([
      ok(dat(5, const {3: '>>1 既読の返信', 5: '>>1 新着の返信'})),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();

    // 1・3 はツリー（3 は 1 の下）、4・5 は新着なので番号順のまま下に積む。
    expect(shownNumbers(tester), [1, 3, 2, 4, 5]);
    expect(find.text('ここから新着'), findsOneWidget);
    // 5 の指し先（1）は画面のずっと上なので、手前に薄く再掲する。
    final quote = tester.widget<QuotedResRow>(find.byType(QuotedResRow));
    expect(quote.res.number, 1);
    // 番号は裸で出す（`>>1` だとこの行が 1 への返信に見えてしまう）。
    expect(
      find.descendant(of: find.byType(QuotedResRow), matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(QuotedResRow),
        matching: find.text('>>1'),
      ),
      findsNothing,
    );
    // 日時は出さない。引用行は 1 行に収める添え物なので、置くものを「誰の・何の
    // 話か」——ID の絵と本文の頭——に絞る。
    expect(
      find.descendant(
        of: find.byType(QuotedResRow),
        matching: find.text('11/03 02:14'),
      ),
      findsNothing,
    );
  });

  testWidgets('複数に返しているレスは返信先を全部、間を空けずに重ねて出す', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 3);
    final f = QueueFetcher([
      ok(dat(4, const {4: '>>1 >>2 まとめて返す'})),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();

    // 1 つ目だけでは、残りの相手へ何を返したのか読めない。
    expect(shownQuotedNumbers(tester), [1, 2]);

    // 続く引用行は間を空けずに重ねる。空けると 1 本ずつ別の何かに見える。
    final rows =
        [
          for (final w in tester.widgetList<QuotedResRow>(
            find.byType(QuotedResRow),
          ))
            tester.getRect(find.byWidget(w)),
        ]..sort((a, b) => a.top.compareTo(b.top));
    expect(rows[1].top, rows[0].bottom);
  });

  testWidgets('開いたあとに来たレスはツリーへ挿さず末尾に積む', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 3);
    final full = dat(3);
    final f = QueueFetcher([
      ok(full),
      // 差分で 4（>>1 への返信）が届く（Range 取得なので直前の 1 バイトを重ねる）。
      partial([
        full.last,
        ...resLine(4, const {4: '>>1 追いレス'}),
      ]),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();
    expect(shownNumbers(tester), [1, 2, 3]);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // >>1 への返信でも 1 の下へは入らず、末尾に積む（見落とさないため）。
    expect(shownNumbers(tester), [1, 2, 3, 4]);
    expect(
      tester.widget<QuotedResRow>(find.byType(QuotedResRow)).res.number,
      1,
    );
  });

  testWidgets('新着どうしの返信はあとから来ても親の下でツリーになる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 2);
    final full = dat(3, const {3: '>>1 新着その1'});
    final f = QueueFetcher([
      ok(full),
      partial([
        full.last,
        ...resLine(4, const {4: '無関係な新着'}),
        ...resLine(5, const {5: '>>3 あとから来た返信'}),
      ]),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();
    expect(shownNumbers(tester), [1, 2, 3]);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 5 は末尾ではなく、返信先の 3 の直下へ入る（4 はその下に残る）。
    expect(shownNumbers(tester), [1, 2, 3, 5, 4]);
  });

  testWidgets('同じ引用先の新着は先に来たものと同じまとまりへ入る', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 2);
    final full = dat(3, const {3: '>>1 新着その1'});
    final f = QueueFetcher([
      ok(full),
      partial([
        full.last,
        ...resLine(4, const {4: '無関係な新着'}),
        ...resLine(5, const {5: '>>1 同じ指し先'}),
      ]),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 5 は 4 の下（末尾）ではなく、同じ >>1 を指す 3 の隣へ。引用行は 1 つだけ。
    expect(shownNumbers(tester), [1, 2, 3, 5, 4]);
    expect(find.byType(QuotedResRow), findsOneWidget);
  });

  testWidgets('末尾まで送れば、開き直しても末尾から続く', (tester) async {
    // ツリーは並びが番号順でないので、既読位置は「通り過ぎた行の番号が 1 から
    // 続いているところまで」で進める。見えている行をその都度拾うだけだと、
    // 勢いよく送ったときに行がフレームを跨いで飛び、下まで読んでも既読位置が
    // 途中で止まる（次に開いたとき古い位置と新着ラインへ戻される）。
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 3);
    final view = await treeSettings();
    final f = QueueFetcher([ok(dat(60))]);

    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();
    expect(find.text('ここから新着'), findsOneWidget);

    // 末尾まで一気に送る。
    for (var i = 0; i < 6; i++) {
      await tester.fling(
        find.byType(PostItem).first,
        const Offset(0, -600),
        6000,
      );
      await tester.pumpAndSettle();
    }
    expect(shownNumbers(tester).last, 60);
    expect(history.lastSeen(threadKey), 60);

    // 別のスレを開いて戻ってきた（＝この画面は作り直される）。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();

    // 続きから＝末尾。古い新着ラインも残らない。
    expect(shownNumbers(tester).last, 60);
    expect(find.text('ここから新着'), findsNothing);
  });

  testWidgets('途中まで送ったぶんも既読になる', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final view = await treeSettings();
    final f = QueueFetcher([
      ok(dat(300, const {5: '>>1 返信'})),
    ]);

    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();
    // 末尾までは行かない勢いで送る。
    await tester.fling(
      find.byType(PostItem).first,
      const Offset(0, -600),
      6000,
    );
    await tester.pumpAndSettle();

    final shown = shownNumbers(tester);
    expect(shown.last, lessThan(300)); // まだ途中
    expect(history.lastSeen(threadKey), shown.last);

    // 開き直すと、その続き（新着ライン）から。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();
    expect(find.text('ここから新着'), findsOneWidget);
  });

  testWidgets('読み返して離れたら、既読位置ではなく読み返していた場所へ戻る', (tester) async {
    // 着地を「どこまで読んだか」だけで決めると、末尾まで目を通したあとに戻って
    // 読み返している最中に離れたとき、次はまた末尾へ運ばれる。読んでいた場所は
    // 既読位置とは別に覚える。
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead(threadKey, 300); // 末尾まで読み終えている
    final f = QueueFetcher([ok(dat(300))]);
    final view = await treeSettings();

    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();
    expect(shownNumbers(tester).last, 300, reason: '続き＝末尾から');

    // 少し戻って読み返す。
    for (var i = 0; i < 5; i++) {
      await tester.drag(
        find.byType(PostItem).at(1),
        const Offset(0, 300),
        warnIfMissed: false, // 端まで戻ると掴む行が画面から外れる
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final stopped = shownNumbers(tester);
    expect(stopped.last, lessThan(295), reason: '末尾からは離れていること');

    // 閉じて開き直す。既読位置は 300 のままだが、着地はそこではない。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(history.lastSeen(threadKey), 300);
    await tester.pumpWidget(app(f, history: history, view: view));
    await tester.pumpAndSettle();

    expect(shownNumbers(tester), contains(stopped.last));
  });

  testWidgets('ツリーの上に出てきた新しい番号では既読位置を進めない', (tester) async {
    // 30 は 1 への返信なので 1 のすぐ下に並ぶ。画面に出たからといって
    // 2〜29 を読んだことにはしない（間の未読を読み飛ばしてしまう）。
    final history = ReadHistory(MemoryReadHistoryStorage());
    final f = QueueFetcher([
      ok(dat(30, const {30: '>>1 ずっと下からの返信'})),
    ]);

    await tester.pumpWidget(
      app(f, history: history, view: await treeSettings()),
    );
    await tester.pumpAndSettle();

    final shown = shownNumbers(tester).toSet();
    expect(shown, contains(30));
    // 既読位置は 1 から続いているところまで。
    var contiguous = 0;
    while (shown.contains(contiguous + 1)) {
      contiguous++;
    }
    expect(contiguous, lessThan(30));
    expect(history.lastSeen(threadKey), contiguous);
  });

  testWidgets('設定で並べ方を切り替えると保存され、その場で効く', (tester) async {
    final storage = MemoryThreadViewSettingsStorage();
    final view = ThreadViewSettings(storage);
    // 既定はツリー。切り替えは既定でない側（番号順）を選んで確かめる。
    expect(view.layout, ThreadLayout.tree);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(threadView: view)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-thread-layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('番号順').last);
    await tester.pumpAndSettle();

    expect(view.layout, ThreadLayout.number);
    expect(storage.values['layout'], 'number');
    expect(find.textContaining('番号順'), findsOneWidget);
  });

  testWidgets('設定でレスの見せ方を切り替えると保存され、その場で効く', (tester) async {
    final storage = MemoryThreadViewSettingsStorage();
    final view = ThreadViewSettings(storage);
    // 既定はヘッダにまとめる組み方。切り替えは柱の組み方を選んで確かめる。
    expect(view.resLayout, ResLayout.header);

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(threadView: view)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-res-layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('アイコンを左に大きく').last);
    await tester.pumpAndSettle();

    expect(view.resLayout, ResLayout.gutter);
    expect(storage.values['resLayout'], 'gutter');
    expect(find.textContaining('アイコンを左に大きく'), findsOneWidget);
  });
}
