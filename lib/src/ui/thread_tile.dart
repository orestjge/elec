import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import 'emphasis.dart';
import 'format.dart';

/// もう書き込めないスレの状態。下段にアイコン＋短いラベルで出す。
enum ThreadStatus {
  /// 1000 まで行き切った。掲示板ではめでたい終わり方なので、トロフィーで
  /// 「やり切った」ほうの止まり方だと分かるようにする。
  finished('完走', Icons.emoji_events_outlined),

  /// 一覧から落ちた（もう書けない）。こちらは地味な事実なので鍵のまま。
  archived('dat落ち', Icons.lock_outline);

  const ThreadStatus(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// そのスレをどこまで見たか。左端のマーカーで区別する。
enum ThreadSeen {
  /// 一覧でも見たことがない＝前に見たときには無かったスレ。実況板では「さっき
  /// 立った」がいちばん拾いたい情報なので、塗りつぶしの点で目立たせる。
  fresh,

  /// 一覧で見かけたが、まだ開いていない。点は輪郭だけにして、未読なのは分かる
  /// が新顔ではない、を表す。
  listed,

  /// 開いたことがある。点は出さない。
  opened,
}

/// スレ一覧の 1 行。カードではなくフラットな行で、余白とタイポグラフィで
/// 区切る。**メタ（勢い・レス数・停止状態）は全部同じ薄さ**で、強調しない。
class ThreadTile extends StatelessWidget {
  const ThreadTile({
    super.key,
    required this.thread,
    required this.onTap,
    this.onLongPress,
    this.seen = ThreadSeen.fresh,
    this.newCount = 0,
    this.status,
    this.isOwn = false,
  });

  final ThreadSummary thread;
  final VoidCallback onTap;

  /// 長押し（スレ主 NG などのメニュー用）。
  final VoidCallback? onLongPress;

  /// このスレをどこまで見たか。開いたスレはタイトルの色を落とす。
  final ThreadSeen seen;

  /// 開いたことがあるか。
  bool get _isRead => seen == ThreadSeen.opened;

  /// 前回開いてからの新着レス数（0 なら無し）。
  final int newCount;

  /// 書き込み停止状態（完走・dat落ち）。まだ書けるスレでは null。
  final ThreadStatus? status;

  /// このアプリから立てたスレか。
  final bool isOwn;

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

    final metaColor = scheme.onSurfaceVariant;
    // 既読スレはタイトルを少し落ち着かせて未読と区別する。
    final titleColor = _isRead ? scheme.onSurfaceVariant : scheme.onSurface;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: 14,
      fontWeight: _isRead ? FontWeight.w500 : FontWeight.w600,
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
                  child: _StatusMark(seen: seen, lineHeight: titleLineHeight),
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
                            if (_isRead) ...[
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
                            _Momentum(perDay: momentum, color: metaColor),
                            const SizedBox(width: 10),
                            _Metric(
                              icon: Icons.forum_outlined,
                              label: formatCompact(thread.resCount),
                              color: metaColor,
                            ),
                            // 停止状態はバッジで目立たせず、勢い・レス数と同じ
                            // 扱いで並べる。完走だけは色を足して、走り切った
                            // ほうの止まり方だと分かるようにする。
                            if (status case final status?) ...[
                              const SizedBox(width: 10),
                              _Metric(
                                icon: status.icon,
                                label: status.label,
                                color: status == ThreadStatus.finished
                                    ? scheme.tertiary
                                    : metaColor,
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

/// 左端の状態マーカー。塗りつぶし＝新顔、輪郭だけ＝一覧で見たがまだ開いていない、
/// 無し＝開いたことがある。チェックは付けない（新着が後から来るので「読み終わっ
/// た」ではない）。
///
/// 3 つとも同じ 8px の丸なので、状態が変わっても行の高さも左端も動かない。
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.seen, required this.lineHeight});
  final ThreadSeen seen;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 開いたスレでも同じ幅を確保してタイトルの左端を揃える。
    return SizedBox(
      width: 8,
      height: lineHeight,
      child: Center(
        child: SizedBox(
          width: 8,
          height: 8,
          child: switch (seen) {
            ThreadSeen.fresh => DecoratedBox(
              key: const ValueKey('fresh-dot'),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            ThreadSeen.listed => DecoratedBox(
              key: const ValueKey('listed-dot'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: scheme.primary, width: 1.5),
              ),
            ),
            ThreadSeen.opened => null,
          },
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
  const _Metric({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// 勢い（レス/日）。数字は他のメタと**同じ薄さ・同じ太さ**で、下に細い棒を
/// 敷いて量を絵にする。
///
/// **棒の色は動かさない。** 一覧は「探す」画面で、目立たせるべきはスレタイの
/// ほう——既読／未読でタイトルの濃さを動かしているので、メタでも濃淡を使うと
/// 2 つの合図が混ざる。速いスレを「強調」するのではなく、数字を読まなくても
/// 桁の見当が付く程度の添え物に留める。
///
/// **下敷きは常に全長ぶん敷く**ので、棒が伸びていなくても行の高さは動かない。
class _Momentum extends StatelessWidget {
  const _Momentum({required this.perDay, required this.color});

  final double perDay;
  final Color color;

  /// 棒の長さ。数字 3 桁ぶんに合わせてある。
  static const _barWidth = 34.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final amount = momentumAmount(perDay);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Metric(
          icon: Icons.bolt,
          label: formatCompact(perDay),
          color: color,
        ),
        const SizedBox(height: 2),
        Stack(
          children: [
            Container(
              width: _barWidth,
              height: 2,
              color: emphasisTrack(scheme),
            ),
            Container(width: _barWidth * amount, height: 2, color: color),
          ],
        ),
      ],
    );
  }
}


