/// **レスとレスの間に線を引く**案を撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/res_divider_preview.dart
/// ```
///
/// 出力は `notes/preview/res_divider_*.png`。`OUT` で出力先を変えられる。
///
/// 並べるのは本体の [PostItem] そのもので、区切りの入れ方だけをこの枠が変える。
/// アプリ本体（`lib/`）は触っていない——採る形が決まってから入れる。
///
/// ## 何を比べているか
/// 今は「レス間は線を引かず、余白だけで区切る」（`thread_screen.dart` の一覧を
/// 組むところにその方針が書いてある）。根拠は、ID の絵と番号・名前の見出し行が
/// レスの始点の目印になるから。
///
/// ただし実際の板でいちばん多いのは**名無し・1 行・返信なし**のレスで、そこでは
/// 見出しに出るものが少ない。上下 6dp ずつ＝**レス間 12dp** の余白しか手掛かりが
/// なく、本文の行間（15px × 1.4 ≒ 21dp）とそれほど離れていない。「どこまでが
/// 1 人の発言か」が読み取りにくい、という指摘はここから来ているはず。
///
/// 比べる 4 つ:
///   1. **なし**（今）
///   2. **薄い線**——テーマ既定の [Divider]（`outlineVariant` の 40%）。
///   3. **はっきりした線**——`outlineVariant` をそのまま。
///   4. **内寄せの線**——本文の始まる位置から引く。柱の組み方では ID の絵の
///      右端（16+24+10=50dp）、ヘッダの組み方では左余白（16dp）に合わせる。
///
/// 別口として、線を引かずに**交互の帯**（1 件おきに背景を変える）でも同じ問題は
/// 解ける。線より賑やかにならないので、こちらも 1 枚撮る。
///
/// 見るところは 3 つ:
///   - 1 行のレスが続くところで、切れ目が読めるようになるか。
///   - 自分宛（左に帯＋薄い塗り）や自分のレス（塗り）と、線がぶつからないか。
///   - 画像やリンクのカードで終わるレスの下で、線が窮屈にならないか。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 見本のレス
// ---------------------------------------------------------------------------

/// 見本 1 件。[PostItem] に渡すものを、この枠で必要なぶんだけ持つ。
class _Sample {
  const _Sample({
    required this.number,
    required this.id,
    required this.body,
    this.name = '',
    this.idCount = 1,
    this.idOrdinal = 1,
    this.replyCount = 0,
    this.isOwn = false,
    this.isReplyToOwn = false,
  });

  final int number;
  final String id;
  final String body;
  final String name;
  final int idCount;
  final int idOrdinal;
  final int replyCount;
  final bool isOwn;
  final bool isReplyToOwn;

  Res get res => Res(
    number: number,
    name: name.isEmpty ? 'エッヂの名無し' : name,
    mail: '',
    // 相対時刻（「3分前」）に化けると撮るたび文字が変わるので、
    // パースできない形にして `02:14` の固定表示に落とす。
    dateText: '2025/11/03(月) 02:${14 + number ~/ 6}:${number % 60}.907',
    dateTime: null,
    id: id,
    beId: null,
    body: body,
    kind: ResKind.normal,
    threadTitle: null,
  );
}

/// 実際の板でいちばん多い形に寄せた並び。**名無し・1 行・返信なし**を主にして、
/// 途中に目印のあるレス（コテハン・返信数・自分宛・連投・複数行）を混ぜる。
/// 線が要るかどうかは、この「何も無いレスが続くところ」で決まる。
const _samples = [
  _Sample(number: 41, id: 'aB3xYz9Qw', body: 'まんげいらない'),
  _Sample(number: 42, id: 'Kd8mN2pLr', body: 'コンドミほんま人妻やな'),
  _Sample(number: 43, id: 'Qw7vT4sZx', body: 'これブラジルミクだろ<br>いや違うか'),
  _Sample(number: 44, id: 'Hj5cB1nMe', body: '機械のくせに恥じらうなよ', replyCount: 4),
  _Sample(
    number: 45,
    id: 'Kd8mN2pLr',
    body: '>>44 それはそう',
    idCount: 3,
    idOrdinal: 2,
  ),
  _Sample(number: 46, id: 'Tz2qW8eRv', body: '近藤さんの性癖'),
  _Sample(
    number: 47,
    id: 'Ln4kP6yHu',
    name: 'ながい名前のコテハン◆Ab12Cd34Ef',
    body: '何年前のAIだよ。もう少し新しいのを持ってきてほしいところではある',
  ),
  _Sample(number: 48, id: 'Mx9dF3gTb', body: '扉に謎の蝶番ついてる', isOwn: true),
  _Sample(
    number: 49,
    id: 'Rc5jV7bNq',
    body: '>>48 言われてみれば確かに',
    isReplyToOwn: true,
  ),
  _Sample(number: 50, id: 'Kd8mN2pLr', body: 'ここ好き', idCount: 3, idOrdinal: 3),
  _Sample(number: 51, id: 'Ws6hG2mXd', body: 'そろそろ寝る'),
  _Sample(number: 52, id: 'Yb1nL9tKp', body: 'おつ'),
  _Sample(number: 53, id: 'Ff7rQ4wZc', body: '起きたらまた見るわ。今日のはだいぶ良かったと思う'),
  _Sample(number: 54, id: 'Ud3sA8vJh', body: 'まだ終わってないが'),
];

