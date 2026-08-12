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

/// レスを畳む高さ。端末の画面のおよそ 3/4。
///
/// これより短くすると、ふつうの長さのレスまで畳まれて「続きを読む」だらけに
/// なる。長くすると畳む意味が薄れる。
const double collapsedPostMaxHeight = 560;

/// 畳まれた本文の下に敷く階調の高さ。
const double _fadeHeight = 40;

/// 「続きを読む」の帯の高さ。指の的の下限に合わせる。
const double _footerHeight = 48;

/// [Collapsible] の子の役どころ。
enum CollapsibleSlot { body, footer }

/// 中身が [maxHeight] を超えたら、そこで切り、下端に [footer] を重ねる。
///
/// **高さは中身を組んでみるまで分からない**ので、ふつうのウィジェットの組み方
/// では「畳めるかどうか」が決められない。ここは自前で測る——子には高さの制約を
/// 渡さずに組ませ、自分の高さだけ [maxHeight] で頭打ちにする。
///
/// **切ったかどうかも同じ組み立て（layout）の中で決める。** 測った高さを状態に
/// 持ち帰って次のフレームで帯を出す、という作りにすると、帯が 1 拍遅れて現れる
/// ——一覧の行は画面外へ出ると捨てられるので、スクロールで戻ってくるたびに測り
/// 直しになり、そのたびに「無い→出る」がちらつく。ここでは [footer] を最初から
/// 子として持っておき、中身を組んだその場で描くか描かないかを決める。
class Collapsible
    extends SlottedMultiChildRenderObjectWidget<CollapsibleSlot, RenderBox> {
  const Collapsible({
    super.key,
    required this.maxHeight,
    required this.child,
    this.footer,
  });

  /// 畳む高さ。[double.infinity] を渡せば畳まない。
  final double maxHeight;

  final Widget child;

  /// 切ったときだけ下端に出すもの。切っていなければ描かれない（触れもしない）。
  final Widget? footer;

  @override
  Iterable<CollapsibleSlot> get slots => CollapsibleSlot.values;

  @override
  Widget? childForSlot(CollapsibleSlot slot) => switch (slot) {
    CollapsibleSlot.body => child,
    CollapsibleSlot.footer => footer,
  };

  @override
  RenderCollapsible createRenderObject(BuildContext context) =>
      RenderCollapsible(maxHeight: maxHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCollapsible renderObject,
  ) {
    renderObject.maxHeight = maxHeight;
  }
}

