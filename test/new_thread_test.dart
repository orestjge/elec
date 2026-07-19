import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_launcher.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:elec/src/ui/new_thread_screen.dart';
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
    final submit = find.widgetWithText(FilledButton, '立てる');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'テストスレ');
    await tester.enterText(find.byType(TextField).at(1), '本文だよ');
    await tester.pump();

    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
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

    await tester.tap(find.widgetWithText(FilledButton, '立てる'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      poster.lastBody,
      buildBbsCgiThreadBody(board: 'liveedge', title: 'テストスレ', message: aa),
    );
  });
}
