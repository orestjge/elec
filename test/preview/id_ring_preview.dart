/// **連投数のリング**と**勢いの見せ方**を撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/id_ring_preview.dart
/// ```
///
/// 出力は `notes/preview/id_ring_*.png`。`OUT` で出力先を変えられる。
///
/// 濃さ・太さ・棒の長さは**本体の目盛り**（`lib/src/ui/emphasis.dart`）を
/// そのまま呼ぶので、ここに写るものは実物と同じになる。この枠が振るのは
/// 「輪の太さも段にするか」だけ。
///
/// ## なぜ要ったか
/// テーマを無彩に振った（`lib/theme.dart`）結果、**段階を色相で伝えていたところが
/// 潰れた**:
///
///   - ID の連投数は 4 段（単発 → 2 件以上 → 5 件以上 → 8 件以上）を
///     `onSurfaceVariant` → `primary` → `tertiary` → `error` で表していた。
///     無彩テーマでは真ん中の 2 段がどちらも灰で見分けが付かず、最上段だけが
///     NG と同じ赤に飛んでいた。
///   - スレ一覧の勢い（⚡）は閾値を超えると `primary` になるが、無彩では
///     地の文字とほとんど変わらない。
///
/// ## 決めた方向
/// **段階は色相ではなく量で見せる**。ただし見せ方は量の性質で分ける:
///
///   - **濃淡**——レスの中（連投・返信数）で使う。多いほど濃く、字は太い。
///   - **長さ**——スレ一覧の勢いだけ。色は動かさず、薄い棒が伸びるだけにする。
///     **ID の連投数には使わない**——青天井なので「輪が 1 周＝満杯」と言われても
///     何件なのか読めず、直感に反する。
///
/// ## 量の均し方
///   - 連投数——**対数**、24 件で頭打ち。濃淡 5 段に落ちると、目に見える段は
///     2〜3 / 4〜7 / 8〜15 / 16 以上の 4 つ（単発は輪そのものが出ない）。
///   - 勢い——**常用対数**、100 レス/日から 100k レス/日までの 3 桁。実況の
///     総合板を実測すると大半が 1k〜10k に固まるので（`emphasis.dart` に数字を
///     残してある）、満杯をそこに置くとほとんど全部が振り切れて差が出ない。
///     **棒だけで、色は動かさない**——強調の経緯は
///     `test/preview/popularity_preview.dart`。
///
/// 見るところ:
///   - 実際にいちばん多いところ（連投 2〜6 件、勢い 10〜1k /日）で段が読めるか。
///   - 24px の絵に載せて**潰れない**か（縮小して見ること）。
///   - 一覧を流し見したとき、速いスレが**視線で拾える**か。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:elec/src/ui/emphasis.dart';
import 'package:elec/src/ui/format.dart';
import 'package:elec/src/ui/id_icon.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// リング（連投数）
// ---------------------------------------------------------------------------

/// 絵の一辺。柱の組み方（`post_item.dart` の `_GutterId`）と同じ。
const _iconSize = 24.0;

/// 輪と絵の間、輪の太さ（の基準）。同上。
const _ringPad = 1.5;
const _ringWidth = 1.5;

/// 輪の太さを段にするか。濃さの段（5 段）はどれも同じで、太さだけが変わる。
enum _Width {
  flat('濃さだけ（採用）'),
  two('＋太さ 2 段'),
  three('＋太さ 3 段');

  const _Width(this.label);
  final String label;

  /// 量 [t] のときの太さ。基準を [_ringWidth] として、段のぶんだけ足す。
  double of(double t) {
    final q = quantizeAmount(t);
    return switch (this) {
      _Width.flat => _ringWidth,
      _Width.two => q >= 0.75 ? _ringWidth + 0.75 : _ringWidth,
      _Width.three => _ringWidth + 0.5 * (q * 2).floorToDouble(),
    };
  }
}

/// 見本 1 つ。絵＋輪＋`n/m` の字。柱の組み方と同じ積み方にする。
class _RingSample extends StatelessWidget {
  const _RingSample({
    required this.id,
    required this.count,
    required this.width,
  });

  final String id;
  final int count;
  final _Width width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final amount = idCountAmount(count);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IdCountRing(
          count: count,
          radius: 9,
          strokeWidth: width.of(amount),
          // 太さが変わっても箱の外寸を揃える（並べて比べるため）。
          padding: _ringPad + _ringWidth - width.of(amount),
          child: IdIcon(id: id, size: _iconSize),
        ),
        const SizedBox(height: 2),
        if (count > 1)
          Text(
            '1/$count',
            style: TextStyle(
              fontSize: 9,
              height: 1,
              // 輪と数は同じことを言っているので、濃さも揃える。
              color: emphasisText(scheme, amount),
              fontWeight: emphasisWeight(amount),
            ),
          ),
      ],
    );
  }
}

/// 並べる連投数。**2〜6 のあたりが実際にいちばん多い**ので厚めに取る。
const _counts = [1, 2, 3, 4, 6, 8, 12, 24, 40];

// ---------------------------------------------------------------------------
// 勢い（ミニバー）
// ---------------------------------------------------------------------------

