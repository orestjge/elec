import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_map.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class PendingFetcher implements HttpFetcher {
  final completer = Completer<FetchResponse>();

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) => completer.future;
}

FetchResponse ok(List<int> body) =>
    FetchResponse(statusCode: 200, bodyBytes: body, headers: const {});
FetchResponse partial(List<int> body) =>
    FetchResponse(statusCode: 206, bodyBytes: body, headers: const {});
FetchResponse redirect(String location) => FetchResponse(
  statusCode: 302,
  bodyBytes: const [],
  headers: {'location': location},
);

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

  /// レス番号（返信数を添えたヘッダの左端）。返信があるものはタップで会話ビュー。
  Finder resNumbers() =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResNumber');
  Finder resNumber(int nth) => resNumbers().at(nth);

  TextSpan textSpanContaining(WidgetTester tester, String text) {
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      if (rich.text.toPlainText().contains(text)) return rich.text as TextSpan;
    }
    throw StateError('TextSpan containing "$text" was not found');
  }

  Iterable<TextSpan> textSpans(TextSpan span) sync* {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) yield* textSpans(child);
    }
  }

  TextSpan selectableTextSpanContaining(WidgetTester tester, String text) {
    for (final selectable in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      final span = selectable.textSpan;
      if (span != null && span.toPlainText().contains(text)) return span;
    }
    throw StateError('SelectableText span containing "$text" was not found');
  }

  testWidgets('本文取得前でも開いたスレを履歴と既読にする', (tester) async {
    final f = PendingFetcher();
    final history = ReadHistory(MemoryReadHistoryStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 60),
          readHistory: history,
          initialResCount: 12,
        ),
      ),
    );
    await tester.pump();

    expect(history.isRead('1762103691'), isTrue);
    expect(history.lastSeen('1762103691'), 0);
    expect(history.lastViewedThread?.toSummary().title, 'テストスレ');
    expect(history.lastViewedThread?.toSummary().resCount, 12);
  });

  testWidgets('初回に本文を番号順で表示する', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('最初のレス'), findsOneWidget);
    expect(find.textContaining('同じIDの2つ目', findRichText: true), findsOneWidget);
    // 同一 ID は「このレスが何番目か / 合計レス数」付きで出る。
    expect(find.text('ID:aaa (1/2)'), findsOneWidget);
    expect(find.text('ID:aaa (2/2)'), findsOneWidget);
    // 初回は新着ライン無し。
    expect(find.text('ここから新着'), findsNothing);
  });

  testWidgets('返信ボタンでコンポーザに >>N が入る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 1 レス目の返信ボタン（ヘッダ右端）をタップ。ヘッダ左の返信数マークと
    // アイコンが同じなので tooltip で選ぶ。
    await tester.tap(find.byTooltip('このレスに返信').first);
    await tester.pump();

    expect(find.text('>>1\n'), findsOneWidget); // 入力欄に反映
  });

  testWidgets('レス入力中はキーボードを閉じるボタンで下書きを残してフォーカスを外せる', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    final composer = find.widgetWithText(TextField, 'レスを書く');
    await tester.tap(composer);
    await tester.pump();
    await tester.enterText(composer, '書きかけ');
    await tester.pump();

    expect(find.byTooltip('キーボードを閉じる'), findsOneWidget);
    var field = tester.widget<TextField>(composer);
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.tap(find.byTooltip('キーボードを閉じる'));
    await tester.pump();

    field = tester.widget<TextField>(composer);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.text, '書きかけ');
  });

  // デスクトップの既定の密度（compact）は InputDecoration の上下パディングを
  // 8 削るので、入力欄だけが縮んで固定サイズの添付・送信ボタンとずれていた。
  // 入力の有無・フォーカスの有無でも高さが変わらないことまで見る。
  testWidgets('レス入力欄の高さは添付・送信ボタンと揃う（デスクトップの密度でも）', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        // デスクトップで既定になる密度。
        theme: ThemeData(visualDensity: VisualDensity.compact),
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final composer = find.widgetWithText(TextField, 'レスを書く');
    void expectAligned(String state) {
      final field = tester.getRect(composer);
      for (final icon in [
        Icons.image_outlined,
        Icons.attach_file,
        Icons.send,
      ]) {
        final button = tester.getRect(
          find.ancestor(
            of: find.byIcon(icon),
            matching: find.byType(IconButton),
          ),
        );
        expect(button.top, field.top, reason: '$state: ${icon.codePoint} の上端');
        expect(button.bottom, field.bottom, reason: '$state: 下端');
      }
    }

    expectAligned('未入力');
    await tester.tap(composer);
    await tester.pump();
    expectAligned('フォーカス中');
    await tester.enterText(composer, 'あ');
    await tester.pump();
    expectAligned('1行入力');
  });

  testWidgets('スレ内検索で一致件数を表示する', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.byTooltip('スレ内検索'), findsNothing);

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'スレ内検索'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'スレ内検索'),
    );
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), 'あとから');
    await tester.pumpAndSettle();

    expect(find.text('1/1'), findsOneWidget);
    expect(find.byTooltip('前の一致'), findsOneWidget);
    expect(find.byTooltip('次の一致'), findsOneWidget);
  });

  testWidgets('スレ内検索は本文の一致箇所を背景色でハイライトする', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), 'あとから');
    await tester.pumpAndSettle();

    // 本文（RichText）の一致語だけに背景色が載っている。
    var highlighted = 0;
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      for (final s in textSpans(rich.text as TextSpan)) {
        if (s.text == 'あとから' && s.style?.backgroundColor != null) {
          highlighted++;
        }
      }
    }
    expect(highlighted, greaterThan(0));
  });

  testWidgets('スレ内検索は該当なしを表示して閉じられる', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), '存在しない語');
    await tester.pumpAndSettle();

    expect(find.text('0件'), findsOneWidget);

    await tester.tap(find.byTooltip('検索を閉じる'));
    await tester.pumpAndSettle();
    expect(find.text('テストスレ'), findsOneWidget);
  });

  testWidgets('スレ内検索中にポーリング更新が来ても検索欄のフォーカスを維持する', (tester) async {
    final full = [...res1, ...res2];
    final f = QueueFetcher([
      ok(full),
      partial([full.last, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), '最初');
    await tester.pumpAndSettle();

    var field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'スレ内検索'),
    );
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    field = tester.widget<TextField>(find.widgetWithText(TextField, 'スレ内検索'));
    expect(f.calls, 2);
    expect(field.focusNode!.hasFocus, isTrue);
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
    await tester.tap(find.text('ID:aaa (1/2)').first);
    await tester.pumpAndSettle();

    // シート見出し。
    expect(find.text('ID:aaa  2レス'), findsOneWidget);

    // シート内の先頭（レス 1・返信 2 件）の番号をタップして会話ビューへ。
    await tester.tap(
      find
          .descendant(of: find.byType(BottomSheet), matching: resNumbers())
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  3件'), findsOneWidget);
    expect(find.text('ID:aaa  2レス'), findsNothing);
  });

  testWidgets('NGワードに該当するレスは非表示になりタップで表示する', (tester) async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWord(const NgWord('あとから来た'));

    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: ng,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 該当レスは本文が隠れ、プレースホルダが出る。
    expect(find.textContaining('あとから来た', findRichText: true), findsNothing);
    expect(find.text('NG（タップで表示）'), findsOneWidget);

    // タップすると本文が出る。
    await tester.tap(find.text('NG（タップで表示）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('あとから来た', findRichText: true), findsOneWidget);
  });

  testWidgets('ID シートからそのIDをNGにできる', (tester) async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();

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
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: ng,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('ID:aaa (1/2)').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('IDをNG'));
    await tester.pumpAndSettle();

    // NG に登録され、シート内のレスがプレースホルダに変わる。
    expect(ng.isNgId('aaa'), isTrue);
    expect(find.text('NG（タップで表示）'), findsWidgets);
    // 「NG解除」に切り替わる。
    expect(find.text('NG解除'), findsOneWidget);
  });

  testWidgets('ID シートに必死チェッカーと ID コピーの導線が出る', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ID:aaa (1/2)').first);
    await tester.pumpAndSettle();

    expect(find.text('必死チェッカー'), findsOneWidget);
    expect(find.text('IDをコピー'), findsOneWidget);

    await tester.tap(find.text('IDをコピー'));
    await tester.pumpAndSettle();
    expect(copied, ['aaa']);
  });

  testWidgets('レス長押しで全体コピーのアクションが出る', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 1 レス目のヘッダ（番号）を長押ししてアクションシートを出す。
    await tester.longPress(find.text('1').first);
    await tester.pumpAndSettle();

    expect(find.text('レス全体をコピー'), findsOneWidget);

    await tester.tap(find.text('レス全体をコピー'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('ID:aaa'));
    expect(copied.single, contains('最初のレス'));
  });

  testWidgets('ユーザー名をタップすると全文を表示する', (tester) async {
    final longName = 'とても長いユーザー名' * 6;
    final f = QueueFetcher([
      ok([
        ...datLine(
          '$longName<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 本文 <>スレタイ',
        ),
      ]),
    ]);

    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text(longName));
    await tester.pumpAndSettle();

    expect(find.byTooltip(longName), findsOneWidget);
  });

  testWidgets('画像URLタップは同じレス内の画像ビューアを開く', (tester) async {
    final f = QueueFetcher([
      ok([
        ...datLine(
          '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<>'
          'https://example.com/a.jpg https://example.com/b.png<>テストスレ',
        ),
      ]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    final body = textSpanContaining(tester, 'https://example.com/b.png');
    final span = textSpans(
      body,
    ).firstWhere((span) => span.text == 'https://example.com/b.png');
    (span.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('2/2  b.png'), findsOneWidget);
  });

  testWidgets('通常一覧の本文タップでレスメニューを出し、メニュー内本文は選択可能', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsNothing);

    await tester.tap(find.textContaining('最初のレス', findRichText: true));
    await tester.pumpAndSettle();

    expect(find.text('レス全体をコピー'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('レスメニュー内のレス参照タップで参照先を開く', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.longPress(resNumber(1));
    await tester.pumpAndSettle();
    expect(find.text('レス全体をコピー'), findsOneWidget);

    final body = selectableTextSpanContaining(tester, '>>1');
    final span = textSpans(body).firstWhere((span) => span.text == '>>1');
    (span.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  2件'), findsOneWidget);
  });

  testWidgets('レス番号横の返信数から会話ビューを出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(resNumber(0));
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

  testWidgets('会話シートは返信アイコンを押したときだけ入力欄を出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 会話シートを開く。
    await tester.tap(resNumber(0));
    await tester.pumpAndSettle();
    expect(find.text('会話 #1  3件'), findsOneWidget);

    // 開いただけでは入力欄は出ない（本体の 1 つだけ＝会話全体への返信と誤解しない）。
    expect(find.widgetWithText(TextField, 'レスを書く'), findsOneWidget);

    // シート内の返信ボタンを押すと入力欄が出る（本体＋シートで 2 つ）。
    await tester.tap(find.byTooltip('このレスに返信').last);
    await tester.pumpAndSettle();
    final composers = find.widgetWithText(TextField, 'レスを書く');
    expect(composers, findsNWidgets(2));
    // シート側の入力欄には対象の >>N が入っている。
    final tf = tester.widget<TextField>(composers.last);
    expect(tf.controller!.text.startsWith('>>'), isTrue);

    // 閉じるボタンで入力欄を隠せる。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'レスを書く'), findsOneWidget);
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

  testWidgets('スレタイシートからスレ主をNGできる', (tester) async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
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
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: ng,
          creatorMetadent: 'B3YfDSAP',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('このスレ主をNG'));
    await tester.pumpAndSettle();

    expect(ng.isNgCreator('B3YfDSAP'), isTrue);

    // 再度開くと解除メニューになる。
    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    expect(find.text('このスレ主のNGを解除'), findsOneWidget);
  });

  testWidgets('metadent 不明ならスレ主NGメニューは出ない', (tester) async {
    final f = QueueFetcher([ok(res1)]);
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: NgStore(MemoryNgStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    expect(find.text('このスレ主をNG'), findsNothing);
  });

  List<int> manyRes(int n) {
    final bytes = <int>[];
    for (var i = 1; i <= n; i++) {
      bytes.addAll(
        datLine(
          '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> レス$i <>'
          '${i == 1 ? 'スレタイ' : ''}',
        ),
      );
    }
    return bytes;
  }

  testWidgets('長いスレでは右端にファストスクロールのつまみを出す', (tester) async {
    await tester.pumpWidget(app(QueueFetcher([ok(manyRes(40))])));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.unfold_more), findsOneWidget);
  });

  testWidgets('短いスレではファストスクロールのつまみを出さない', (tester) async {
    await tester.pumpWidget(app(QueueFetcher([ok(manyRes(5))])));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.unfold_more), findsNothing);
  });

  testWidgets('つまみを下へドラッグすると大きく移動する', (tester) async {
    await tester.pumpWidget(app(QueueFetcher([ok(manyRes(60))])));
    await tester.pumpAndSettle();
    // 最初は先頭のレスが見えている。
    expect(find.text('レス1'), findsOneWidget);

    await tester.drag(find.byIcon(Icons.unfold_more), const Offset(0, 3000));
    await tester.pumpAndSettle();

    // 先頭は画面外へ、後方のレスが見えるようになる。
    expect(find.text('レス1'), findsNothing);
  });

  testWidgets('スレタイは AppBar 内で複数行表示する', (tester) async {
    const title = 'これはかなり長いスレッドタイトルで省略せずに複数行で読みたいテスト用のタイトルです';
    final f = QueueFetcher([ok(res1)]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: title,
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, 2);
    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 80);
  });

  testWidgets('1001 行があれば完走表示を出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...over1000]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('3レス ・ 完走'), findsOneWidget);
  });

  testWidgets('dat落ちは過去ログを辿って表示し、dat落ち表示・書き込み無効にする', (tester) async {
    // 現行 dat が 302 で過去ログ(kako)へ飛び、そこから全文が返る。
    final f = QueueFetcher([
      redirect('/liveedge/kako/1762/17621/1762103691.dat'),
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 過去ログの本文が出る。
    expect(find.text('最初のレス'), findsOneWidget);
    // dat落ちラベル。
    expect(find.text('2レス ・ dat落ち'), findsOneWidget);
    // 書き込み欄は無効（停止扱い）。ヒントも停止中に変わる。
    expect(find.widgetWithText(TextField, 'レスを書く'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
  });

  testWidgets('dat も過去ログも無ければ「見つかりません」を出す', (tester) async {
    final f = QueueFetcher([
      const FetchResponse(statusCode: 404, bodyBytes: []),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('スレッドが見つかりません'), findsOneWidget);
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

  // --- スレマップ（ファストスクロールのトラックに出す目印） ---

  /// [bodies] で本文を差し替えつつ [n] レスの dat を組む。
  List<int> manyResWithBodies(int n, Map<int, String> bodies) {
    final bytes = <int>[];
    for (var i = 1; i <= n; i++) {
      bytes.addAll(
        datLine(
          '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> '
          '${bodies[i] ?? 'レス$i'} <>${i == 1 ? 'スレタイ' : ''}',
        ),
      );
    }
    return bytes;
  }

  List<ThreadMapMarker> mapMarkers(WidgetTester tester) {
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ThreadMapPainter>()
        .toList();
    expect(painters, hasLength(1));
    return painters.single.markers;
  }

  testWidgets('あぼーんのレスにはスレマップの目印を出さない', (tester) async {
    // NG に該当するレス 5 は返信を 5 件集めているが、飛んでも読めないので
    // 目印は出さない。
    final f = QueueFetcher([
      ok(
        manyResWithBodies(40, {
          5: 'NGだよ',
          20: '>>5 a',
          21: '>>5 b',
          22: '>>5 c',
          23: '>>5 d',
          24: '>>5 e',
        }),
      ),
    ]);
    final ng = NgStore(MemoryNgStorage());
    await ng.addWord(const NgWord('NGだよ'));

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'テストスレ',
          fetcher: f,
          pollInterval: const Duration(seconds: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: ng,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(mapMarkers(tester), isEmpty);
  });

  testWidgets('新着ラインと自分のレスをスレマップに出す', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead('1762103691', 10);
    await history.markOwnPost('1762103691', 3);
    final f = QueueFetcher([ok(manyResWithBodies(40, const {}))]);

    await tester.pumpWidget(appWithHistory(f, history));
    await tester.pumpAndSettle();

    // 新着ラインは行インデックス 10（=既読 10 レスの直後）に挟まる。自分のレス
    // 3 はその手前なので index 2 のまま。
    expect(mapMarkers(tester), const [
      ThreadMapMarker(2, ThreadMapMarkerKind.own),
      ThreadMapMarker(10, ThreadMapMarkerKind.newArrival),
    ]);
  });

  testWidgets('返信数に応じてレス番号の色と太さを変える', (tester) async {
    // レス 1 は返信なし、レス 2 は 5 件、レス 3 は 10 件。
    final bodies = <int, String>{};
    for (var i = 0; i < 5; i++) {
      bodies[10 + i] = '>>2 $i';
    }
    for (var i = 0; i < 10; i++) {
      bodies[30 + i] = '>>3 $i';
    }
    final f = QueueFetcher([ok(manyResWithBodies(60, bodies))]);

    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    TextStyle styleOfNumber(int number) => tester
        .widget<Text>(
          find
              .descendant(of: resNumbers(), matching: find.text('$number'))
              .first,
        )
        .style!;

    final scheme = Theme.of(
      tester.element(find.byType(ThreadScreen)),
    ).colorScheme;
    // 返信なしは従来どおり primary。
    expect(styleOfNumber(1).color, scheme.primary);
    expect(styleOfNumber(1).fontWeight, FontWeight.w700);
    // 5 件以上は色が上がる。10 件以上はさらに太くなる（色は同じ＝テキストなので
    // 淡くせず、段階は太さで示す）。
    expect(styleOfNumber(2).color, scheme.error);
    expect(styleOfNumber(2).fontWeight, FontWeight.w700);
    expect(styleOfNumber(3).color, scheme.error);
    expect(styleOfNumber(3).fontWeight, FontWeight.w800);
  });

  testWidgets('返信数に応じて2段階でスレマップに出す', (tester) async {
    // レス 2 は 4 件（閾値未満）、レス 3 は 5 件、レス 4 は 10 件。
    final bodies = <int, String>{};
    for (var i = 0; i < 4; i++) {
      bodies[10 + i] = '>>2 $i';
    }
    for (var i = 0; i < 5; i++) {
      bodies[20 + i] = '>>3 $i';
    }
    for (var i = 0; i < 10; i++) {
      bodies[30 + i] = '>>4 $i';
    }
    final f = QueueFetcher([ok(manyResWithBodies(60, bodies))]);

    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(mapMarkers(tester), const [
      ThreadMapMarker(2, ThreadMapMarkerKind.manyReplies),
      ThreadMapMarker(3, ThreadMapMarkerKind.veryManyReplies),
    ]);
  });

  testWidgets('目印をタップするとその行へ飛ぶ', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markOwnPost('1762103691', 50);
    final f = QueueFetcher([ok(manyResWithBodies(100, const {}))]);

    await tester.pumpWidget(appWithHistory(f, history));
    await tester.pumpAndSettle();
    expect(find.textContaining('レス50', findRichText: true), findsNothing);

    // レス 50（index 49）の目印の位置をトラックの矩形から割り出して押す。
    final track = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ThreadMapPainter,
      ),
    );
    final travel = track.height - 52; // つまみの高さ
    await tester.tapAt(
      Offset(track.right - 11, track.top + 26 + 49 / 99 * travel),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('レス50', findRichText: true), findsOneWidget);
  });

  testWidgets('ドラッグ中は近くの目印に吸い付き、何の目印かを吹き出しに出す', (tester) async {
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markOwnPost('1762103691', 50);
    final f = QueueFetcher([ok(manyResWithBodies(100, const {}))]);

    await tester.pumpWidget(appWithHistory(f, history));
    await tester.pumpAndSettle();

    // トラックの高さからつまみの移動量を出し、レス 50（index 49）の少し手前まで
    // ドラッグする。吸着範囲に入るので、ぴったりでなくてもレス 50 に着く。
    final track = tester.getSize(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ThreadMapPainter,
      ),
    );
    final travel = track.height - 52; // つまみの高さ
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.unfold_more)),
    );
    await gesture.moveBy(Offset(0, 48 / 99 * travel));
    await tester.pump();

    expect(find.text('自分 · 50'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('レス50', findRichText: true), findsOneWidget);
  });

  testWidgets('スレ内検索の一致レスをスレマップに出す', (tester) async {
    final f = QueueFetcher([
      ok(manyResWithBodies(40, {7: 'さがしもの'})),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), 'さがしもの');
    await tester.pumpAndSettle();

    expect(mapMarkers(tester), const [
      ThreadMapMarker(6, ThreadMapMarkerKind.searchMatch),
    ]);
  });
}
