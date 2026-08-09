import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_link.dart';
import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/src/ui/mini_player.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/thread_map.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/src/ui/thread_tree.dart';
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

/// URL ごとに決められた応答を返すフェイク（貼られたスレの dat 用）。
class MapFetcher implements HttpFetcher {
  MapFetcher(this._byUrl);
  final Map<String, FetchResponse> _byUrl;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async =>
      _byUrl[url.toString()] ??
      const FetchResponse(statusCode: 404, bodyBytes: []);
}

/// 2 回目以降の取得を [gate] で止められる（＝通信中の見た目を作れる）フェイク。
class GatedFetcher implements HttpFetcher {
  GatedFetcher(this._body);
  final List<int> _body;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    calls++;
    if (calls > 1) {
      await (gate = Completer<void>()).future;
    }
    return ok(_body);
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
  // 全画面ビューアは 1 つしかない（[MiniPlayerController.shared]）ので、
  // 開きっぱなしを次のテストへ持ち越さない。
  tearDown(MiniPlayerController.shared.debugReset);

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

  Widget app(HttpFetcher f, {String? defaultName}) => MaterialApp(
    // 全画面ビューアは Navigator の外（この層）に載る（`mini_player.dart`）。
    builder: (context, child) =>
        MiniPlayerHost(child: child ?? const SizedBox.shrink()),
    home: ThreadScreen(
      threadKey: '1762103691',
      threadTitle: 'テストスレ',
      fetcher: f,
      pollInterval: const Duration(seconds: 5),
      readHistory: ReadHistory(MemoryReadHistoryStorage()),
      defaultName: defaultName,
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

  /// ヘッダの ID アイコン（identicon）。タップで同一 ID のレス一覧が出る。
  ///
  /// レス本体に絞る。返信先の引用行にも同じ絵が出るが、あちらは押せない再掲
  /// なので数にも並びにも入れない。
  Finder idIcons(String id) => find.descendant(
    of: find.byType(PostItem),
    matching: find.byWidgetPredicate((w) => w is IdIcon && w.id == id),
  );

  /// レス本体の中の文字。引用行にも同じ本文の頭が出るので、本体だけを見る。
  Finder inPost(Finder matching) =>
      find.descendant(of: find.byType(PostItem), matching: matching);

  /// ヘッダ左端の返信数（吹き出し＋件数）。**返信が付いたレスにしか出ない。**
  /// タップで会話ビュー。
  Finder replyCounts() =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ReplyCount');
  Finder replyCount(int nth) => replyCounts().at(nth);

  /// 番号 [n] のレス。シートを開いている間は本体とシートの両方に出るので、
  /// 必要なら `.last` でシート側を選ぶ。
  Finder posts(int n) =>
      find.byWidgetPredicate((w) => w is PostItem && w.res.number == n);

  /// レスを左へ引いて返信する。返信の入り口はこのスワイプだけで、ヘッダに常時
  /// ボタンは置いていない。しきい値（56px）を確実に越える距離を引く。
  Future<void> swipeToReply(WidgetTester tester, Finder post) async {
    await tester.drag(post, const Offset(-120, 0));
    await tester.pumpAndSettle();
  }

  /// 入力欄の上に出る返信先の帯。
  Finder replyTargetBar() => find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_ReplyTargetBar',
  );
  Finder inReplyTargetBar(String text) =>
      find.descendant(of: replyTargetBar(), matching: find.text(text));

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

    expect(inPost(find.text('最初のレス')), findsOneWidget);
    expect(
      inPost(find.textContaining('同じIDの2つ目', findRichText: true)),
      findsOneWidget,
    );
    // 同一 ID は同じ identicon で出て、横に「このレスが何番目か / 合計レス数」
    // が付く。ID 文字列そのものはアイコンをタップした先のシートで読む。
    expect(idIcons('aaa'), findsNWidgets(2));
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    // 初回は新着ライン無し。
    expect(find.text('ここから新着'), findsNothing);
  });

  testWidgets('>>1 と同じ ID のレスにスレ主の印が付く', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // >>1（ID:aaa）とその ID の 2 つ目にだけ付き、別 ID の >>3 には付かない。
    expect(find.text('スレ主'), findsNWidgets(2));
  });

  testWidgets('左スワイプでコンポーザに >>N が入る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await swipeToReply(tester, posts(1));

    expect(find.text('>>1\n'), findsOneWidget); // 入力欄に反映
    // 誰への返信を書いているかが入力欄の上に出る（番号＋本文の頭）。番号は
    // その行が指すレスの番号なので、`>>` は付けずに裸で出す。
    expect(inReplyTargetBar('1'), findsOneWidget);
    expect(inReplyTargetBar('最初のレス'), findsOneWidget);
  });

  testWidgets('入力中の >>N から返信先を出し、押すと会話が開く', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    final composer = find.widgetWithText(TextField, 'レスを書く');
    await tester.enterText(composer, '>>2 そうだね');
    await tester.pump();

    expect(inReplyTargetBar('2'), findsOneWidget);
    await tester.tap(inReplyTargetBar('2'));
    await tester.pumpAndSettle();

    expect(find.textContaining('会話 #2'), findsOneWidget);
  });

  testWidgets('返信先が数件なら1件1行で本文の頭まで出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'レスを書く'),
      '>>1 >>2 まとめて',
    );
    await tester.pump();

    expect(inReplyTargetBar('1'), findsOneWidget);
    expect(inReplyTargetBar('2'), findsOneWidget);
    // それぞれの行に本文の頭が付く。
    expect(inReplyTargetBar('最初のレス'), findsOneWidget);
    expect(inReplyTargetBar('>>1 同じIDの2つ目'), findsOneWidget);
  });

  testWidgets('返信先が多いときは頭の3件だけ出して残りは件数で示す', (tester) async {
    final many = <int>[];
    for (var i = 1; i <= 5; i++) {
      many.addAll(
        datLine('名無し<><>2025/11/03(月) 02:14:5$i.907 ID:aaa<> レス$i <>'),
      );
    }
    await tester.pumpWidget(app(QueueFetcher([ok(many)])));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'レスを書く'),
      '>>1 >>2 >>3 >>4 まとめて',
    );
    await tester.pump();

    // 頭の 3 件は本文付きの行のまま。4 件目は出さず、件数だけ添える。
    expect(inReplyTargetBar('1'), findsOneWidget);
    expect(inReplyTargetBar('レス1'), findsOneWidget);
    expect(inReplyTargetBar('3'), findsOneWidget);
    expect(inReplyTargetBar('4'), findsNothing);
    expect(inReplyTargetBar('レス4'), findsNothing);
    expect(inReplyTargetBar('他1件に返信'), findsOneWidget);
  });

  testWidgets('まだ無い番号への >>N では返信先を出さない', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'レスを書く'),
      '>>99 打ち間違い',
    );
    await tester.pump();

    // 帯そのものが出ない。
    expect(replyTargetBar(), findsNothing);
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

  testWidgets('取得中の表示で本文を上下に動かさない', (tester) async {
    final f = GatedFetcher([...res1, ...res2]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();
    final before = tester.getRect(posts(1));

    await tester.pump(const Duration(seconds: 5)); // ポーリング開始
    await tester.pump();

    // 取得中の細い線は AppBar に重ねて出す。本文の位置は変わらない。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.getRect(posts(1)), before);

    f.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getRect(posts(1)), before);
  });

  testWidgets('ID タップで同一 ID のレス一覧シートが出る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // aaa は 2 レス。チップをタップ。
    await tester.tap(idIcons('aaa').first);
    await tester.pumpAndSettle();

    // シート見出し。
    expect(find.text('ID:aaa  2レス'), findsOneWidget);

    // シート内の先頭（レス 1・返信 2 件）の返信数をタップして会話ビューへ。
    await tester.tap(
      find
          .descendant(of: find.byType(BottomSheet), matching: replyCounts())
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

    await tester.tap(idIcons('aaa').first);
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

    await tester.tap(idIcons('aaa').first);
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

  testWidgets('レス長押しに ID の操作は並べない（ID タップ側にある）', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('1').first);
    await tester.pumpAndSettle();

    expect(find.text('レス全体をコピー'), findsOneWidget);
    expect(find.text('ID:aaa をコピー'), findsNothing);
    expect(find.text('ID:aaa をNGにする'), findsNothing);
    expect(find.text('必死チェッカーで開く'), findsNothing);
  });

  testWidgets('レス長押しから、差し替えを挟まないクラシック表示を見られる', (tester) async {
    // 画像 URL はサムネイルになって本文から消え、名前欄のワッチョイ
    // （元データは `</b>…<b>` を含む）はヘッダで括弧の中だけになる。どちらも
    // クラシック表示で確かめられることを見る。
    final withImage = datLine(
      'エッヂの名無し</b> (L20 5clL-4hXU)<b><>sage<>'
      '2025/11/03(月) 02:14:51.907 ID:aaa<>'
      'これ見て<br>https://example.com/a.jpg<>スレタイ',
    );
    final f = QueueFetcher([ok(withImage)]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 通常表示では URL の文字列は出ていない。
    expect(
      find.textContaining('https://example.com/a.jpg', findRichText: true),
      findsNothing,
    );

    await tester.longPress(find.textContaining('これ見て', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('クラシック表示で見る'));
    await tester.pumpAndSettle();

    // ヘッダと本文はひと続きの 1 つのテキスト。境目で選択が切れると、ヘッダごと
    // なぞって持っていけないため。
    final shown = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(
      shown.textSpan!.toPlainText(),
      // ヘッダは read.cgi が昔から出している 1 行。通常表示では省く名前欄も、
      // 絵にしている ID も、日付と地続きの文字で並ぶ。
      '1 名前:エッヂの名無し (L20 5clL-4hXU) Mail:sage '
      '投稿日:2025/11/03(月) 02:14:51.907 ID:aaa\n'
      '\n'
      // 本文は URL の差し替えを挟まない。HTML は掲示板と同じく効かせるので、
      // <br> は改行になり、タグ自体は文字として残らない。
      'これ見て\n'
      'https://example.com/a.jpg',
    );
  });

  testWidgets('レス長押しのアクションから返信すると入力欄に >>N が入る', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // ヘッダにレス番号は出さないので、レス 2 の ID アイコンを長押しする。
    await tester.longPress(idIcons('aaa').at(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('>>2 に返信'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '>>2\n');
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

  testWidgets('サムネイルタップは同じレス内の画像ビューアを開く', (tester) async {
    final f = QueueFetcher([
      ok([
        ...datLine(
          '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<>'
          '前置き<br>https://example.com/a.jpg<br>あいだ<br>'
          'https://example.com/b.png<>テストスレ',
        ),
      ]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 本文の途中で区画が分かれても、どのサムネイルからでもレス内の全画像を送れる。
    final thumbs = find.descendant(
      of: find.byType(PostImages),
      matching: find.byType(GestureDetector),
    );
    expect(thumbs, findsNWidgets(2));
    await tester.tap(thumbs.last);
    await tester.pumpAndSettle();

    // 題名バーは既定では出さない（絵をタップすると一式出る）。
    await tester.tap(find.byType(PageView));
    await tester.pumpAndSettle();
    expect(find.text('2/2  b.png'), findsOneWidget);
  });

  testWidgets('通常一覧の本文タップではメニューを出さず、長押しで出す（メニュー内本文は選択可能）', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsNothing);

    final body = find.textContaining('最初のレス', findRichText: true);
    await tester.tap(body);
    await tester.pumpAndSettle();

    expect(find.text('レス全体をコピー'), findsNothing);

    await tester.longPress(body);
    await tester.pumpAndSettle();

    expect(find.text('レス全体をコピー'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('レスを押している間だけ指の位置から沈み込みが広がり、長押し成立で手応えを返す', (tester) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String? ?? '');
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
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 沈み込みは本文の後ろに広がる円として描く。
    final body = find.textContaining('最初のレス', findRichText: true);
    final spread = find
        .ancestor(of: body, matching: find.byType(CustomPaint))
        .first;

    expect(spread, paintsExactlyCountTimes(#drawCircle, 0));

    final press = await tester.startGesture(tester.getCenter(body));
    // 触れた直後は広げない（スクロール開始のチカチカ防止）。
    await tester.pump(const Duration(milliseconds: 100));
    expect(spread, paintsExactlyCountTimes(#drawCircle, 0));

    // 指を止めていれば広がり出す。ここではまだ長押しは成立していない。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    expect(spread, paintsExactlyCountTimes(#drawCircle, 1));
    expect(find.text('レス全体をコピー'), findsNothing);
    expect(haptics, isEmpty);

    // 押し続ければ長押しが通り、手応えを返してメニューを出す。
    await tester.pump(const Duration(milliseconds: 400));
    expect(haptics, isNotEmpty);
    expect(find.text('レス全体をコピー'), findsOneWidget);

    // 離すと沈み込みは消える。
    await press.up();
    await tester.pumpAndSettle();
    expect(spread, paintsExactlyCountTimes(#drawCircle, 0));
  });

  // スクロールを始めた指の下で沈み込みが広がると、押していないのに反応したように
  // 見える。長押しが外れる 18px を待たず、指が動いた時点で引っ込める。
  testWidgets('スワイプ中は沈み込みを広げない', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    final body = find.textContaining('最初のレス', findRichText: true);
    final spread = find
        .ancestor(of: body, matching: find.byType(CustomPaint))
        .first;

    // 広がり出す前に引き始めれば、そもそも出ない。
    final swipe = await tester.startGesture(tester.getCenter(body));
    await tester.pump(const Duration(milliseconds: 20));
    await swipe.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 300));
    expect(spread, paintsExactlyCountTimes(#drawCircle, 0));
    await swipe.up();
    await tester.pumpAndSettle();

    // 一度広がってから引き始めても、動かした時点で（余韻を残さず）消える。
    final hold = await tester.startGesture(tester.getCenter(body));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 60));
    expect(spread, paintsExactlyCountTimes(#drawCircle, 1));

    await hold.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(spread, paintsExactlyCountTimes(#drawCircle, 0));
    // 指が離れる前にスクロールへ移ったので、メニューも出ない。
    expect(find.text('レス全体をコピー'), findsNothing);
    await hold.up();
    await tester.pumpAndSettle();
  });

  testWidgets('レスメニュー内のレス参照タップで参照先を開く', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // レス 2 は返信を集めていないのでヘッダに返信数が無い。ID アイコンを
    // 長押しする（タップは同一 ID 一覧だが、長押しはレス全体が受ける）。
    await tester.longPress(idIcons('aaa').at(1));
    await tester.pumpAndSettle();
    expect(find.text('レス全体をコピー'), findsOneWidget);

    final body = selectableTextSpanContaining(tester, '>>1');
    final span = textSpans(body).firstWhere((span) => span.text == '>>1');
    (span.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  2件'), findsOneWidget);
  });

  /// `>>n-1` へ返信し続ける [n] 件の数珠つなぎ。1 は返信していない。
  List<int> chainDat(int n) => [
    for (var i = 1; i <= n; i++)
      ...datLine(
        '名無し<><>2025/11/03(月) 02:${i.toString().padLeft(2, '0')}:00.000 '
        'ID:aaa<> ${i == 1 ? '最初のレス' : '>>${i - 1} レス$i'} '
        '<>${i == 1 ? 'スレタイ' : ''}',
      ),
  ];

  /// 返信先の引用行。押すと会話ビューが開く。
  Finder quoteRowFor(int number) => find.byWidgetPredicate(
    (w) => w is QuotedResRow && w.res.number == number,
  );

  testWidgets('会話ビューは返信先をたどって会話の始まりまで載せる', (tester) async {
    final f = QueueFetcher([ok(chainDat(4))]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // レス 4 の手前に出ている引用行（返信先＝3）から会話を開く。
    await tester.tap(quoteRowFor(3));
    await tester.pumpAndSettle();

    // 3 から返信先をたどって 2・1 まで載る。直接の返信先だけ（2・3・4）だと
    // 会話の途中から読むことになり、その前を見るのに開き直すはめになる。
    expect(find.text('会話 #3  4件'), findsOneWidget);
    expect(find.text('最初のレス'), findsWidgets);
  });

  testWidgets('遡るのは決めた世代まで（会話ビューが手前のレスで埋まらない）', (tester) async {
    // 数珠つなぎの末尾まで一度に映るよう、縦に長い画面で見る。
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final f = QueueFetcher([ok(chainDat(10))]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(quoteRowFor(9));
    await tester.pumpAndSettle();

    // 中心は 9。手前は 6 世代ぶん（8〜3）で打ち切り、あとは 9 への返信 10。
    // 2・1 まで載せると、読みに来た 9 が下へ押し流される。
    expect(find.text('会話 #9  8件'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_ConversationPost',
      ),
      findsNWidgets(8),
    );
  });

  testWidgets('ヘッダ左端の返信数から会話ビューを出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.tap(replyCount(0));
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

  testWidgets('返信数は押せる大きさで出し、返信のないレスには出さない', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // レス 1（2 件）とレス 2（1 件）にだけ出る。返信のないレス 3 には出さない
    // ので、ヘッダは ID アイコンから始まって一覧が詰まる。
    expect(replyCounts(), findsNWidgets(2));
    // 押せるものなので、文字の高さ（16px）ではなくヘッダ行が返信ボタンのために
    // 元から持っている高さまで使う。
    expect(tester.getSize(replyCount(0)).height, greaterThanOrEqualTo(26));
  });

  testWidgets('名無しはヘッダから名前を省き、コテハンだけ残す', (tester) async {
    final kote = datLine(
      'コテハン◆Ab12<><>2025/11/03(月) 04:00:00.000 ID:ccc<> 名乗ってるレス <>',
    );
    final f = QueueFetcher([
      ok([...res1, ...kote]),
    ]);
    await tester.pumpWidget(app(f, defaultName: '名無し'));
    await tester.pumpAndSettle();

    expect(find.text('名無し'), findsNothing);
    expect(find.text('コテハン◆Ab12'), findsOneWidget);
    // 本文は消えていない（消したのは名前だけ）。
    expect(find.text('最初のレス'), findsOneWidget);
  });

  testWidgets('名無しにワッチョイが付いていれば括弧の中だけ残す', (tester) async {
    // 実データと同じ形（dat の名前欄はタグ込みで来る）。
    final anon = datLine(
      'エッヂの名無し </b>(L20 NKP8-6NV7)<b><><>2025/11/03(月) 05:00:00.000 '
      'ID:ddd<> ワッチョイ付きの名無し <>スレタイ',
    );
    final kote = datLine(
      'コテハン◆Ab12 </b>(L20 ZZZZ-1111)<b><><>2025/11/03(月) 05:00:01.000 '
      'ID:eee<> ワッチョイ付きのコテハン <>',
    );
    final f = QueueFetcher([
      ok([...anon, ...kote]),
    ]);
    await tester.pumpWidget(app(f, defaultName: 'エッヂの名無し'));
    await tester.pumpAndSettle();

    // 毎行同じ既定名は消える。ワッチョイは書いた人の情報なので残す。
    expect(find.textContaining('エッヂの名無し'), findsNothing);
    expect(find.text('(L20 NKP8-6NV7)'), findsOneWidget);
    // コテハンは既定名と違うので、ワッチョイごとそのまま出す。
    expect(find.text('コテハン◆Ab12 (L20 ZZZZ-1111)'), findsOneWidget);
  });

  testWidgets('板の既定名が分からなければ名前を省かない', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    // defaultName なし＝名無しかどうか判断できないので、そのまま出す。
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('名無し'), findsOneWidget);
  });

  testWidgets('省いた名前でも検索に引っかかれば表示する', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f, defaultName: '名無し'));
    await tester.pumpAndSettle();

    expect(find.text('名無し'), findsNothing);

    await tester.tap(find.text('テストスレ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('スレ内検索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'スレ内検索'), '名無し');
    await tester.pumpAndSettle();

    // 一致件数に数えたレスの一致箇所が画面のどこにも無い、という状態を作らない。
    expect(find.textContaining('名無し', findRichText: true), findsWidgets);
  });

  testWidgets('時刻は時分だけ出し、タップで完全な日時を出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    expect(find.text('02:14'), findsOneWidget);
    expect(find.text('02:14:51'), findsNothing);

    await tester.tap(find.text('02:14'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2025/11/03(月) 02:14:51.907'), findsOneWidget);
  });

  testWidgets('レスのメニューからも返信一覧へ入れる', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 番号横の吹き出しを押し外すとこのメニューが開くので、ここからも同じ
    // 返信一覧へ行けるようにしてある。
    await tester.longPress(inPost(find.text('最初のレス')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返信 2 件を見る'));
    await tester.pumpAndSettle();

    expect(find.text('会話 #1  3件'), findsOneWidget);
  });

  testWidgets('しきい値まで引かなければ返信にならない', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 縦スクロールのついでに少し横へ動いた程度では成立しない。
    await tester.drag(posts(1), const Offset(-30, 0));
    await tester.pumpAndSettle();

    expect(find.text('>>1\n'), findsNothing);
    expect(replyTargetBar(), findsNothing);
  });

  testWidgets('返信の矢印は引いている間しか出ない', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    Finder arrow() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ReplySwipeArrow',
    );

    // 静止した一覧には何も置かない。これが常時ボタンを畳んだ狙い。
    expect(arrow(), findsNothing);

    // ドラッグが成立するまでの分は捨てられるので、2 回に分けて引く。
    final gesture = await tester.startGesture(tester.getCenter(posts(1)));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(arrow(), findsOneWidget);

    // しきい値（56px）には届いていないので、離しても返信にはならない。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(arrow(), findsNothing);
    expect(replyTargetBar(), findsNothing);
  });

  testWidgets('右スワイプは返信にならない（戻る操作を取らない）', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 右へのスワイプは外側の「一覧へ戻る」のもの。レス側は降りる。
    await tester.drag(posts(1), const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(find.text('>>1\n'), findsNothing);
    expect(replyTargetBar(), findsNothing);
  });

  testWidgets('会話シートは左スワイプで返信したときだけ入力欄を出す', (tester) async {
    final f = QueueFetcher([
      ok([...res1, ...res2, ...res3]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 会話シートを開く。
    await tester.tap(replyCount(0));
    await tester.pumpAndSettle();
    expect(find.text('会話 #1  3件'), findsOneWidget);

    // 開いただけでは入力欄は出ない（本体の 1 つだけ＝会話全体への返信と誤解しない）。
    expect(find.widgetWithText(TextField, 'レスを書く'), findsOneWidget);

    // シート内のレスを左へ引くと入力欄が出る（本体＋シートで 2 つ）。
    await swipeToReply(tester, posts(3).last);
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
    expect(inPost(find.text('最初のレス')), findsOneWidget);
    // dat落ちラベル。
    expect(find.text('2レス ・ dat落ち'), findsOneWidget);
    // 書き込み欄は読み取り専用（停止扱い）。ヒントも停止中に変わる。
    expect(find.widgetWithText(TextField, 'レスを書く'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
  });

  testWidgets('書いている最中にdat落ちしたらモーダルで知らせ、書きかけは残す', (tester) async {
    final f = QueueFetcher([
      ok(res1),
      redirect('/liveedge/kako/1762/17621/1762103691.dat'),
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    final composer = find.widgetWithText(TextField, 'レスを書く');
    await tester.tap(composer);
    await tester.enterText(composer, '書きかけ');
    await tester.pump();

    // ポーリングで過去ログへ飛ばされる（＝閲覧中に dat落ち）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('スレッドがdat落ちしました'), findsOneWidget);
    // 書きかけは消さない。コピーして次スレへ持っていける。
    expect(find.text('本文をコピー'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    // モーダルを閉じたあとも、書きかけは欄に残り、選択してコピーできる。
    // enabled: false だと選択もできず、取り出す手立てが無くなる。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '書きかけ');
    expect(field.readOnly, isTrue);
    expect(field.enabled, isNot(false));
    // 送信・添付は止めたまま。
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNull,
    );
  });

  testWidgets('書いている最中に完走したらモーダルで知らせる', (tester) async {
    final f = QueueFetcher([
      ok(res1),
      ok([...res1, ...over1000]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'レスを書く'), '書きかけ');
    await tester.pump();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('スレッドが完走しました'), findsOneWidget);
  });

  // 一覧のポーリングが subject.txt から消えたことに気づくと、親から
  // initialStatusLabel が降りてくる。dat 本体はまだ 200 を返し続けるので、
  // 「書き込み終了だが過去ログにはまだ移っていない」状態はこの経路でしか
  // 分からない。
  testWidgets('一覧側がdat落ちに気づいたときも書いている最中ならモーダルで知らせる', (tester) async {
    final f = QueueFetcher([ok(res1)]);
    final label = ValueNotifier<String?>(null);
    addTearDown(label.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<String?>(
          valueListenable: label,
          builder: (_, value, _) => ThreadScreen(
            threadKey: '1762103691',
            threadTitle: 'テストスレ',
            fetcher: f,
            pollInterval: const Duration(seconds: 5),
            readHistory: ReadHistory(MemoryReadHistoryStorage()),
            initialStatusLabel: value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'レスを書く'), '書きかけ');
    await tester.pump();

    label.value = 'dat落ち';
    await tester.pumpAndSettle();

    expect(find.text('スレッドがdat落ちしました'), findsOneWidget);
  });

  testWidgets('書いていなければdat落ちしてもモーダルは出さない', (tester) async {
    final f = QueueFetcher([
      ok(res1),
      redirect('/liveedge/kako/1762/17621/1762103691.dat'),
      ok([...res1, ...res2]),
    ]);
    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('2レス ・ dat落ち'), findsOneWidget);
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

  testWidgets('返信数に応じて件数の色と太さを変える', (tester) async {
    // レス 2 は 1 件（閾値未満）、レス 3 は 5 件、レス 4 は 10 件。
    final bodies = <int, String>{};
    bodies[5] = '>>2 ひとつだけ';
    for (var i = 0; i < 5; i++) {
      bodies[10 + i] = '>>3 $i';
    }
    for (var i = 0; i < 10; i++) {
      bodies[30 + i] = '>>4 $i';
    }
    final f = QueueFetcher([ok(manyResWithBodies(60, bodies))]);

    await tester.pumpWidget(app(f));
    await tester.pumpAndSettle();

    // 件数そのもののテキストから拾う（同じ数字が本文にもあるので、
    // 返信数チップの中に限る）。
    TextStyle styleOfCount(int count) => tester
        .widget<Text>(
          find
              .descendant(of: replyCounts(), matching: find.text('$count'))
              .first,
        )
        .style!;

    final scheme = Theme.of(
      tester.element(find.byType(ThreadScreen)),
    ).colorScheme;
    // 閾値未満は従来どおり primary。
    expect(styleOfCount(1).color, scheme.primary);
    expect(styleOfCount(1).fontWeight, FontWeight.w700);
    // 5 件以上は色が上がる。10 件以上はさらに太くなる（色は同じ＝テキストなので
    // 淡くせず、段階は太さで示す）。
    expect(styleOfCount(5).color, scheme.error);
    expect(styleOfCount(5).fontWeight, FontWeight.w700);
    expect(styleOfCount(10).color, scheme.error);
    expect(styleOfCount(10).fontWeight, FontWeight.w800);
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

  group('貼られたスレのカード', () {
    const other = Board(
      host: 'mi.5ch.io',
      boardKey: 'news4vip',
      title: 'ニュー速VIP',
    );
    const url = 'https://mi.5ch.io/news4vip/1700000000';

    setUp(() {
      ThreadLinks.clearCache();
      ThreadLinks.boards = () => const [Board.eddibb, other];
      ThreadLinks.debugFetcher = MapFetcher({
        'https://mi.5ch.io/news4vip/dat/1700000000.dat': ok(
          datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:x<> 本文 <>VIPのスレタイ'),
        ),
      });
    });
    tearDown(() {
      ThreadLinks.debugFetcher = null;
      ThreadLinks.boards = () => const [];
      ThreadLinks.clearCache();
    });

    testWidgets('別板のスレ URL でも板名とスレタイを出す', (tester) async {
      final f = QueueFetcher([
        ok(
          datLine(
            '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 次スレ<br>$url <>スレタイ',
          ),
        ),
      ]);
      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();

      expect(find.text('ニュー速VIP'), findsOneWidget);
      expect(find.text('VIPのスレタイ'), findsOneWidget);
    });

    testWidgets('カードをタップすると別板のスレをアプリ内で開く', (tester) async {
      final f = QueueFetcher([
        ok(
          datLine(
            '名無し<><>2025/11/03(月) 02:14:51.907 ID:aaa<> 次スレ<br>$url <>スレタイ',
          ),
        ),
      ]);
      // その板の既読履歴を先に用意しておく（読み込みはファイル越しで、pump では
      // 進まないため）。アプリでも 2 回目以降はこの状態から開く。
      await tester.runAsync(() => ReadHistory.forBoard(other));

      await tester.pumpWidget(app(f));
      await tester.pumpAndSettle();

      await tester.tap(find.text('VIPのスレタイ'));
      await tester.pump(); // タップの処理
      await tester.pump(const Duration(milliseconds: 400)); // 画面の遷移

      // その板のエンドポイントで開き、取れているスレタイをそのまま見出しに使う。
      final opened = tester.widgetList<ThreadScreen>(find.byType(ThreadScreen));
      expect(opened.last.endpoints.host, 'mi.5ch.io');
      expect(opened.last.endpoints.boardKey, 'news4vip');
      expect(opened.last.threadKey, '1700000000');
      expect(opened.last.threadTitle, 'VIPのスレタイ');
    });
  });
}
