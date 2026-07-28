import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import 'format.dart';

/// スレ一覧の 1 行。カードではなくフラットな行で、余白とタイポグラフィで
/// 区切る。勢いが高いスレはアクセント色で強調する。
class ThreadTile extends StatelessWidget {
  const ThreadTile({
    super.key,
    required this.thread,
    required this.onTap,
    this.onLongPress,
    this.isRead = false,
    this.newCount = 0,
    this.statusLabel,
    this.isOwn = false,
  });

  final ThreadSummary thread;
  final VoidCallback onTap;

  /// 長押し（スレ主 NG などのメニュー用）。
  final VoidCallback? onLongPress;

  /// 開いたことがあるスレか（タイトルの色を落として区別する）。
  final bool isRead;

  /// 前回開いてからの新着レス数（0 なら無し）。
  final int newCount;

  /// dat落ち・完走など、書き込み停止状態を示す短いラベル。
  final String? statusLabel;

  /// このアプリから立てたスレか。
  final bool isOwn;

  /// この勢い以上を「勢いのあるスレ」としてアクセント表示する（レス/日）。
  static const _hotThreshold = 300;

  /// 新着バッジのために空けておく幅。
  ///
  /// バッジが出入りしたり桁が増えたりするとタイトルの使える幅が変わり、1 行で
  /// 収まっていたものが 2 行に折り返して行の高さが動く。自動更新の最中にそれが
  /// 起きると、その行より下＝見ている場所が丸ごとズレる。出る可能性のある行
  /// （＝既読行）では、先に空けておいて幅を動かさない。
  ///
  /// タイトルから奪う幅なので、いちばん長い「999+」がぎりぎり収まるところまで
  /// 詰めてある。文字サイズの設定に合わせて広げるので、拡大しても収まる。
  static const _newBadgeSlot = 42.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final momentum = momentumPerDay(thread);
    final isHot = momentum >= _hotThreshold;

    final metaColor = scheme.onSurfaceVariant;
    final momentumColor = isHot ? scheme.primary : metaColor;
    // 既読スレはタイトルを少し落ち着かせて未読と区別する。
    final titleColor = isRead ? scheme.onSurfaceVariant : scheme.onSurface;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: 14,
      fontWeight: isRead ? FontWeight.w500 : FontWeight.w600,
      height: 1.3,
      color: titleColor,
    );
    final titleLineHeight = _lineHeight(titleStyle, fallbackFontSize: 14);
    final textScaler = MediaQuery.textScalerOf(context);

    return Material(
      color: isOwn
          ? scheme.tertiaryContainer.withValues(alpha: 0.22)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: isOwn
                ? Border(left: BorderSide(color: scheme.tertiary, width: 4))
                : null,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(isOwn ? 8 : 12, 8, 14, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左端の状態マーカー。タイトル 1 行目の中央に合わせる。
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _StatusMark(
                    isRead: isRead,
                    lineHeight: titleLineHeight,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1 行目はバッジ 1 個分の高さを常に確保する。バッジは
                      // タイトル 1 行より背が高いので、確保しておかないと付いた
                      // 瞬間に行が伸びて、下の行＝見ている場所がズレる。
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: _NewBadge.heightFor(textScaler),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                decodeEntities(thread.title),
                                style: titleStyle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // 新着はいちばん拾いたい情報なのでタイトルの右端に
                            // 出す。ただし出入りでタイトルの折り返し（＝行の
                            // 高さ）が変わらないよう、出る可能性のある既読行では
                            // 幅を先に空けておく（[_newBadgeSlot]）。
                            if (isRead) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: textScaler.scale(_newBadgeSlot),
                                child: newCount > 0
                                    ? Align(
                                        alignment: Alignment.centerRight,
                                        // 収まらないとき（極端な字幅のフォント）
                                        // だけ縮める。幅は動かさない。
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerRight,
                                          child: _NewBadge(count: newCount),
                                        ),
                                      )
                                    : null,
                              ),
                            ],
                            if (isOwn) ...[
                              const SizedBox(width: 8),
                              const _OwnThreadBadge(),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 11,
                          color: metaColor,
                        ),
                        // 停止状態はここに置く。タイトルの幅を奪わないので、
                        // 自動更新で後から付いても折り返しは変わらない。段の
                        // 高さも、常に出ている勢い・レス数（アイコン 13）より
                        // 背の低いものしか入れないので動かない。
                        child: Row(
                          children: [
                            _Metric(
                              icon: Icons.bolt,
                              label: formatCompact(momentum),
                              color: momentumColor,
                              emphasized: isHot,
                            ),
                            const SizedBox(width: 10),
                            _Metric(
                              icon: Icons.forum_outlined,
                              label: formatCompact(thread.resCount),
                              color: metaColor,
                            ),
                            // 停止状態は「もう書けない」という地味な事実なので、
                            // バッジで目立たせず勢い・レス数と同じ扱いで並べる。
                            if (statusLabel != null) ...[
                              const SizedBox(width: 10),
                              _Metric(
                                icon: Icons.lock_outline,
                                label: statusLabel!,
                                color: metaColor,
                              ),
                            ],
                            const Spacer(),
                            Text(formatAge(thread.createdAt)),
                          ],
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
    );
  }
}

double _lineHeight(TextStyle? style, {required double fallbackFontSize}) {
  final fontSize = style?.fontSize ?? fallbackFontSize;
  return fontSize * (style?.height ?? 1);
}

class _OwnThreadBadge extends StatelessWidget {
  const _OwnThreadBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note, size: 13, color: scheme.onTertiaryContainer),
          const SizedBox(width: 3),
          Text(
            '自分',
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 左端の未読マーカー。未読はアクセント色の点、既読は点なし（＝開いたことが
/// ある）。チェックは付けない（新着が後から来るので「読み終わった」ではない）。
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.isRead, required this.lineHeight});
  final bool isRead;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 既読でも同じ幅を確保してタイトルの左端を揃える。
    return SizedBox(
      width: 8,
      height: lineHeight,
      child: Center(
        child: SizedBox(
          width: 8,
          height: 8,
          child: isRead
              ? null
              : DecoratedBox(
                  key: const ValueKey('unread-dot'),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
  }
}

/// 前回からの新着レス数バッジ。
class _NewBadge extends StatelessWidget {
  const _NewBadge({required this.count});
  final int count;

  static const _fontSize = 11.0;
  static const _lineHeightFactor = 1.45;
  static const _verticalPadding = 3.0;

  /// このバッジの高さ。タイトル 1 行より背が高いので、行の高さを動かさないよう
  /// 呼び出し側があらかじめこの分を確保する（[ThreadTile.build]）。
  ///
  /// 文字の高さは整数に切り上げて組まれるので、こちらも切り上げる（端数のまま
  /// だと確保が 0.05px 足りず、付いた瞬間に行がその分伸びる）。
  static double heightFor(TextScaler textScaler) =>
      (textScaler.scale(_fontSize) * _lineHeightFactor).ceilToDouble() +
      _verticalPadding * 2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: _verticalPadding,
      ),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        // 1000 以上は桁が増えて幅が読めなくなるので丸める（スレは 1000 で
        // 止まるので、実際に出るのは開いたまま放置した未読だけ）。
        count > 999 ? '999+' : '+$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: _fontSize,
          // 高さを [heightFor] で計算できるよう、継承させず明示する。
          height: _lineHeightFactor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.color,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
