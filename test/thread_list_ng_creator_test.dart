/// 一覧からのスレ主 NG と、その通知の後始末。
///
/// この通知だけが「取り消す」を持つ。[SnackBar.persist] は action があると既定で
/// true なので、放っておくと出しっぱなしになる（他のスレを開いても消えない）。
library;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

final _win31j = Windows31JCodec();

/// subject-metadent.txt を 1 本だけ返すフェイク。スレ主 NG は metadent 付きの
/// 一覧（eddist）でしか出ないので、`[xxx★]` の付いた行を返す。
class _StaticFetcher implements HttpFetcher {
  _StaticFetcher(this.body);
  final String body;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async => FetchResponse(
    statusCode: 200,
    bodyBytes: _win31j.encode(body),
    headers: const {'last-modified': 'LM1'},
  );
}

/// スレ画面と違い一覧は [WidgetTester.pumpAndSettle] で落ち着かないので、必要な
/// 分だけ [WidgetTester.pump] する。
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

void main() {
  testWidgets('スレ主NGの通知は時間で消える', (tester) async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();

    await tester.pumpWidget(
      MaterialApp(
        home: ThreadListScreen(
          fetcher: _StaticFetcher('1.dat<>最初のスレ [B3YfDSAP★] (10)\n'),
          pollInterval: const Duration(minutes: 5),
          readHistory: ReadHistory(MemoryReadHistoryStorage()),
          ngStore: ng,
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('最初のスレ'), findsOneWidget);

    await tester.longPress(find.text('最初のスレ'));
    await _pumpFor(tester, const Duration(seconds: 1));
    await tester.tap(find.text('このスレ主を NG'));
    await _pumpFor(tester, const Duration(seconds: 2));

    expect(ng.isNgCreator('B3YfDSAP'), isTrue);
    const notice = 'スレ主 [B3YfDSAP★] を NG にしました';
    expect(find.text(notice), findsOneWidget);
    // 押せるうちは出ている。
    expect(find.text('取り消す'), findsOneWidget);

    // 既定の表示時間（4 秒）を大きく越えれば引っ込む。放っておくと他のスレを
    // 開いても居座り続けていた。
    await _pumpFor(tester, const Duration(seconds: 20));
    expect(find.text(notice), findsNothing);
  });
}
