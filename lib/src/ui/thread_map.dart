/// スレマップ — ファストスクロールのトラックに出す目印。
///
/// chMate の「スレマップ」のように本文の長さを縦軸に写すことはしない。
/// [ScrollablePositionedList] はピクセル位置を持たず、画像・動画・あぼーんで
/// 行の高さもまちまちなので、正確なピクセル縦軸を出すには全行の実測がいる。
/// 代わりに、つまみと同じ「行インデックス」を縦軸にして、飛び先を選ぶのに効く
/// 情報だけを目印として置く。**数が多いものは載せない**（画像を含むレスの目盛り
/// を出していた時期があるが、典型的なスレでは目印の 8〜9 割を占めてトラックが
/// ごちゃつくのでやめた。残っているのはどれも 1 スレに数本〜十数本）。
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'reply_tier.dart';

/// スレマップの目印の種別。
enum ThreadMapMarkerKind {
  /// 返信を [manyRepliesThreshold] 件以上集めたレス。
  manyReplies,

  /// 返信を [veryManyRepliesThreshold] 件以上集めたレス。
  veryManyReplies,

  /// 「ここから新着」の区切り。
  newArrival,

  /// 自分のレス。
  own,

  /// 自分宛（自分のレスへの `>>N`）のレス。
  replyToOwn,

  /// スレ内検索の一致レス。
  searchMatch,
}

/// スレマップの目印 1 つ。位置は行インデックスで持つ。
class ThreadMapMarker {
  const ThreadMapMarker(this.index, this.kind);

  final int index;
  final ThreadMapMarkerKind kind;

  @override
  bool operator ==(Object other) =>
      other is ThreadMapMarker && other.index == index && other.kind == kind;

  @override
  int get hashCode => Object.hash(index, kind);

  @override
  String toString() => 'ThreadMapMarker($index, ${kind.name})';
}

/// スレマップを描く。行インデックスを縦位置に写し、目印を短い横線で並べる。
///
/// 縦軸はつまみの中心に合わせてあるので、目印の高さへつまみを運べばその行に
/// 着く。色はレス本体の表現に揃える（自分＝secondary、自分宛と新着＝primary、
/// 検索一致＝tertiary）。
class ThreadMapPainter extends CustomPainter {
  const ThreadMapPainter({
    required this.markers,
    required this.itemCount,
    required this.handleHeight,
    required this.scheme,
  });

  final List<ThreadMapMarker> markers;
  final int itemCount;

  /// つまみの高さ。縦軸をつまみの中心に合わせるために要る。
  final double handleHeight;

  final ColorScheme scheme;

  /// 背骨（目印だけだと縦軸が浮くので薄く引く）の幅。
  static const double _spineWidth = 2;

  /// 目印のバー。指で押せる大きさでもある（タップでその行へ飛ぶ）。
  static const double _barWidth = 16;
  static const double _barHeight = 5;

  /// 新着ラインの太さ。長さは他の目印と同じで、細さだけで区切りらしくする。
  static const double _lineHeight = 2.5;

  Color _markerColor(ThreadMapMarkerKind kind) => switch (kind) {
    // 返信が集まったレスは、他のどれとも被らない暖色で目立たせる（警告の意味
    // ではなく「盛り上がった場所」の印）。件数の段階は同じ色の濃さで示す。
    ThreadMapMarkerKind.manyReplies => Color.alphaBlend(
      scheme.error.withValues(alpha: 0.5),
      scheme.surface,
    ),
    ThreadMapMarkerKind.veryManyReplies => scheme.error,
    ThreadMapMarkerKind.newArrival => scheme.primary,
    ThreadMapMarkerKind.own => scheme.secondary,
    ThreadMapMarkerKind.replyToOwn => scheme.primary,
    ThreadMapMarkerKind.searchMatch => scheme.tertiary,
  };

  /// 右端から左へ伸びる目印を描く。
  void _drawBar(
    Canvas canvas,
    Paint paint,
    Size size,
    double y,
    double width,
    double height,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - width, y - height / 2, width, height),
        Radius.circular(height / 2),
      ),
      paint,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (itemCount <= 1) return;
    final travel = size.height - handleHeight;
    if (travel <= 0) return;
    // つまみの縦位置は「つまみ上端 = index/(件数-1) * travel」なので、目印は
    // つまみの中心に合わせて半分ぶん下げる。
    final top = handleHeight / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width - _spineWidth, top, _spineWidth, travel),
        const Radius.circular(_spineWidth / 2),
      ),
      Paint()..color = scheme.outlineVariant,
    );

    // 種別ごとにまとめて描く。列挙の順が重なりの順（後のものほど手前）。
    for (final kind in ThreadMapMarkerKind.values) {
      final paint = Paint()..color = _markerColor(kind);
      for (final marker in markers) {
        if (marker.kind != kind) continue;
        final y = top + marker.index / (itemCount - 1) * travel;
        switch (kind) {
          // 新着はレスではなく区切り。長さは他と揃え、細さで線らしく見せる。
          case ThreadMapMarkerKind.newArrival:
            _drawBar(canvas, paint, size, y, _barWidth, _lineHeight);
          // レスを指す目印はバー。タップで飛べる／つまみが吸い付く。
          case ThreadMapMarkerKind.manyReplies:
          case ThreadMapMarkerKind.veryManyReplies:
          case ThreadMapMarkerKind.own:
          case ThreadMapMarkerKind.replyToOwn:
          case ThreadMapMarkerKind.searchMatch:
            _drawBar(canvas, paint, size, y, _barWidth, _barHeight);
        }
      }
    }
  }

  @override
  bool shouldRepaint(ThreadMapPainter old) =>
      old.itemCount != itemCount ||
      old.handleHeight != handleHeight ||
      old.scheme != scheme ||
      !listEquals(old.markers, markers);
}
