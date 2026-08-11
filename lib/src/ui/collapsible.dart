/// 長いレスを途中で畳み、「続きを読む」で伸ばす。
///
/// レス 1 つが画面を丸ごと埋めることがある。長文と、画像を何枚も貼ったレス。
/// どちらもスレを追う邪魔になるが、**中身を削る（行数で切る・サムネイルを
/// 小さくする）のではなく、畳んで開けるようにする**方が素直——読みたい人は
/// 開けばよく、飛ばしたい人は次のレスがすぐ来る。
///
/// ついでに効くことが 1 つある。畳んでいる間の高さは上限で頭打ちなので、
/// **中でサムネイルが読み込まれて伸びても外の高さは変わらない**（`post_images.
/// dart` の [thumbBox] が比率を知った瞬間に起きる組み直しが、下のレスへ波及
/// しない）。長いレスに関しては、読み込みによる位置ずれが丸ごと無くなる。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// レスを畳む高さ。端末の画面のおよそ 3/4。
///
/// これより短くすると、ふつうの長さのレスまで畳まれて「続きを読む」だらけに
/// なる。長くすると畳む意味が薄れる。
const double collapsedPostMaxHeight = 560;

/// 畳まれた本文の下に敷く階調の高さ。
const double _fadeHeight = 40;

/// 「続きを読む」の帯の高さ。指の的の下限に合わせる。
const double _footerHeight = 48;

/// 中身が [maxHeight] を超えたら、そこで切る。
///
/// **高さは中身を組んでみるまで分からない**ので、ふつうのウィジェットの組み方
/// では「畳めるかどうか」が決められない。ここは自前で測る——子には高さの制約を
/// 渡さずに組ませ、本来の高さを [onMeasured] で知らせたうえで、自分の高さだけ
/// [maxHeight] で頭打ちにする。
///
/// **頭打ちは最初の組み立てから効く**（測った結果を待たない）ので、一瞬だけ
/// 伸びきった姿が出てから縮む、ということは起きない。[onMeasured] が効くのは
/// 「続きを読む」を出すかどうかだけで、そちらは 1 フレーム遅れて現れる。
class Collapsible extends SingleChildRenderObjectWidget {
  const Collapsible({
    super.key,
    required this.maxHeight,
    required this.onMeasured,
    required Widget super.child,
  });

  /// 畳む高さ。[double.infinity] を渡せば畳まない。
  final double maxHeight;

  /// 組んでみた結果の**本来の高さ**。組み立ての最中には呼ばれない
  /// （フレームの切れ目まで遅らせる）。
  final ValueChanged<double> onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCollapsible(maxHeight: maxHeight, onMeasured: onMeasured);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as RenderCollapsible)
      ..maxHeight = maxHeight
      ..onMeasured = onMeasured;
  }
}

class RenderCollapsible extends RenderProxyBox {
  RenderCollapsible({required double maxHeight, required this.onMeasured})
    : _maxHeight = maxHeight;

  double _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  ValueChanged<double> onMeasured;

  /// 直前に知らせた高さ。同じ値を繰り返し知らせて組み直しを誘わないため。
  double? _reported;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // 高さは縛らずに組ませる。縛ると中身が上限に合わせて自分を縮めてしまい、
    // 「本来どれだけ高いか」が分からなくなる。
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
      ),
      parentUsesSize: true,
    );
    final natural = child.size.height;
    size = constraints.constrain(
      Size(child.size.width, math.min(natural, _maxHeight)),
    );
    if (_reported == natural) return;
    _reported = natural;
    final report = onMeasured;
    // 組み立ての最中に外へ知らせると、そのフレームで作り直しに入って怒られる。
    SchedulerBinding.instance.addPostFrameCallback((_) => report(natural));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // はみ出したぶんは切る。切らないと下のレスに重なって描かれる。
    if (child.size.height <= size.height) {
      context.paintChild(child, offset);
      return;
    }
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset),
    );
  }
}

/// 長いときだけ畳む本文の入れ物。
///
/// 畳むかどうかは中身の高さを測ってから決まるので、**開いているかどうかは外が
/// 持つ**（[expanded] / [onExpand]）。一覧の行は画面外へ出ると捨てられるため、
/// ここで覚えると戻ってきたときに畳み直されてしまう。
class CollapsingBody extends StatefulWidget {
  const CollapsingBody({
    super.key,
    required this.child,
    required this.expanded,
    required this.onExpand,
    this.maxHeight = collapsedPostMaxHeight,
    this.showLineCount = true,
  });

  final Widget child;

  /// 「続きを読む」を押した後か。
  final bool expanded;

  final VoidCallback onExpand;

  final double maxHeight;

  /// 隠した量を「あと◯行ほど」で出すか。**絵や札が隠れているときは false**
  /// ——行数は文章にしか意味が無く、画像 2 枚を「あと 11 行」と言われても
  /// 何のことか分からない。
  final bool showLineCount;

  @override
  State<CollapsingBody> createState() => _CollapsingBodyState();
}

class _CollapsingBodyState extends State<CollapsingBody> {
  /// 中身の本来の高さ。測る前は null（そのあいだ「続きを読む」は出さない）。
  double? _natural;

  /// 隠れているぶんを行に直すときの 1 行の高さ。本文（15px・行高 1.4）の目安で、
  /// 「あと◯行ほど」の**ほど**が引き受ける精度でよい。
  static const double _lineHeight = 21;

  @override
  Widget build(BuildContext context) {
    final natural = _natural;
    // 切った以上は必ず「続きを読む」を出す。**上限を少し超えただけなら畳まない**
    // ——といった手心を加えると、その帯（上限〜上限＋手心）のレスが、ボタンも
    // 出ないまま黙って切れる。頭打ちは測る前から効いているので、切るかどうかを
    // 後から緩めることはできない。
    final collapses =
        !widget.expanded && natural != null && natural > widget.maxHeight;
    return Stack(
      children: [
        Collapsible(
          // 開いていない間は常に頭打ちにする。測り終わるのを待つと、一瞬だけ
          // 伸びきった姿が出てから縮むことになる。
          maxHeight: widget.expanded ? double.infinity : widget.maxHeight,
          onMeasured: (height) {
            if (!mounted || _natural == height) return;
            setState(() => _natural = height);
          },
          child: widget.child,
        ),
        if (collapses)
          _MoreFooter(
            onTap: widget.onExpand,
            label: widget.showLineCount
                ? 'あと${((natural - widget.maxHeight) / _lineHeight).ceil()}行ほど'
                : '続きを読む',
          ),
      ],
    );
  }
}

/// 畳まれた本文の下端に敷く「続きがある」合図。
///
/// ボタンだけでも用は足りるが、**どこで切れたか**が分からないと文章が途中で
/// 消えたように見える。地色へ溶ける階調を掛けて切れ目をぼかす。
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 階調は下端だけ。上まで掛けると本文が読みにくくなる。
          Container(
            height: _fadeHeight,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scheme.surface.withValues(alpha: 0), scheme.surface],
              ),
            ),
          ),
          // **幅いっぱいの帯にする。** 隠れているものを見るためのボタンは、
          // レスの中で一番押される的になる——小さな字の脇を狙わせる理由がない。
          // 高さも指の的の下限（48）に合わせてある。
          ColoredBox(
            color: scheme.surface,
            child: SizedBox(
              width: double.infinity,
              height: _footerHeight,
              child: TextButton.icon(
                onPressed: onTap,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.expand_more, size: 20),
                label: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
