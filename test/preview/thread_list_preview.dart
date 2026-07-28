/// スレ一覧の見た目を PNG に落とす確認用スクリプト。
///
/// **通常のテストでは走らない。** ファイル名が `_test.dart` で終わらないので
/// `flutter test`（`test/**_test.dart` を拾う）の対象外になる。撮るときだけ
/// パスを明示して実行する:
///
/// ```
/// flutter test test/preview/thread_list_preview.dart
/// ```
///
/// 出力先は既定で `notes/preview/`（.gitignore 対象）。`OUT` で変えられる。
///
/// 自動更新を 1 回わざと起こして、新着バッジが付いた行・subject.txt から落ちて
/// 「dat落ち」が付いた行も一緒に写るようにしてある（行の高さが動かないこと、
/// 停止状態が目立ちすぎないことの確認用）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

import '../support/preview_fonts.dart';

final _win31j = Windows31JCodec();

class _QueueFetcher implements HttpFetcher {
  _QueueFetcher(this._bodies);
  final List<String> _bodies;
  int _calls = 0;

  @override
  Future<FetchResponse> get(Uri url, {Map<String, String> headers = const {}}) {
    final i = _calls < _bodies.length ? _calls : _bodies.length - 1;
    _calls++;
    return Future.value(
      FetchResponse(
        statusCode: 200,
        bodyBytes: _win31j.encode(_bodies[i]),
        headers: {'last-modified': 'LM$i'},
      ),
    );
  }
}

/// 一覧に出したい状態を一通り並べた subject.txt。
/// [dropped] を立てると 3 番目のスレが消える（＝ dat 落ち）。
String _subject({required bool dropped}) {
  final lines = [
    '1762103601.dat<>実況の勢いがあるスレ。長いスレタイの折り返しもここで見る (842)',
    '1762103602.dat<>既読で新着があるスレ (317)',
    if (!dropped) '1762103603.dat<>そのうち subject から落ちるスレ (48)',
    '1762103604.dat<>完走したスレ (1000)',
    '1762103605.dat<>一覧で見たがまだ開いていないスレ (12)',
    '1762103607.dat<>一覧でも初めて見るスレ (2)',
    '1762103606.dat<>自分で立てたスレ (3)',
  ];
  return '${lines.join('\n')}\n';
}

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  double width = 420,
}) async {
  tester.view.physicalSize = Size(width * 2, 720 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final history = ReadHistory(MemoryReadHistoryStorage());
  // 既読（一部は新着あり）と、自分のスレを仕込む。
  await history.markOpenedThread(
    const ThreadSummary(
      key: '1762103602',
      title: '既読で新着があるスレ',
      resCount: 300,
      capName: null,
    ),
  );
  await history.markRead('1762103602', 300);
  await history.markOpenedThread(
    const ThreadSummary(
      key: '1762103603',
      title: 'そのうち subject から落ちるスレ',
      resCount: 48,
      capName: null,
    ),
  );
  await history.markRead('1762103603', 48);
  await history.markOwnThread('1762103606');
  // 「一覧で見たことがある」ぶん（1762103607 だけ入れない＝新顔）。
  await history.markListed([
    '1762103601',
    '1762103604',
    '1762103605',
    '1762103606',
  ]);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ThreadListScreen(
          fetcher: _QueueFetcher([
            _subject(dropped: false),
            _subject(dropped: true),
          ]),
          pollInterval: const Duration(seconds: 5),
          readHistory: history,
        ),
      ),
    ),
  );
  // 初回取得 → レイアウト。
  await tester.pump();
  await tester.pump(Duration.zero);
  // 自動更新を 1 回起こす（3 番目が落ちて「dat落ち」が付く）。
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 400));

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  final file = File(out)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $out');
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  setUpAll(loadPreviewFonts);

  testWidgets('light', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/list_light.png');
  });

  testWidgets('dark', (tester) async {
    await _shoot(tester, ElecTheme.dark(), '$dir/list_dark.png');
  });
}
