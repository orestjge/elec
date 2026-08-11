import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_launcher.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/src/ui/write_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();
List<int> sjis(String s) => _win31j.encode(s);
List<int> datLine(String s) => [...sjis(s), 0x0A];

List<int> unauthBody(String code) => sjis(
  '<html><!-- 2ch_X:error -->'
  '<meta name="error_code" content="E-Unauthenticated">'
  "<body>エラー！<br>認証コード'$code'を用いて、以下のURLから認証を行ってください \n"
  ' https://bbs.eddibb.cc/auth-code</body></html>',
);
List<int> successBody() =>
    sjis('<html><!-- 2ch_X:true --><body>書きこみました</body></html>');

/// GET は固定の dat、POST は「呼び出し回数で切り替わる」フェイク。
class ScriptedClient implements HttpFetcher, HttpPoster {
  ScriptedClient(this._postResponses, {this.dat});
  final List<FetchResponse> _postResponses;
  final List<int>? dat;
  int posts = 0;
  String? lastBody;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async => FetchResponse(
    statusCode: 200,
    bodyBytes:
        dat ?? datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 本文 <>スレタイ'),
  );

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    lastBody = body;
    final i = posts < _postResponses.length ? posts : _postResponses.length - 1;
    posts++;
    return _postResponses[i];
  }
}

class FakeLauncher implements AuthLauncher {
  bool opened = false;
  Uri? url;
  @override
  Future<bool> open(Uri url) async {
    opened = true;
    this.url = url;
    return true;
  }
}

class AppendAfterPostClient implements HttpFetcher, HttpPoster {
  int gets = 0;
  int posts = 0;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    gets++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: gets == 1
          ? datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 既存 <>スレタイ')
          : [
              ...datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 既存 <>スレタイ'),
              ...datLine('名無し<><>2025/11/03(月) 02:20:00.000 ID:b<> 自分の投稿 <>'),
            ],
    );
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    posts++;
    return FetchResponse(statusCode: 200, bodyBytes: successBody());
  }
}

/// POST 応答に `x-resnum` を載せ、GET では自分の後に他人のレスも増える。
/// 末尾ヒューリスティックなら他人のレスを誤って自分にしてしまう状況。
class PreciseResNumClient implements HttpFetcher, HttpPoster {
  int gets = 0;
  int posts = 0;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    gets++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: gets == 1
          ? datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 既存 <>スレタイ')
          : [
              ...datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 既存 <>スレタイ'),
              ...datLine('名無し<><>2025/11/03(月) 02:20:00.000 ID:b<> 自分の投稿 <>'),
              ...datLine('名無し<><>2025/11/03(月) 02:20:05.000 ID:c<> 他人の投稿 <>'),
            ],
    );
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    posts++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: successBody(),
      headers: const {'x-resnum': '2'},
    );
  }
}

class StaleOnceAfterPostClient implements HttpFetcher, HttpPoster {
  int gets = 0;
  int posts = 0;
  final List<Map<String, String>> getHeaders = [];

  List<int> get _oldDat =>
      datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 既存 <>スレタイ');

  List<int> get _newDat => [
    ..._oldDat,
    ...datLine('名無し<><>2025/11/03(月) 02:20:00.000 ID:b<> 自分の投稿 <>'),
  ];

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    getHeaders.add(Map.of(headers));
    gets++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: gets < 3 ? _oldDat : _newDat,
    );
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    posts++;
    return FetchResponse(statusCode: 200, bodyBytes: successBody());
  }
}

/// 画面に収まらない長さのスレ。60 レスで開き、投稿すると [afterPost] 件まで
/// 増える（自分のレスは [resNum]）。[bodies] に無い番号の本文は `レスN`。
class LongThreadClient implements HttpFetcher, HttpPoster {
  LongThreadClient({
    this.afterPost = 61,
    this.resNum = 61,
    this.bodies = const {},
  });

  final int afterPost;
  final int resNum;
  final Map<int, String> bodies;
  int gets = 0;
  int posts = 0;

