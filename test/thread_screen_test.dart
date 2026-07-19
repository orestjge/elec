import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/src/net/read_history.dart';
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

void main() {
  final res1 = datLine(
    '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 最初のレス <>スレタイ',
  );
  final res2 = datLine(
    '名無し<><>2025/11/03(月) 02:20:00.000 ID:aaa<> >>1 同じIDの2つ目 <>',
  );
  final res3 = datLine(
    '名無し<><>2025/11/03(月) 03:00:00.000 ID:bbb<> >>1-2 あとから来た <>',
  );
  final over1000 = datLine('1001<><>Over 1000 Thread<>このスレッドは1000を超えました。<>');

  Widget app(HttpFetcher f) => MaterialApp(
    home: ThreadScreen(
      threadKey: '1762103691',
      threadTitle: 'テストスレ',
      fetcher: f,
      pollInterval: const Duration(seconds: 5),
      readHistory: ReadHistory(MemoryReadHistoryStorage()),
    ),
  );

  Widget appWithHistory(HttpFetcher f, ReadHistory history) => MaterialApp(
    home: ThreadScreen(
      threadKey: '1762103691',
      threadTitle: 'テストスレ',
      fetcher: f,
      pollInterval: const Duration(seconds: 5),
      readHistory: history,
    ),
  );

  testWidgets('初回に本文を番号順で表示する', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('最初のレス'), findsOneWidget);
    expect(find.textContaining('同じIDの2つ目', findRichText: true), findsOneWidget);
    // 同一 ID はカウント付きで出る。
    expect(find.text('ID:aaa (2)'), findsWidgets);
    // 初回は新着ライン無し。
    expect(find.text('ここから新着'), findsNothing);
  });

  testWidgets('返信ボタンでコンポーザに >>N が入る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 1 レス目の返信ボタン（ヘッダの reply アイコン）をタップ。
    await tester.tap(find.byIcon(Icons.reply).first);
    await tester.pump();

    expect(find.text('>>1\n'), findsOneWidget); // 入力欄に反映
  });

  testWidgets('ポーリングで新着が付き、新着ラインが出る', (tester) async {
    final full = [...res1, ...res2];
    final f = QueueFetcher([
      ok(full),
      partial([full.last, ...res3]), // 差分で res3 追加
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();
    expect(find.textContaining('あとから来た', findRichText: true), findsNothing);

    // 先頭付近（末尾ではない）で新着が来ると新着ラインが出る想定。
    // テスト環境では hasClients で末尾判定になり得るため、まず 5 秒進める。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(f.calls, 2);
    expect(find.textContaining('あとから来た', findRichText: true), findsOneWidget);
  });

  testWidgets('ID タップで同一 ID のレス一覧シートが出る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // aaa は 2 レス。チップをタップ。
    await tester.tap(find.text('ID:aaa (2)').first);
    await tester.pumpAndSettle();

    // シート見出し。
    expect(find.text('ID:aaa  2レス'), findsOneWidget);
    expect(find.text('返信 2'), findsWidgets);

    await tester.tap(find.text('返信 2').last);
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  3件'), findsOneWidget);
    expect(find.text('ID:aaa  2レス'), findsNothing);
  });

  testWidgets('返信数チップから会話ビューを出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('返信 2'), findsOneWidget);
    await tester.tap(find.text('返信 2').first);
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  3件'), findsOneWidget);
    expect(find.text('最初のレス'), findsWidgets);
    expect(find.textContaining('同じIDの2つ目', findRichText: true), findsWidgets);
    expect(find.textContaining('あとから来た', findRichText: true), findsWidgets);
    expect(find.text('返信先 >>1 >>2'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_ConversationPost',
      ),
      findsNWidgets(3),
    );
  });

  testWidgets('スレタイシートからお気に入りを切り替える', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('お気に入りに追加'));
    await tester.pumpAndSettle();

    expect(history.isFavorite('1762103691'), isTrue);

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    expect(find.text('お気に入りを解除'), findsOneWidget);
  });

  testWidgets('1001 行があれば完走表示を出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...over1000]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('3レス ・ 完走'), findsOneWidget);
  });

  testWidgets('自分のレスには自分ラベルを出す', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markOwnPost('1762103691', 2);
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);

    await tester.pumpWidget(appWithHistory(f, history));
    await tester.pumpAndSettle();

    expect(find.text('自分'), findsOneWidget);
  });
}
