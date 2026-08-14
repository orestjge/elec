/// スレ一覧で**盛り上がっているスレをどう示すか**の案を並べて撮る、検討用
/// スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/popularity_preview.dart
/// ```
///
/// 出力は `notes/preview/popularity_*.png`。`OUT` で出力先を変えられる。
/// アプリ本体（`lib/`）は触っていない——採る形が決まってから入れる。
///
/// ## 何が問題か
/// 勢い（レス/日）は経過時間で割るだけなので、**立ったばかりのスレを過大に
/// 見積もる**。実測（2026-08-15 の liveedge）でも、
///
///   - 8 レス / 16 分 → 743 レス/日（中央値 1721 の半分。もう「そこそこ速い」）
///   - 1 レス / 11 分 → 126 レス/日
///
/// のように、**まだ何も起きていないスレが中位に混ざる**。並べ替えの鍵として
/// 上に出るぶんには構わない（新しいスレを見つけられる）が、「盛り上がっている」
/// の合図としては嘘になる。
///
/// ## 案
///   1. **勢いだけ**——勢いを棒と濃さで見せる。若いスレも同じ強さで出る。
///   2. **人気度**——勢いに**レス数の信頼度**（100 レスで頭打ち）を掛けたものを
///      同じ棒で見せる。立ったばかりのスレは棒が伸びない。表示物は増えない。
///   3. **人気度＋印**——2 に加えて、いちばん上の段のスレにだけ小さな印を出す。
///   4. **数字だけ＋印**——棒と濃淡をやめ、勢いは素の数字に戻して、印だけで
///      盛り上がりを示す。行はいちばん静かになる。
///
/// ## 結論：どれも採らなかった
/// 一覧の行が**ごちゃつく**のと、**濃淡がタイトル側と競合する**（既読／未読で
/// タイトルの濃さを動かしている）ため。落ち着いた先は「勢いはレス数と同じ薄さの
/// 数字＋色を動かさない細い棒」で、盛り上がりを強調する仕掛けそのものを置かない
/// ——一覧は探す画面であって、順位を主張する画面ではない。
///
/// 若いスレの過大評価は残るが、**並べ替えの鍵としては正しい**（新しく立った
/// スレを見つけられる）ので、表示を静かにすることで折り合いを付けた。
///
/// 見本は**実測のスレをそのまま**使う（レス数と経過時間の組が本物でないと、
/// 若いスレの混ざり方が再現できない）。
///
/// 見るところ:
///   - 8 レス / 16 分のスレが、盛り上がっているスレと**区別できているか**。
///   - 一覧を流し見して、本物の祭りが**視線で拾えるか**。
///   - 印を足したぶん、行が賑やかになりすぎていないか。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:elec/src/ui/emphasis.dart';
import 'package:elec/src/ui/format.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 見本（実測）
// ---------------------------------------------------------------------------

/// 2026-08-15 の liveedge から採ったスレ。タイトル・レス数・経過時間。
/// 勢いはここから計算する（`momentumPerDay` と同じ割り算）。
const _threads = [
  ('【BS14】乙女怪獣キャラメリゼ', 534, 0.30),
  ('【MX】うちの弟どもがすみません→ジョジョ6部', 747, 1.13),
  ('夜の投資部投機部 ★3', 875, 2.14),
  ('35歳独身ワイ、結婚を半ば諦めてて泣きそうになる', 416, 1.69),
  ('なんエヂ台風一家の精神疾患障害者部', 124, 1.52),
  ('逆にさ？ロングスリーパーっていたら流行りそうじゃね？', 8, 0.27),
  ('ワイ、マッマのChatGPT Plusの支払いをする', 7, 0.25),
  ('【BS11】文豪ストレイドッグス わん！', 2, 0.26),
  ('牛「この子わたしにくださいな！」←欲しそうな顔', 1, 0.19),
];

double _perDay(int resCount, double hours) =>
    resCount / math.max(hours / 24, 1 / 1440);

/// レス数の信頼度。**[_reliableRes] レス積んで初めて満点**。
///
/// 勢いは「これまでの平均速度」でしかないので、レスが数件しかないスレの値は
/// たまたま連投が続いただけかもしれない。積み上がった数を確からしさとして掛け、
/// **まだ分からないスレは静かにしておく**。
double _confidence(int resCount) => math.min(1, resCount / _reliableRes);

const _reliableRes = 100;

/// 「盛り上がっている度合い」。勢いの量に信頼度を掛けたもの。
double _popularity(int resCount, double hours) =>
    momentumAmount(_perDay(resCount, hours)) * _confidence(resCount);

// ---------------------------------------------------------------------------
// 案
// ---------------------------------------------------------------------------

enum _Style {
  momentum('今（勢いだけ）'),
  popularity('人気度'),
  popularityMark('人気度＋印'),
  markOnly('数字だけ＋印');

  const _Style(this.label);
  final String label;
}

/// 棒の長さ。`thread_tile.dart` の `_Momentum` と同じ。
const _barWidth = 34.0;

/// 一覧の 1 行ぶん。勢いのところだけを [style] が差し替える。
class _Row extends StatelessWidget {
  const _Row({
    required this.style,
    required this.title,
    required this.resCount,
    required this.hours,
  });

  final _Style style;
  final String title;
  final int resCount;
  final double hours;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = scheme.onSurfaceVariant;
    final perDay = _perDay(resCount, hours);
    // 棒と濃さが表す量。案によって「勢い」か「人気度」かが変わる。
    final amount = switch (style) {
      _Style.momentum => momentumAmount(perDay),
      _ => _popularity(resCount, hours),
    };
    // 印を出すのは、いちばん上の段（＝実測 94 スレ中 1 本だけ）。
    final marked =
        style != _Style.momentum &&
        style != _Style.popularity &&
        quantizeAmount(_popularity(resCount, hours)) >= 1;
    final showBar = style != _Style.markOnly;
    final color = showBar ? emphasisText(scheme, amount) : meta;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (marked) ...[const SizedBox(width: 6), _Mark()],
            ],
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
                            fontWeight: showBar
                                ? emphasisWeight(amount)
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (showBar) ...[
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
                            color: emphasisFill(scheme, amount),
                          ),
                        ],
                      ),
                    ],
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
                Text('${hours.toStringAsFixed(1)}時間前'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 盛り上がっているスレの印。**色は使わない**（無彩テーマなので）。地を反転
/// させた小さな札にして、行の中で 1 つだけ強い面にする。
class _Mark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.onSurface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: 11, color: scheme.surface),
          const SizedBox(width: 2),
          Text(
            '人気',
            style: TextStyle(
              fontSize: 10,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: scheme.surface,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 撮る枠
// ---------------------------------------------------------------------------

const _gap = 16.0;
const _captionHeight = 26.0;
const _columnWidth = 330.0;
const _rowHeight = 64.0;

Future<void> _shoot(WidgetTester tester, ThemeData theme, String out) async {
  const width = _columnWidth * 4 + _gap * 2;
  final height = _captionHeight + _rowHeight * _threads.length + _gap * 2;
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final style in _Style.values)
                    SizedBox(
                      width: _columnWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: _captionHeight,
                            child: Text(
                              style.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          for (final (title, res, hours) in _threads)
                            SizedBox(
                              height: _rowHeight,
                              child: _Row(
                                style: style,
                                title: title,
                                resCount: res,
                                hours: hours,
                              ),
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

  testWidgets('light', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/popularity_light.png');
  });

  testWidgets('dark', (tester) async {
    await _shoot(tester, ElecTheme.dark(), '$dir/popularity_dark.png');
  });
}