  List<int> _dat(int n) => [
    for (var i = 1; i <= n; i++)
      ...datLine(
        '名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> ${bodies[i] ?? 'レス$i'} '
        '<>${i == 1 ? 'スレタイ' : ''}',
      ),
  ];

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    gets++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: _dat(gets == 1 ? 60 : afterPost),
    );
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    posts++;
    return FetchResponse(
      statusCode: 200,
      bodyBytes: successBody(),
      headers: {'x-resnum': '$resNum'},
    );
  }
}

void main() {
  Widget longThreadApp(
    LongThreadClient client,
    ReadHistory history, {
    ThreadViewSettings? view,
  }) => MaterialApp(
    home: ThreadScreen(
      threadKey: '123',
      threadTitle: 'テスト',
      fetcher: client,
      authStore: AuthStore(MemoryTokenStorage()),
      authLauncher: FakeLauncher(),
      pollInterval: const Duration(seconds: 60),
      readHistory: history,
      threadViewSettings: view,
    ),
  );

  /// 本文を打って送信し、書き込み後の取り直しと追従スクロールまで進める。
  Future<void> post(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 「映っているか」の判定は追従が落ち着いてから走る。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  /// [number] のレスが実際に画面へ出ているか（組まれているだけでは数えない）。
  bool showsRes(WidgetTester tester, int number) {
    final item = find.byWidgetPredicate(
      (w) => w is PostItem && w.res.number == number,
    );
    if (item.evaluate().isEmpty) return false;
    final screen = tester.getRect(find.byType(Scaffold));
    final rect = tester.getRect(item);
    return rect.top < screen.bottom && rect.bottom > screen.top;
  }

  testWidgets('途中を読んでいるときの投稿では読んでいた場所を動かさない', (tester) async {
    final client = LongThreadClient();
    final history = ReadHistory(MemoryReadHistoryStorage());

    await tester.pumpWidget(longThreadApp(client, history));
    await tester.pumpAndSettle();
    // 先頭を読んでいる（末尾は組まれてもいない）。
    expect(find.text('レス1'), findsOneWidget);
    expect(find.text('レス60'), findsNothing);

    await post(tester);

    // 読んでいた先頭のまま。自分のレスへ勝手に飛ばさない。
    expect(history.isOwnPost('123', 61), isTrue);
    expect(find.text('レス1'), findsOneWidget);
    expect(showsRes(tester, 61), isFalse);

    // 代わりに押せば飛べる知らせを出す。
    expect(find.text('書き込みが反映されました'), findsOneWidget);
    await tester.tap(find.text('見る'));
    await tester.pumpAndSettle();

    expect(showsRes(tester, 61), isTrue);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('送り終えたら入力欄は焦点を手放して 1 段へ戻る', (tester) async {
    // 送った直後は書く用が済んだところ。キーボードと 2 段の欄が場所を取り
    // 続ける理由が無いので、欄は空のまま 1 段（ボタンが横並び）へ戻す。
    final client = LongThreadClient();
    await tester.pumpWidget(
      longThreadApp(client, ReadHistory(MemoryReadHistoryStorage())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await post(tester);

    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
    // 1 段＝ボタンが欄と横に揃う。
    expect(
      tester.getRect(find.widgetWithIcon(IconButton, Icons.send)).top,
      tester.getRect(field).top,
    );
  });

  testWidgets('ツリー表示で自分のレスが末尾に来ないときは知らせから飛べる', (tester) async {
    final view = ThreadViewSettings(MemoryThreadViewSettingsStorage());
    await view.setLayout(ThreadLayout.tree);
    // 62〜75 は返信していないので根のまま並び、>>1 への返信である自分の 76 は
    // 先に来た 61 と同じ引用行の下＝その手前へ入る（末尾から 14 行上）。
    final client = LongThreadClient(
      afterPost: 76,
      resNum: 76,
      bodies: const {61: '>>1 だれかの返信', 76: '>>1 自分の返信'},
    );
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead('123', 60); // 末尾を追っている

    await tester.pumpWidget(longThreadApp(client, history, view: view));
    await tester.pumpAndSettle();

    await post(tester);

    // 自分の 76 は末尾（75）のずっと上に入るので、末尾追従では映らない。
    expect(history.isOwnPost('123', 76), isTrue);
    expect(showsRes(tester, 76), isFalse);

    await tester.tap(find.text('見る'));
    await tester.pumpAndSettle();

    expect(showsRes(tester, 76), isTrue);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('末尾を追っているときは追従で見えるので知らせない', (tester) async {
    final client = LongThreadClient();
    final history = ReadHistory(MemoryReadHistoryStorage());
    // 60 レスまで読んである＝続きから（末尾）で開く。実況しているところ。
    await history.markRead('123', 60);

    await tester.pumpWidget(longThreadApp(client, history));
    await tester.pumpAndSettle();
    expect(find.text('レス60'), findsOneWidget);
    expect(find.text('レス1'), findsNothing);

    await post(tester);

    expect(history.isOwnPost('123', 61), isTrue);
    expect(showsRes(tester, 61), isTrue);
    expect(find.text('自分'), findsOneWidget);
    expect(find.text('書き込みが反映されました'), findsNothing);
  });

  testWidgets('新着の追従は末尾を通り越さない（跳ね返らない）', (tester) async {
    final client = LongThreadClient();
    final history = ReadHistory(MemoryReadHistoryStorage());
    await history.markRead('123', 55);

    // 端で跳ねる物理（iOS の挙動）で見る。行き過ぎを頼んでいれば、端を越えて
    // から戻るぶんがはみ出し量として出る。端で止まる物理では隠れてしまう。
    var overshoot = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: ScrollConfiguration(
          behavior: const _BouncingBehavior(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              final over = n.metrics.pixels - n.metrics.maxScrollExtent;
              if (over > overshoot) overshoot = over;
              return false;
            },
            child: ThreadScreen(
              threadKey: '123',
              threadTitle: 'テスト',
              fetcher: client,
              authStore: AuthStore(MemoryTokenStorage()),
              authLauncher: FakeLauncher(),
              pollInterval: const Duration(seconds: 60),
              readHistory: history,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 指で末尾まで送る（実況していて最新を見ているところ）。
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(PostItem).first, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(showsRes(tester, 60), isTrue);
    expect(showsRes(tester, 61), isFalse);

    // ポーリングで 61 が届き、末尾へ追従する。
    overshoot = 0;
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();

    expect(showsRes(tester, 61), isTrue);
    expect(overshoot, lessThan(1), reason: 'はみ出し $overshoot');
  });

  testWidgets('コード無し認証ダイアログはURLを表示してコピーできる', (tester) async {
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

    final authUrl = Uri.parse('https://bbs.punipuni.eu/auth-code?token=abc');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthDialog(
            initialCode: '',
            authUrl: authUrl,
            onOpen: (_) async => true,
            onRetry: () async => PostNeedsAuth(authCode: '', authUrl: authUrl),
          ),
        ),
      ),
    );

    expect(find.text('認証が必要です'), findsOneWidget);
    expect(find.text(authUrl.toString()), findsOneWidget);
    expect(find.text('URLをコピー'), findsOneWidget);

    await tester.tap(find.text('URLをコピー'));
    await tester.pumpAndSettle();

    expect(copied, [authUrl.toString()]);
    expect(find.text('認証URLをコピーしました'), findsOneWidget);
  });

  testWidgets('認証後の長い拒否エラーでもダイアログが溢れない', (tester) async {
    tester.view.physicalSize = const Size(420, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final authUrl = Uri.parse('https://bbs.punipuni.eu/auth');
    const longError =
        '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">\n\n'
        'ERROR!\n\n'
        '<!--nobanner-->\n'
        '<!-- 2ch_X:error -->\n'
        'ERROR: 書き込みに必要なレベルが足りていません。。トレーニングしてくださいぷい！'
        'レベルが十分あるのに書き込めないときは忍法帖を再読込してもう一回書き込んでみて！\n'
        'ホスト125-14-139-110.rev.home.ne.jp\n'
        '名前：\n'
        'E-mail：\n'
        'こちらでリロードしてください。 GO!\n'
        '0ch+ BBS 0.7.5 20220323';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthDialog(
            initialCode: '',
            authUrl: authUrl,
            onOpen: (_) async => true,
            onRetry: () async =>
                const PostRejected(errorCode: 'Unknown', message: longError),
          ),
        ),
      ),
    );

    await tester.tap(find.text('認証したので投稿'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('書き込みに必要なレベル'), findsOneWidget);
  });

  testWidgets('通常の書き込み拒否はダイアログで表示してコピーできる', (tester) async {
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

    const message = 'ERROR: 書き込みに必要なレベルが足りていません。';
    final client = ScriptedClient([
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis(
          '<html><!-- 2ch_X:error --><body>エラー！<br>$message</body></html>',
        ),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('書き込みエラー'), findsOneWidget);
    expect(find.textContaining('書き込みに必要なレベル'), findsOneWidget);

    await tester.tap(find.text('コピー'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(copied.single, contains('書き込みに必要なレベル'));
    expect(find.text('エラー内容をコピーしました'), findsOneWidget);
  });

  testWidgets('未認証→コード表示→認証後の再送で成功する', (tester) async {
    final client = ScriptedClient([
      // 1 回目: 未認証（edge-token を Set-Cookie）
      FetchResponse(
        statusCode: 200,
        bodyBytes: unauthBody('016227'),
        setCookies: const ['edge-token=abc123; HttpOnly'],
      ),
      // 2 回目（再送）: 成功
      FetchResponse(
        statusCode: 200,
        bodyBytes: successBody(),
        setCookies: const ['tinker-token=jwt'],
      ),
    ]);
    final launcher = FakeLauncher();
    // テスト専用の空ストア（共有インスタンス・ディスクを汚さない）。
    final store = AuthStore(MemoryTokenStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: store,
          authLauncher: launcher,
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 送信中スピナー・進捗バーが不定アニメーションのため、以降は固定 pump。
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // 入力して送信。
    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await settle();

    // 認証ダイアログにコードが出る。
    expect(find.text('認証が必要です'), findsOneWidget);
    expect(find.text('016227'), findsOneWidget);
    // edge-token は未認証応答から回収済み。
    expect(store.tokens.edgeToken, 'abc123');

    // ブラウザで認証ページを開く。
    await tester.tap(find.text('認証ページを開く'));
    await settle();
    expect(launcher.opened, isTrue);
    expect(launcher.url.toString(), 'https://bbs.eddibb.cc/auth-code');

    // 認証後、再送 → 成功でダイアログが閉じる。
    await tester.tap(find.text('認証したので投稿'));
    await settle();
    expect(find.text('認証が必要です'), findsNothing);
    expect(find.text('書き込みました'), findsOneWidget);
    expect(store.tokens.tinkerToken, 'jwt'); // 成功応答で tinker 更新
    expect(client.posts, 2);

    // 後始末: 保留中の SnackBar タイマーを流す。
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('レス投稿では本文前後の空白を保持する', (tester) async {
    final client = ScriptedClient([
      FetchResponse(statusCode: 200, bodyBytes: successBody()),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const aa = '　 ∧＿∧\n　（　´∀｀）\n ';
    await tester.enterText(find.byType(TextField), aa);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(client.lastBody, isNotNull);
    expect(
      client.lastBody,
      buildBbsCgiBody(board: 'liveedge', threadKey: '123', message: aa),
    );
  });

  testWidgets('画像アップロード後に Imgur URL をレス本文へ挿入する', (tester) async {
    final client = ScriptedClient([
      FetchResponse(statusCode: 200, bodyBytes: successBody()),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          pickAndUploadImages: () async => [
            Uri.parse('https://i.imgur.com/example.jpg'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '本文');
    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // URL の後ろには改行が入り、次の入力を新しい行から始められる。
    expect(find.text('本文\nhttps://i.imgur.com/example.jpg\n'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      client.lastBody,
      buildBbsCgiBody(
        board: 'liveedge',
        threadKey: '123',
        message: '本文\nhttps://i.imgur.com/example.jpg',
      ),
    );
  });

  testWidgets('期限切れで再送すると新しいコードに更新される', (tester) async {
    final client = ScriptedClient([
      // 1 回目: 未認証（コード 111111）
      FetchResponse(
        statusCode: 200,
        bodyBytes: unauthBody('111111'),
        setCookies: const ['edge-token=t1'],
      ),
      // 2 回目（再送）: まだ未認証だが、期限切れで新コード 222222
      FetchResponse(
        statusCode: 200,
        bodyBytes: unauthBody('222222'),
        setCookies: const ['edge-token=t2'],
      ),
    ]);
    final store = AuthStore(MemoryTokenStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: store,
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.enterText(find.byType(TextField), 'やあ');
    await tester.tap(find.byIcon(Icons.send));
    await settle();
    expect(find.text('111111'), findsOneWidget);

    // 再送 → 新コードに更新され、ダイアログは開いたまま。
    await tester.tap(find.text('認証したので投稿'));
    await settle();
    expect(find.text('111111'), findsNothing);
    expect(find.text('222222'), findsOneWidget);
    expect(find.text('認証が必要です'), findsOneWidget); // まだ閉じない
    expect(find.textContaining('新しいコードに更新'), findsOneWidget);
  });

  testWidgets('停止スレではレス入力と送信ができない', (tester) async {
    final client = ScriptedClient(
      [FetchResponse(statusCode: 200, bodyBytes: successBody())],
      dat: [
        ...datLine('名無し<><>2025/11/03(月) 02:14:51.907 ID:a<> 本文 <>スレタイ'),
        ...datLine('1001<><>Over 1000 Thread<>このスレッドは1000を超えました。<>'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 書けないが、書きかけを取り出せるよう欄は読み取り専用で生かす。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
    expect(find.text('書き込み停止中'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(client.posts, 0);
  });

  testWidgets('一覧から dat落ち扱いで開いたスレではレス入力と送信ができない', (tester) async {
    final client = ScriptedClient([
      FetchResponse(statusCode: 200, bodyBytes: successBody()),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          initialStatusLabel: 'dat落ち',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1レス ・ dat落ち'), findsOneWidget);
    // 書けないが、書きかけを取り出せるよう欄は読み取り専用で生かす。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
    expect(find.text('書き込み停止中'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(client.posts, 0);
  });

  testWidgets('投稿成功後に増えたレスを自分のレスとして記録する', (tester) async {
    final client = AppendAfterPostClient();
    final history = ReadHistory(MemoryReadHistoryStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(history.isOwnPost('123', 2), isTrue);
    expect(find.text('自分'), findsOneWidget);
  });

  testWidgets('x-resnum があればその番号を正確に自分のレスにする（末尾ではない）', (tester) async {
    final client = PreciseResNumClient();
    final history = ReadHistory(MemoryReadHistoryStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // ヘッダの番号(2)だけが自分。末尾(3)は他人なので自分にしない。
    expect(history.isOwnPost('123', 2), isTrue);
    expect(history.isOwnPost('123', 3), isFalse);
  });

  testWidgets('投稿直後に古い dat を掴んでも再取得して自分のレスとして記録する', (tester) async {
    final client = StaleOnceAfterPostClient();
    final history = ReadHistory(MemoryReadHistoryStorage());

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          threadKey: '123',
          threadTitle: 'テスト',
          fetcher: client,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pollInterval: const Duration(seconds: 60),
          readHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(history.isOwnPost('123', 1), isFalse);
    expect(history.isOwnPost('123', 2), isFalse);
    expect(client.getHeaders[1].containsKey('Range'), isFalse);
    expect(client.getHeaders[1].containsKey('If-Modified-Since'), isFalse);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(client.posts, 1);
    expect(history.isOwnPost('123', 1), isFalse);
    expect(history.isOwnPost('123', 2), isTrue);
    expect(find.text('自分'), findsOneWidget);
  });
}

/// 端で跳ねる物理を使わせる（テストの既定は端で止まる Android の物理）。
class _BouncingBehavior extends MaterialScrollBehavior {
  const _BouncingBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics();
}
