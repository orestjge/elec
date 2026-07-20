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
      fontWeight: isRead ? FontWeight.w500 : FontWeight.w600,
      height: 1.3,
      color: titleColor,
    );
    final titleLineHeight = _lineHeight(titleStyle, fallbackFontSize: 16);

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
            padding: EdgeInsets.fromLTRB(isOwn ? 10 : 14, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左端の状態マーカー。タイトル 1 行目の中央に合わせる。
                Padding(
                  padding: const EdgeInsets.only(right: 10),
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
                          if (newCount > 0) ...[
                            const SizedBox(width: 8),
                            _NewBadge(count: newCount),
                          ],
                          if (statusLabel != null) ...[
                            const SizedBox(width: 8),
                            _StatusBadge(label: statusLabel!),
                          ],
                          if (isOwn) ...[
                            const SizedBox(width: 8),
                            const _OwnThreadBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: metaColor,
                        ),
                        child: Row(
                          children: [
                            _Metric(
                              icon: Icons.bolt,
                              label: formatCompact(momentum),
                              color: momentumColor,
                              emphasized: isHot,
                            ),
                            const SizedBox(width: 14),
                            _Metric(
                              icon: Icons.forum_outlined,
                              label: formatCompact(thread.resCount),
                              color: metaColor,
                            ),
                            if (thread.metadent != null) ...[
                              const SizedBox(width: 14),
                              Flexible(
                                child: Text(
                                  'ID:${thread.metadent}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
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
      width: 9,
      height: lineHeight,
      child: Center(
        child: SizedBox(
          width: 9,
          height: 9,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 11,
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
        Icon(icon, size: 15, color: color),
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