/// 棒の長さ。`thread_tile.dart` の `_Momentum` と同じ。
const _barWidth = 34.0;

/// 一覧の 1 行ぶん。本体（`thread_tile.dart`）と同じ組み方を写したもの。
class _HotSample extends StatelessWidget {
  const _HotSample({
    required this.title,
    required this.perDay,
    required this.resCount,
  });

  final String title;
  final double perDay;
  final int resCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = scheme.onSurfaceVariant;
    final amount = momentumAmount(perDay);
    // 数字も棒も、他のメタと同じ薄さで固定（強調しない）。
    final color = meta;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            style: TextStyle(fontSize: 11, color: meta),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 13, color: color),
                        const SizedBox(width: 3),
                        Text(
                          formatCompact(perDay),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Stack(
                      children: [
                        Container(
                          width: _barWidth,
                          height: 2,
                          color: emphasisTrack(scheme),
                        ),
                        Container(
                          width: _barWidth * amount,
                          height: 2,
                          color: color,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Icon(Icons.forum_outlined, size: 13, color: meta),
                const SizedBox(width: 3),
                Text(
                  formatCompact(resCount),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                const Text('9ヶ月前'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 並べるスレ。**実測（2026-08-15 の liveedge、94 スレ）の分位点**をそのまま
/// 使う。作り物の数字だと「実際の一覧でどう見えるか」が分からないため。
const _threads = [
  ('最速のスレ（実測の最大）', 95212.0, 534),
  ('上位 5% のスレ', 36784.0, 360),
  ('上位 10% のスレ', 6654.0, 213),
  ('上位 25% のスレ', 3754.0, 420),
  ('中央値のスレ', 1721.0, 317),
  ('上位 75% のスレ', 1155.0, 604),
  ('上位 90% のスレ', 651.0, 120),
  ('いちばん遅いスレ（実測の最小）', 202.0, 41),
];

// ---------------------------------------------------------------------------
// 撮る枠
// ---------------------------------------------------------------------------

const _gap = 16.0;
const _captionHeight = 26.0;

/// 見本の表を 1 枚に撮る。列が案、行が数。
Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  required List<String> columnLabels,
  required List<String> rowLabels,
  required Widget Function(int column, int row) cell,
  required double columnWidth,
  required double rowHeight,
  double rowLabelWidth = 64,
}) async {
  final width = rowLabelWidth + columnWidth * columnLabels.length + _gap * 2;
  final height = _captionHeight + rowHeight * rowLabels.length + _gap * 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final scheme = theme.colorScheme;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: Material(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(_gap),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontFamily: japaneseTestFontFamily),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: _captionHeight,
                    child: Row(
                      children: [
                        SizedBox(width: rowLabelWidth),
                        for (final label in columnLabels)
                          SizedBox(
                            width: columnWidth,
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  for (var row = 0; row < rowLabels.length; row++)
                    SizedBox(
                      height: rowHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: rowLabelWidth,
                            child: Text(
                              rowLabels[row],
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          for (
                            var column = 0;
                            column < columnLabels.length;
                            column++
                          )
                            SizedBox(
                              width: columnWidth,
                              child: cell(column, row),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  // 画像化はエンジン側の実際の非同期処理なので、fake async のゾーンの外へ出す。
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

  Future<void> shootRings(WidgetTester tester, ThemeData theme, String out) =>
      _shoot(
        tester,
        theme,
        out,
        columnLabels: [for (final w in _Width.values) w.label],
        rowLabels: [for (final c in _counts) c == 1 ? '単発' : '$c 件'],
        columnWidth: 120,
        rowHeight: 58,
        cell: (column, row) => Align(
          alignment: Alignment.centerLeft,
          child: _RingSample(
            // 絵は全部同じ ID にする（形の違いに気を取られないように）。
            id: 'Kd8mN2pLr',
            count: _counts[row],
            width: _Width.values[column],
          ),
        ),
      );

  testWidgets('rings light', (tester) async {
    await shootRings(tester, ElecTheme.light(), '$dir/id_ring_light.png');
  });

  testWidgets('rings dark', (tester) async {
    await shootRings(tester, ElecTheme.dark(), '$dir/id_ring_dark.png');
  });

  Future<void> shootMomentum(WidgetTester tester, ThemeData theme, String out) =>
      _shoot(
        tester,
        theme,
        out,
        columnLabels: const ['勢い（採用）'],
        rowLabels: [
          for (final t in _threads)
            t.$2 >= 1 ? '${t.$2.toStringAsFixed(0)} /日' : '${t.$2} /日',
        ],
        columnWidth: 300,
        rowHeight: 66,
        rowLabelWidth: 72,
        cell: (column, row) {
          final (title, perDay, resCount) = _threads[row];
          return _HotSample(title: title, perDay: perDay, resCount: resCount);
        },
      );

  testWidgets('momentum light', (tester) async {
    await shootMomentum(tester, ElecTheme.light(), '$dir/id_ring_momentum.png');
  });

  testWidgets('momentum dark', (tester) async {
    await shootMomentum(
      tester,
      ElecTheme.dark(),
      '$dir/id_ring_momentum_dark.png',
    );
  });
}
