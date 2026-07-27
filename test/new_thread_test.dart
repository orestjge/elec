import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_launcher.dart';
import 'package:elec/src/net/auth_store.dart';
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
  String? lastBody;

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
    return FetchResponse(statusCode: 200, bodyBytes: successBody());
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

  testWidgets('画像を添付すると本文へ URL が入りプレビューが出る', (tester) async {
    final poster = RecordingPoster();

    await tester.pumpWidget(
      MaterialApp(
        home: NewThreadScreen(
          fetcher: poster,
          authStore: AuthStore(MemoryTokenStorage()),
          authLauncher: FakeLauncher(),
          pickAndUploadImage: () async =>
              Uri.parse('https://i.imgur.com/example.jpg'),
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
}
