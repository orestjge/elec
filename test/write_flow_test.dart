import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_launcher.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:flutter/material.dart';
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

void main() {
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
          pickAndUploadImage: () async =>
              Uri.parse('https://i.imgur.com/example.jpg'),
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

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
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
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
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