// ---------------------------------------------------------------------------
// 区切りの入れ方
// ---------------------------------------------------------------------------

/// レスとレスの間に何を入れるか。
enum _Sep {
  /// 今のまま。余白だけ。
  none('なし（今）'),

  /// テーマ既定の [Divider]（`outlineVariant` の 40%）。
  hairline('薄い線'),

  /// `outlineVariant` をそのまま引く。
  solid('はっきりした線'),

  /// 本文の始まる位置から引く。
  inset('内寄せの線'),

  /// 線ではなく、1 件おきに背景を変える。
  zebra('交互の帯'),

  /// 両端が地の色へ抜けるグラデーションの線。
  fade('端が抜ける線'),

  /// 線の下に淡い影を 3px 敷く。上のレスが手前にある感じを出す。
  shade('線＋影'),

  /// 線の下に地より明るい 1px を重ねる（彫り込み）。
  emboss('彫り込み'),

  /// 線を引かず、影だけで段を作る。
  shadowOnly('影だけ'),

  /// 線を引かず、**レスの間だけ余白を広げる**。近いものは同じレス、離れて
  /// いれば別のレス、という近接だけで切る。
  space('余白だけ・広め'),

  /// 各レスを丸角の面に載せ、面と面の隙間で切る。線も縦の筋も出ない。
  tile('丸角タイル'),

  /// [tile] の密な版。隙間と角を詰めて、1 画面に入る数を保つ。
  tileTight('丸角タイル・密');

  const _Sep(this.label);
  final String label;
}

/// 区切りの色（テーマ既定の [Divider] と同じ）。
Color _lineColor(ColorScheme scheme) =>
    scheme.outlineVariant.withValues(alpha: 0.4);

/// 影の濃さ。暗いテーマでは黒を重ねても沈むだけなので、少し強めに敷く。
Color _shadeColor(ColorScheme scheme) => Colors.black.withValues(
  alpha: scheme.brightness == Brightness.dark ? 0.22 : 0.05,
);

/// 上から下へ抜ける影。レスの上端に敷いて「手前の紙の影」に見せる。
Widget _shade(ColorScheme scheme, {double height = 3}) => Container(
  height: height,
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_shadeColor(scheme), Colors.transparent],
    ),
  ),
);

/// [ResLayout.gutter] で本文が始まる x。ID の柱（24）＋間（10）＋左余白（16）。
const _gutterBodyLeft = 50.0;

/// [ResLayout.header] で中身が始まる x（レスの左余白）。
const _headerBodyLeft = 16.0;

/// 見本を 1 列に積む。[sep] のとおりに区切りを入れる。
Widget _column(_Sep sep, ResLayout layout, ColorScheme scheme) {
  final rows = <Widget>[];
  for (var i = 0; i < _samples.length; i++) {
    final s = _samples[i];
    if (i > 0) {
      rows.add(switch (sep) {
        _Sep.none || _Sep.zebra => const SizedBox.shrink(),
        _Sep.hairline => const Divider(height: 1),
        _Sep.solid => Divider(height: 1, color: scheme.outlineVariant),
        // 右端も同じだけ空ける。ヘッダの組み方は中身が左余白（16）から始まる
        // ので、左だけ空けても全幅とほとんど区別が付かない。
        _Sep.inset => Divider(
          height: 1,
          indent: layout == ResLayout.gutter
              ? _gutterBodyLeft
              : _headerBodyLeft,
          endIndent: _headerBodyLeft,
        ),
        // 端を地の色へ溶かす。真横に走りきる 1 本より柔らかく見える。
        _Sep.fade => Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                _lineColor(scheme),
                _lineColor(scheme),
                Colors.transparent,
              ],
              stops: const [0, 0.1, 0.9, 1],
            ),
          ),
        ),
        _Sep.shade => Column(
          mainAxisSize: MainAxisSize.min,
          children: [const Divider(height: 1), _shade(scheme)],
        ),
        // 彫り込み。線の下に**地より明るい** 1px を置くと、境目が窪んで見える。
        _Sep.emboss => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Container(
              height: 1,
              color: Colors.white.withValues(
                alpha: scheme.brightness == Brightness.dark ? 0.05 : 0.9,
              ),
            ),
          ],
        ),
        _Sep.shadowOnly => _shade(scheme, height: 4),
        // 近接だけで切る。レス内の行間（約 21）より外を広げるのが狙いなので、
        // 今の 12（上下 6 ずつ）へ足して 20 にする。
        _Sep.space => const SizedBox(height: 8),
        // 面の隙間が切れ目になるので、行と行の間には何も入れない。
        _Sep.tile || _Sep.tileTight => const SizedBox.shrink(),
      });
    }
    final post = PostItem(
      res: s.res,
      idCount: s.idCount,
      idOrdinal: s.idOrdinal,
      onTapId: (_) {},
      resLayout: layout,
      replyCount: s.replyCount,
      isOwn: s.isOwn,
      isReplyToOwn: s.isReplyToOwn,
      // 名無しの名前が省かれる（実際の一覧と同じ状態にする）。
      defaultName: 'エッヂの名無し',
    );
    // 丸角タイル。地よりわずかに明るい（暗いテーマでは明るい側の）面に載せ、
    // 上下の隙間で切る。**縁も影も付けない**——線を減らすのが目的なので、
    // 面と地の差だけで浮かせる。
    if (sep == _Sep.tile || sep == _Sep.tileTight) {
      final tight = sep == _Sep.tileTight;
      rows.add(
        Container(
          margin: EdgeInsets.symmetric(
            horizontal: tight ? 6 : 8,
            vertical: tight ? 1.5 : 3,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(tight ? 10 : 14),
          ),
          clipBehavior: Clip.antiAlias,
          child: post,
        ),
      );
      continue;
    }
    rows.add(
      sep == _Sep.zebra && i.isOdd
          // 帯は薄く。塗りを持つレス（自分・自分宛）の下に敷いても、
          // そちらの色が沈まない濃さに留める。**明るいテーマでは
          // surfaceContainerLow だと地の色との差がほとんど出ない**ので、
          // 一段濃い surfaceContainer で撮る（判断できる濃さにする）。
          ? ColoredBox(color: scheme.surfaceContainer, child: post)
          : post,
    );
  }
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
}

