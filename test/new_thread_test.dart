import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_launcher.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/endpoints.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:elec/src/ui/new_thread_screen.dart';
import 'package:elec/src/ui/post_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();

List<int> successBody() =>
    _win31j.encode('<html><!-- 2ch_X:true --><body>書きこみました</body></html>');

/// createThread の POST を記録するフェイク。
class RecordingPoster implements HttpFetcher, HttpPoster {
  RecordingPoster({this.response});

  /// POST への応答。既定は 5ch 互換の成功ページ。
  final FetchResponse? response;

  String? lastBody;
  Uri? lastUrl;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async => FetchResponse(statusCode: 200, bodyBytes: const []);

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    lastBody = body;
    lastUrl = url;
    return response ?? FetchResponse(statusCode: 200, bodyBytes: successBody());
  }
}

class FakeLauncher implements AuthLauncher {
  @override
  Future<bool> open(Uri url) async => true;
}

void main() {
  testWidgets('タイトルと本文を入れて立てると createThread が POST される', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    // 空では「立てる」は押せない。
    final submit = find.byKey(const ValueKey('new-thread-submit'));
    expect(tester.widget<ButtonStyleButton>(submit).onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.enterText(find.byType(TextField).at(1), '本文だよ');
    await tester.pump();

    expect(tester.widget<ButtonStyleButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 新規スレッド作成の POST が飛んでいる。
    expect(poster.lastBody, isNotNull);
    expect(poster.lastBody, startsWith('submit='));
    expect(poster.lastBody, contains('&subject='));
    expect(poster.lastBody, isNot(contains('key=')));
  });

  testWidgets('新規スレ本文では本文前後の空白を保持する', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    const aa = '　 ∧＿∧\n　（　´∀｀）\n ';
    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.enterText(find.byType(TextField).at(1), aa);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      poster.lastBody,
      buildBbsCgiThreadBody(board: 'liveedge', title: 'テストスレ', message: aa),
    );
  });

  testWidgets('したらばのスレ立ては write.cgi/new へ EUC-JP で送る', (tester) async {
    final poster = RecordingPoster(
      response: FetchResponse(
        statusCode: 200,
        bodyBytes: EucJpEncoder().convert(
          '<html><!-- 2ch_X:true --><body>書きこみました。</body></html>',
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          endpoints: EdgeEndpoints.forBoard(
            const Board(
              host: 'jbbs.shitaraba.net',
              boardKey: 'otaku/18550',
              title: 'したらばの板',
              kind: BoardKind.shitaraba,
            ),
          ),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.enterText(find.byType(TextField).at(1), 'みんないる');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      poster.lastUrl.toString(),
      'https://jbbs.shitaraba.net/bbs/write.cgi/otaku/18550/new/',
    );
    expect(poster.lastBody, contains('SUBJECT=%A5%C6%A5%B9%A5%C8%A5%B9%A5%EC'));
    expect(poster.lastBody, contains('MESSAGE=%A4%DF%A4%F3%A4%CA%A4%A4%A4%EB'));
    expect(poster.lastBody, contains('DIR=otaku'));
    expect(poster.lastBody, contains('BBS=18550'));
    expect(poster.lastBody, isNot(contains('KEY=')));
  });

  testWidgets('本文に AA を書くと、AA の字で・幅に収めて見せる', (tester) async {
    // レス入力欄と同じ扱い（[composeAsciiArtFit]）。書いている最中から絵として
    // 見えないと、スレ立ての 1 レス目に何を置いたのか確かめられない。
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    const aa = '''
　　 ∧＿∧　　　　＿＿＿＿＿＿＿
　　（　´∀｀）　＜　横に長い AA
　　（　　　　）　￣￣￣￣￣￣￣''';

    final body = find.byType(TextField).at(1);
    await tester.enterText(body, aa);
    await tester.pump();

    final art = tester.widget<TextField>(body);
    expect(art.style?.fontFamily, 'Monapo');
    expect(art.maxLines, greaterThan(24));

    await tester.enterText(body, 'ふつうの本文です');
    await tester.pump();

    final plain = tester.widget<TextField>(body);
    expect(plain.style?.fontFamily, isNot('Monapo'));
    expect(plain.maxLines, 24);
  });

  testWidgets('画像を添付すると本文へ URL が入りプレビューが出る', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pickAndUploadImages: () async => [
            Uri.parse('https://i.imgur.com/example.jpg'),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.tap(find.byTooltip('画像を追加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // URL の後ろには改行が入る。
    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(body.controller!.text, 'https://i.imgur.com/example.jpg\n');
    // レス表示と同じ仕組みでプレビューが出る。
    expect(find.byType(PostImages), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 投稿本文には末尾の改行を残さない。
    expect(
      poster.lastBody,
      buildBbsCgiThreadBody(
        board: 'liveedge',
        title: 'テストスレ',
        message: 'https://i.imgur.com/example.jpg',
      ),
    );
  });

  testWidgets('ファイルを添付すると本文へ URL が入る', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pickAndUploadFile: () async =>
              Uri.parse('https://files.catbox.moe/abc123.zip'),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.tap(find.byTooltip('ファイルを添付'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(body.controller!.text, 'https://files.catbox.moe/abc123.zip\n');

    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 投稿本文には末尾の改行を残さない。
    expect(
      poster.lastBody,
      buildBbsCgiThreadBody(
        board: 'liveedge',
        title: 'テストスレ',
        message: 'https://files.catbox.moe/abc123.zip',
      ),
    );
  });

  // カウンタが 0 文字のときだけ消えると、1 文字目で下の入力欄が押し下げられる。
  testWidgets('文字数カウンタは0文字でも出て、書き始めても入力欄が動かない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: RecordingPoster(),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 / 192'), findsOneWidget);
    final before = tester.getRect(find.byType(TextField).at(1));

    await tester.enterText(find.byType(TextField).at(0), 'あ');
    await tester.pump();

    expect(find.text('1 / 192'), findsOneWidget);
    expect(tester.getRect(find.byType(TextField).at(1)), before);
  });

  testWidgets('スレッドタイトルが折り返すとタイトル入力欄が広がる', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: RecordingPoster(),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleField = find.byType(TextField).first;
    expect(tester.getRect(titleField).height, 42);

    await tester.enterText(
      titleField,
      'これはかなり長いスレッドタイトルで入力欄が二行以上に折り返されたときに高さが自然に広がることを確認するためのテスト用タイトルです',
    );
    await tester.pump();

    expect(tester.getRect(titleField).height, greaterThan(42));
  });

  // デスクトップの既定の密度（compact）は InputDecoration の上下パディングと
  // ボタンの最小サイズを 8 削るので、放っておくとスレタイ欄・添付・立てるが
  // ばらばらの高さになる。レス入力欄と同じ 42 に揃っていることを見る。
  testWidgets('スレ立ての入力欄と操作ボタンは同じ高さに揃う（デスクトップの密度でも）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(visualDensity: VisualDensity.compact),
        home: NewThreadScreen(
          fetcher: RecordingPoster(),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double heightOf(Finder f) => tester.getRect(f).height;
    final title = heightOf(find.byType(TextField).first);
    final attach = heightOf(
      find.ancestor(
        of: find.byIcon(Icons.image_outlined),
        matching: find.byType(IconButton),
      ),
    );
    // 「立てる」はタップ判定が実寸より大きいので、塗りの出る Material を見る。
    final submit = heightOf(
      find
          .descendant(
            of: find.byKey(const ValueKey('new-thread-submit')),
            matching: find.byType(Material),
          )
          .first,
    );

    expect(title, 42);
    expect(attach, 42);
    expect(submit, 42);
  });

  // Scaffold は bottomNavigationBar をキーボードの上へ押し上げないので、操作バーを
  // そこに置くと立てる・添付がキーボードに隠れる。キーボード分の inset を与えて、
  // バーがその上に残ることを見る。
  testWidgets('キーボードを開いても立てる・添付ボタンがキーボードに隠れない', (tester) async {
    const keyboard = 300.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: keyboard)),
            child: NewThreadScreen(
              fetcher: RecordingPoster(),
              authStore: AuthStore(MemoryTokenStorage()),
              authLauncher: FakeLauncher(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final keyboardTop =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        keyboard;
    for (final f in [
      find.byKey(const ValueKey('new-thread-submit')),
      find.byIcon(Icons.image_outlined),
      find.byIcon(Icons.attach_file),
    ]) {
      expect(tester.getRect(f).bottom, lessThanOrEqualTo(keyboardTop));
    }
  });

  testWidgets('名前欄を選ぶと本文の先頭にコマンドが入り、そのまま投稿される', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.enterText(find.byType(TextField).at(1), '本文だよ');
    await tester.pump();

    // 既定はコマンド無し。
    expect(find.text('名前欄: なし'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-thread-command')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ワッチョイ').last);
    await tester.pumpAndSettle();

    // 書きかけの本文は消えず、コマンドが先頭に足される。
    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(body.controller!.text, '!metadent:vv:\n本文だよ');
    expect(find.text('名前欄: ワッチョイ'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-thread-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      poster.lastBody,
      buildBbsCgiThreadBody(
        board: 'liveedge',
        title: 'テストスレ',
        message: '!metadent:vv:\n本文だよ',
      ),
    );
  });

  testWidgets('選び直してもコマンド行は増えず差し替わる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: RecordingPoster(),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(1), '本文');
    await tester.pump();

    Future<void> pick(String label) async {
      await tester.tap(find.byKey(const ValueKey('new-thread-command')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await pick('ワッチョイ');
    await pick('レベル');
    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(body.controller!.text, '!metadent:v:\n本文');

    await pick('なし');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '本文',
    );
  });

  testWidgets('コマンドを受け付けない板では名前欄の選択を出さない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: RecordingPoster(),
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          endpoints: const EdgeEndpoints(
            host: 'nova.5ch.net',
            boardKey: 'livegalileo',
            kind: BoardKind.fivech,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('new-thread-command')), findsNothing);
  });
}
