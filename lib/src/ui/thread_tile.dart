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
                      Row(
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
                          if (isOwn) ...[
                            const SizedBox(width: 8),
                            const _OwnThreadBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 11,
                          color: metaColor,
                        ),
                        // 自動更新で後から付くもの（新着バッジ・停止状態）は、
                        // 常に出ている勢い・レス数と同じこの下段に置く。
                        //
                        // タイトルの横に置くと、その幅の分だけタイトルが折り返
                        // して行の高さが動き、下の行＝見ている場所が丸ごとズレ
                        // る。下段なら幅を奪わないうえ、後から入るものはどれも
                        // メトリクス（アイコン 13・11px 文字）より背が低いので、
                        // 出入りしても段の高さは変わらない。
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
                            if (newCount > 0) ...[
                              const SizedBox(width: 6),
                              _NewBadge(count: newCount),
                            ],
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
    // 新着バッジと同じく、タイトル 1 行分の高さに収める。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
              height: 1,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 下段のメトリクスより背が低くなるよう詰める。はみ出すと、バッジが付いた
    // 瞬間に行が伸びて一覧がズレる。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 11,
          height: 1,
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
