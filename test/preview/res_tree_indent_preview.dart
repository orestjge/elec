/// ツリーの字下げを**縦帯で表すのをやめる**案を撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/res_tree_indent_preview.dart
/// ```
///
/// 出力は `notes/preview/res_tree_indent_{light,dark}.png`。`OUT` で変えられる。
///
/// 本体（`lib/`）は触っていない。ここに置いた枠は [ThreadTreeTier] の見た目を
/// 真似た使い捨てで、帯を描くかどうかだけを差し替えている。
///
/// ## 何を比べているか
/// レス間に線を引いてみたところ、きつく見えるのは**横線そのものではなく**、
/// 返信がぶら下がって字下げが増えるところだった。字下げを縦帯（左の細い線）で
/// 表しているので、深さごとに**位置のズレた縦線が何本も並び**、そこへ横線が
/// 交わって格子になる。
///
/// なので比べるのは、字下げの見せ方と横線の引き方の組み合わせ:
///   1. **今**——縦帯あり。横線は上下の浅いほうの深さに合わせて内寄せ。
///   2. **帯なし**——字下げは余白だけ（＝縦線ゼロ）。横線は今と同じく内寄せ。
///   3. **帯なし＋横線は全幅**——横線の始まる x も揃えて、階段状のズレを消す。
///
/// 中身の x 位置は 3 つとも同じにしてある（帯の太さ 2＋間 2 のぶんを、帯を
/// 描かない列では余白で埋める）。変わるのは線が出るか出ないかだけ。
///
/// なお**自分宛のレスの左に出るアクセント帯は別物**（そのレスだけに付く目印）
/// なので、どの案でも残る。常時出る「深さの筋」だけを問題にしている。
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

/// 見本 1 件。深さ付き。
class _Row {
  const _Row(
    this.number,
    this.depth,
    this.id,
    this.body, {
    this.replyCount = 0,
    this.isReplyToOwn = false,
  });

  final int number;
  final int depth;
  final String id;
  final String body;
  final int replyCount;
  final bool isReplyToOwn;

  Res get res => Res(
    number: number,
    name: 'エッヂの名無し',
    mail: '',
    // 相対時刻に化けないよう、パースできない形にして `02:14` 表示に落とす。
    dateText: '2025/11/03(月) 02:${14 + number ~/ 6}:${number % 60}.907',
    dateTime: null,
    id: id,
    beId: null,
    body: body,
    kind: ResKind.normal,
    threadTitle: null,
  );
}

/// 字下げが行ったり来たりする並び。**深さのズレがいちばん目に付く形**——
/// 根・1 段・2 段が混ざり、間に返信の無いレスも挟まる——にしてある。
const _rows = [
  _Row(41, 0, 'aB3xYz9Qw', 'この番組もう10年やってるらしい', replyCount: 3),
  _Row(42, 1, 'Kd8mN2pLr', '>>41 まじか'),
  _Row(43, 1, 'Qw7vT4sZx', '>>41 もっとやってるだろ', replyCount: 2),
  _Row(44, 2, 'Hj5cB1nMe', '>>43 初回は覚えてないわ'),
  _Row(45, 2, 'Tz2qW8eRv', '>>43 それはさすがに盛りすぎ'),
  _Row(46, 1, 'Ln4kP6yHu', '>>41 スタッフだけ入れ替わってる'),
  _Row(47, 0, 'Mx9dF3gTb', '近藤さんの性癖'),
  _Row(48, 0, 'Rc5jV7bNq', 'これブラジルミクだろ', replyCount: 1),
  _Row(49, 1, 'Ws6hG2mXd', '>>48 言われてみれば確かに', isReplyToOwn: true),
  _Row(50, 0, 'Yb1nL9tKp', 'まんげいらない'),
  _Row(51, 1, 'Ff7rQ4wZc', '>>50 それな'),
  _Row(52, 2, 'Ud3sA8vJh', '>>51 わかる'),
  _Row(53, 0, 'Pn8xC3vBm', 'そろそろ寝る'),
];

// ---------------------------------------------------------------------------
// 字下げの見せ方
// ---------------------------------------------------------------------------

/// 比べる案。
enum _Style {
  /// 今。縦帯で字下げを表し、横線は浅いほうの深さに合わせて内寄せ。
  band('今（縦帯あり）'),

  /// 縦帯をやめて余白だけにする。横線は今と同じ内寄せ（画面端から引く）。
  plain('帯なし・端から'),

  /// 横線をレスの左余白（16）から引く。字下げぶんはさらに右へずれる。
  inset16('帯なし・マージン16', lineMargin: 16),

  /// 横線を本文の頭（ID の柱の右、50）から引く。柱を跨がない。
  insetBody('帯なし・本文の頭から', lineMargin: 50),

  /// 縦帯をやめ、横線の始まりも全部そろえる。
  flush('帯なし＋横線は全幅'),

  /// 線を一切引かず、各レスを丸角の面に載せる。字下げは面の左マージンで表す。
  tile('丸角タイル'),

