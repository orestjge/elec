/// スレッド画面の見た目を PNG に落とす確認用スクリプト。
///
/// **通常のテストでは走らない。** ファイル名が `_test.dart` で終わらないので
/// `flutter test`（`test/**_test.dart` を拾う）の対象外になる。撮るときだけ
/// パスを明示して実行する:
///
/// ```
/// flutter test test/preview/thread_screen_preview.dart
/// ```
///
/// 出力先は既定で `notes/preview/`（.gitignore 対象）。`OUT` で変えられる。
///
/// アサーションはしない。**[WidgetTester.pumpAndSettle] も使わない** ——
/// スレッド画面はポーリングタイマーとつまみの自動フェードを持っていて「フレーム
/// が予約されない状態」に永久に到達せず、10 分のタイムアウトまで回り続けるため。
/// 必要な分だけ [WidgetTester.pump] する。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

import '../support/preview_fonts.dart';

final _win31j = Windows31JCodec();
List<int> _datLine(String s) => [..._win31j.encode(s), 0x0A];

class _StaticFetcher implements HttpFetcher {
  _StaticFetcher(this.body);
  final List<int> body;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) => Future.value(
    FetchResponse(statusCode: 200, bodyBytes: body, headers: const {}),
  );
}

/// 目印が一通り出るスレを組む。
/// レス 2 に 5 件・レス 3 に 12 件の返信、レス 8 は自分のレス（＝自分宛も付く）。
/// [watchoi] を立てると、名前に `</b>(L20 ...)<b>` が付いた板（ワッチョイ有効）の
/// dat になる。実データと同じ形にしてある（experiment_sample.dat 参照）。
/// [noId] を立てると ID 表示が無い板の dat になる（日付欄に `ID:` が付かない）。
List<int> _dat({bool watchoi = false, bool noId = false}) {
  const ids = ['aB3xYz9Qw', 'Kd8mN2pLr', 'Qw7vT4sZx', 'Hj5cB1nMe'];
  final bytes = <int>[];
  for (var i = 1; i <= 60; i++) {
    final body = switch (i) {
      1 => '返信なしのレス。番号の色は今までどおり。',
      2 => '返信を5件集めたレス。番号の色が上がる。',
      3 => '返信を12件集めたレス。さらに太くなる。',
      8 => '自分の書き込み。スレマップにも目印が出る。',
      9 => '>>8 自分宛のレス。左に帯が付く。',
      _ when i > 10 && i <= 15 => '>>2 なるほど',
      _ when i > 30 && i <= 42 => '>>3 それな',
      _ => 'ふつうのレス $i。本文はこのくらいの長さで折り返しを見る。',
    };
    // 名無しに混ざるコテハン。名無しの名前を省いたときの見え方（コテハンだけが
    // 残る・ID の位置が揃う）を確かめるために入れておく。
    final base = switch (i) {
      4 => 'ながい名前のコテハン◆Ab12Cd34Ef',
      5 => 'これはかなり長いコテハンの名前です◆Zz99Yy88',
      _ => 'エッヂの名無し',
    };
    final name = watchoi
        ? '$base </b>(L20 ${ids[i % ids.length].substring(0, 4)}-6NV7)<b>'
        : base;
    final date = '2025/11/03(月) 02:14:${i.toString().padLeft(2, '0')}.907';
    final dateAndId = noId ? date : '$date ID:${ids[i % ids.length]}';
    bytes.addAll(
      _datLine('$name<><>$dateAndId<> $body <>${i == 1 ? 'スレタイ' : ''}'),
    );
  }
  return bytes;
}

/// [width] は論理ピクセルの画面幅。既定は普通の端末幅。狭い端末（ヘッダが
/// 折り返す幅）での見え方も確かめられるように可変にしてある。
Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  double width = 420,
  bool watchoi = false,
  bool noId = false,
  ThreadLayout layout = ThreadLayout.number,
  int? lastSeen,
}) async {
  tester.view.physicalSize = Size(width * 2, 900 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final history = ReadHistory(MemoryReadHistoryStorage());
  await history.markOwnPost('1762103691', 8);
  // 既読位置を入れると新着ラインが出る（ツリー表示ではここが境界になる）。
  if (lastSeen != null) await history.markRead('1762103691', lastSeen);
  final view = ThreadViewSettings(MemoryThreadViewSettingsStorage());
  await view.setLayout(layout);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ThreadScreen(
          threadKey: '1762103691',
          threadTitle: 'スレマップと返信数の見た目を確認するスレ',
          fetcher: _StaticFetcher(_dat(watchoi: watchoi, noId: noId)),
          // 撮っている間にポーリングが走らないよう十分長くする。
          pollInterval: const Duration(hours: 1),
          readHistory: history,
          threadViewSettings: view,
          // 一覧から開いたときと同じに、板の既定名を渡す（名無しの名前が省かれる）。
          defaultName: Board.eddibb.defaultName,
        ),
      ),
    ),
  );
  // 取得（Future）の解決 → 初回レイアウト → つまみのフェードイン、の 3 段階分。
  // つまみは 2.4 秒で自動的に消えるので、それより手前で撮る。
  await tester.pump();
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 400));

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  // 画像化はエンジン側の実際の非同期処理なので、fake async のゾーンの外へ出す
  // （runAsync を挟まないと Future が完了せずタイムアウトまで止まる）。
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

  // フォント読み込みはテスト本体の外で（fake async のゾーンに入れない）。
  setUpAll(loadPreviewFonts);

  testWidgets('light', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/thread_light.png');
  });

  testWidgets('dark', (tester) async {
    await _shoot(tester, ElecTheme.dark(), '$dir/thread_dark.png');
  });

  // 名前にワッチョイが付く板。既定名が消えて括弧書きだけ残るのを見る。
  testWidgets('watchoi', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thread_watchoi.png',
      watchoi: true,
    );
  });

  // ツリー表示（未読スレ）。返信がぶら下がって字下げされる。
  // ID 表示が無い板。identicon を出せないので、代わりの枠でレスの切れ目を保つ。
  testWidgets('no id', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/thread_no_id.png', noId: true);
  });

  testWidgets('tree', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thread_tree.png',
      layout: ThreadLayout.tree,
    );
  });

  // ツリー表示＋新着。新着ラインから下は番号順のまま積み、指し先を薄く再掲する。
  testWidgets('tree with arrivals', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thread_tree_arrivals.png',
      layout: ThreadLayout.tree,
      lastSeen: 10,
    );
  });

  // ヘッダが折り返す幅。番号・名前・ID・時刻の並びが崩れないかを見る。
  testWidgets('narrow', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thread_narrow.png',
      width: 340,
    );
  });
}