class RenderCollapsible extends RenderBox
    with SlottedContainerRenderObjectMixin<CollapsibleSlot, RenderBox> {
  RenderCollapsible({required double maxHeight}) : _maxHeight = maxHeight;

  double _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  RenderBox? get _body => childForSlot(CollapsibleSlot.body);
  RenderBox? get _footer => childForSlot(CollapsibleSlot.footer);

  /// 中身を切ったか。切ったときだけ帯を描き、触れるようにする。
  bool _collapsed = false;

  BoxConstraints _childConstraints(BoxConstraints constraints) => BoxConstraints(
    minWidth: constraints.minWidth,
    maxWidth: constraints.maxWidth,
  );

  @override
  void performLayout() {
    final body = _body;
    if (body == null) {
      _collapsed = false;
      size = constraints.smallest;
      return;
    }
    // 高さは縛らずに組ませる。縛ると中身が上限に合わせて自分を縮めてしまい、
    // 「本来どれだけ高いか」が分からなくなる。
    body.layout(_childConstraints(constraints), parentUsesSize: true);
    final natural = body.size.height;
    // 切った以上は必ず帯を出す。**上限を少し超えただけなら畳まない**といった
    // 手心を加えると、その帯（上限〜上限＋手心）のレスが、ボタンも出ないまま
    // 黙って切れる。
    _collapsed = natural > _maxHeight;
    size = constraints.constrain(
      Size(body.size.width, math.min(natural, _maxHeight)),
    );
    final footer = _footer;
    if (footer == null) return;
    // 幅は自分と同じ、高さは中身なり。位置は下端に揃える。切っていないときは
    // 潰した枠を渡す——帯の側（[CollapsingBody]）がそれを見て中身を作らないので、
    // 畳まないふつうのレスにボタン一式を組ませずに済む。
    footer.layout(
      _collapsed
          ? BoxConstraints.tightFor(width: size.width)
          : BoxConstraints.tight(Size.zero),
      parentUsesSize: true,
    );
    (footer.parentData! as BoxParentData).offset = Offset(
      0,
      size.height - footer.size.height,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final body = _body;
    if (body == null) return constraints.smallest;
    final natural = body.getDryLayout(_childConstraints(constraints));
    return constraints.constrain(
      Size(natural.width, math.min(natural.height, _maxHeight)),
    );
  }

  // 寸法の問い合わせは中身に丸投げする（高さだけ頭打ちにする）。帯は問い合わせ
  // に含めない——出るかどうかが中身の高さ次第で、含めると堂々巡りになる。
  @override
  double computeMinIntrinsicWidth(double height) =>
      _body?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _body?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.min(_body?.getMinIntrinsicHeight(width) ?? 0, _maxHeight);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.min(_body?.getMaxIntrinsicHeight(width) ?? 0, _maxHeight);

  @override
  void paint(PaintingContext context, Offset offset) {
    final body = _body;
    if (body == null) return;
    if (!_collapsed) {
      context.paintChild(body, offset);
      return;
    }
    // はみ出したぶんは切る。切らないと下のレスに重なって描かれる。
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(body, offset),
    );
    final footer = _footer;
    if (footer == null) return;
    context.paintChild(
      footer,
      offset + (footer.parentData! as BoxParentData).offset,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final footer = _footer;
    if (_collapsed &&
        footer != null &&
        _hitTestChild(footer, result, position)) {
      return true;
    }
    final body = _body;
    return body != null && _hitTestChild(body, result, position);
  }

  bool _hitTestChild(RenderBox child, BoxHitTestResult result, Offset position) {
    final childOffset = (child.parentData! as BoxParentData).offset;
    return result.addWithPaintOffset(
      offset: childOffset,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final childOffset = (child.parentData! as BoxParentData).offset;
    transform.translateByDouble(childOffset.dx, childOffset.dy, 0, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final body = _body;
    if (body != null) visitor(body);
    // 切っていないときの帯は画面に無いのと同じ。読み上げにも出さない。
    final footer = _footer;
    if (_collapsed && footer != null) visitor(footer);
  }
}

/// 長いときだけ畳む本文の入れ物。
///
/// 畳むかどうかは中身の高さ次第なので、**開いているかどうかは外が持つ**
/// （[expanded] / [onExpand]）。一覧の行は画面外へ出ると捨てられるため、ここで
/// 覚えると戻ってきたときに畳み直されてしまう。
class CollapsingBody extends StatelessWidget {
  const CollapsingBody({
    super.key,
    required this.child,
    required this.expanded,
    required this.onExpand,
    this.maxHeight = collapsedPostMaxHeight,
  });

  final Widget child;

  /// 「続きを読む」を押した後か。
  final bool expanded;

  final VoidCallback onExpand;

  final double maxHeight;

  @override
  Widget build(BuildContext context) => Collapsible(
    // 開いていない間は常に頭打ちにする。測り終わるのを待つと、一瞬だけ伸びきった
    // 姿が出てから縮むことになる。
    maxHeight: expanded ? double.infinity : maxHeight,
    // 帯を組み立てるのは切ったときだけ。切ったかどうかは中身を組んでみるまで
    // 分からないので、**組み立ての中で聞く**（[LayoutBuilder]）——潰した枠が
    // 来たら切っていない、というのが [RenderCollapsible] との約束。状態に
    // 持ち帰って次のフレームで出す作りと違い、1 拍遅れてちらつくことがない。
    footer: expanded
        ? null
        : LayoutBuilder(
            builder: (context, constraints) => constraints.maxHeight == 0
                ? const SizedBox.shrink()
                : _MoreFooter(onTap: onExpand),
          ),
    child: child,
  );
}

/// 畳まれた本文の下端に敷く「続きがある」合図。
///
/// ボタンだけでも用は足りるが、**どこで切れたか**が分からないと文章が途中で
/// 消えたように見える。地色へ溶ける階調を掛けて切れ目をぼかす。
///
/// 文言は「続きを読む」で固定。隠れた量を「あと◯行」と添えていたことがあるが、
/// **その数字で何かを決める人はいない**（開くか飛ばすかは、行数ではなくレスの
/// 見えている頭で決まる）わりに、行に直せるのが文章だけのレスに限られて出し
/// 分けが要るうえ、中身が伸び縮みするたびに数字が動く。
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
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
              label: const Text(
                '続きを読む',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