  /// [tile] の密な版。隙間と角を詰める。
  tileTight('丸角タイル・密');

  const _Style(this.label, {this.lineMargin = 0});
  final String label;

  /// 横線の始まり（と終わり）に空ける余白。0 なら画面端から端まで。
  final double lineMargin;
}

/// [ThreadTreeTier] と同じ数値。1 段あたりの字下げと、深さの上限。
const _indentStep = 14.0;
const _maxIndentLevels = 6;

/// 帯（2）＋帯と中身の間（2）。帯を描かない案では、同じだけ余白で埋めて
/// 中身の x を揃える。
const _barAndGap = 4.0;

double _indentOf(int depth) => depth <= 0
    ? 0
    : (depth < _maxIndentLevels ? depth : _maxIndentLevels) * _indentStep;

/// タイル案か。
bool _isTile(_Style style) => style == _Style.tile || style == _Style.tileTight;

/// 字下げを巻く。[_Style.band] だけ縦帯を描く。
Widget _tier(_Style style, int depth, Widget child, ColorScheme scheme) {
  if (depth <= 0) return child;
  final indent = _indentOf(depth);
  if (style != _Style.band) {
    return Padding(
      padding: EdgeInsets.only(left: indent + _barAndGap),
      child: child,
    );
  }
  return Padding(
    padding: EdgeInsets.only(left: indent),
    child: Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.8),
            width: 2,
          ),
        ),
      ),
      child: Padding(padding: const EdgeInsets.only(left: 2), child: child),
    ),
  );
}

/// タイル 1 枚。字下げは**左マージン**で表す（縦帯も横線も出ない）。
Widget _tile(_Style style, int depth, Widget child, ColorScheme scheme) {
  final tight = style == _Style.tileTight;
  final base = tight ? 6.0 : 8.0;
  return Container(
    margin: EdgeInsets.only(
      left: base + _indentOf(depth),
      right: base,
      top: tight ? 1.5 : 3,
      bottom: tight ? 1.5 : 3,
    ),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(tight ? 10 : 14),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// 見本を 1 列に積む。
Widget _column(_Style style, ColorScheme scheme) {
  final children = <Widget>[];
  for (var i = 0; i < _rows.length; i++) {
    final row = _rows[i];
    if (i > 0 && !_isTile(style)) {
      // 横線の深さは上下の浅いほう（本体の `resDividerDepth` と同じ規則）。
      final depth = row.depth < _rows[i - 1].depth
          ? row.depth
          : _rows[i - 1].depth;
      children.add(switch (style) {
        _Style.flush => const Divider(height: 1),
        // マージン付きは [Divider] 自身に持たせる（帯を巻かないので、字下げも
        // ここで足す）。左右に同じだけ空けて、線を画面端から浮かせる。
        _ when style.lineMargin > 0 => Divider(
          height: 1,
          indent: style.lineMargin + _indentOf(depth),
          endIndent: style.lineMargin,
        ),
        _ => _tier(style, depth, const Divider(height: 1), scheme),
      });
    }
    final post = PostItem(
      res: row.res,
      nested: row.depth > 0,
      idCount: 1,
      idOrdinal: 1,
      onTapId: (_) {},
      resLayout: ResLayout.gutter,
      replyCount: row.replyCount,
      isReplyToOwn: row.isReplyToOwn,
      defaultName: 'エッヂの名無し',
    );
    children.add(
      _isTile(style)
          ? _tile(style, row.depth, post, scheme)
          : _tier(style, row.depth, post, scheme),
    );
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

// ---------------------------------------------------------------------------
// 撮る枠
// ---------------------------------------------------------------------------

const _columnWidth = 360.0;
const _captionHeight = 30.0;

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  required List<_Style> styles,
  double height = 800,
}) async {
  final width = _columnWidth * styles.length + 12 * (styles.length + 1);
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final scheme = theme.colorScheme;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      // [PostItem] の中の InkWell が Material の子であることを求める。
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: Material(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final style in styles) ...[
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
                                style.label,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              maxHeight: double.infinity,
                              child: _column(style, scheme),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (style != styles.last) const SizedBox(width: 12),
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

  setUpAll(loadPreviewFonts);

  const structure = [
    _Style.band,
    _Style.plain,
    _Style.flush,
    _Style.tile,
    _Style.tileTight,
  ];

  // 字下げの見せ方そのものを比べる。
  testWidgets('light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_tree_indent_light.png',
      styles: structure,
    );
  });

  testWidgets('dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_tree_indent_dark.png',
      styles: structure,
    );
  });

  // 縦帯なし・横線ありに絞って、**線をどこから引き始めるか**を比べる。
  const margins = [_Style.band, _Style.plain, _Style.inset16, _Style.insetBody];

  testWidgets('margin light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/res_tree_line_margin_light.png',
      styles: margins,
    );
  });

  testWidgets('margin dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/res_tree_line_margin_dark.png',
      styles: margins,
    );
  });
}