// ---------------------------------------------------------------------------
// 撮る枠
// ---------------------------------------------------------------------------

const _columnWidth = 340.0;
const _captionHeight = 30.0;

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  required List<_Sep> seps,
  ResLayout layout = ResLayout.header,
  double height = 780,
}) async {
  final width = _columnWidth * seps.length + 12 * (seps.length + 1);
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
        // [PostItem] の中の InkWell が Material の子であることを求める。
        child: Material(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final sep in seps) ...[
                  SizedBox(
                    width: _columnWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: _captionHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Text(
                                sep.label,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 見本は画面の高さに収まらない分を切って見せる（下端が
                        // 途中で切れるのは、実際にスクロールしている見え方に近い）。
                        Expanded(
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              maxHeight: double.infinity,
                              child: _column(sep, layout, scheme),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (sep != seps.last) const SizedBox(width: 12),
                ],
              ],
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

  // 既定の組み方（[ResLayout.header]）で線の有無・濃さ・引き始めを比べる。
  testWidgets('header light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_light.png',
      seps: [_Sep.none, _Sep.hairline, _Sep.solid, _Sep.inset],
    );
  });

  // 暗いところでは線のコントラストの出方が変わる（明るい線は浮いて見える）。
  testWidgets('header dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_divider_dark.png',
      seps: [_Sep.none, _Sep.hairline, _Sep.solid, _Sep.inset],
    );
  });

  // 柱の組み方。ID の絵がすでに切れ目を作っているので、線の効き目が変わるはず。
  testWidgets('gutter light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_gutter_light.png',
      layout: ResLayout.gutter,
      seps: [_Sep.none, _Sep.hairline, _Sep.solid, _Sep.inset],
    );
  });

  // 線を引かない別解。交互の帯と、今／薄い線を並べる。
  testWidgets('zebra light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_zebra_light.png',
      seps: [_Sep.none, _Sep.hairline, _Sep.zebra],
    );
  });

  // 線が機械的に見えないよう、少しだけ立体感を足す案。柱の組み方（線を入れる
  // のはこちらだけ）で、今の線と並べて撮る。
  testWidgets('depth light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_depth_light.png',
      layout: ResLayout.gutter,
      seps: [_Sep.hairline, _Sep.fade, _Sep.shade, _Sep.emboss],
    );
  });

  testWidgets('depth dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_divider_depth_dark.png',
      layout: ResLayout.gutter,
      seps: [_Sep.hairline, _Sep.fade, _Sep.shade, _Sep.emboss],
    );
  });

  // 線を使わずに切る案。「線ばかりで硬い」への当て所はこちら。
  testWidgets('soft light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_soft_light.png',
      layout: ResLayout.gutter,
      seps: [_Sep.hairline, _Sep.space, _Sep.tile, _Sep.tileTight],
    );
  });

  testWidgets('soft dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_divider_soft_dark.png',
      layout: ResLayout.gutter,
      seps: [_Sep.hairline, _Sep.space, _Sep.tile, _Sep.tileTight],
    );
  });

  // 線そのものを外して、影の段だけで区切る案。
  testWidgets('shadow only', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_divider_shadow_light.png',
      layout: ResLayout.gutter,
      seps: [_Sep.hairline, _Sep.shadowOnly, _Sep.shade],
    );
  });

  testWidgets('zebra dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_divider_zebra_dark.png',
      seps: [_Sep.none, _Sep.hairline, _Sep.zebra],
    );
  });
}
