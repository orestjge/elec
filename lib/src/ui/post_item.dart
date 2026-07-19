import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import 'id_color.dart';
import 'image_urls.dart';
import 'post_images.dart';
import 'res_body.dart';

/// スレッドの 1 レス。番号順タイムライン向けの密なレイアウト。
/// 名前・本文は [htmlToText] で整形して表示する。
class PostItem extends StatelessWidget {
  const PostItem({
    super.key,
    required this.res,
    required this.idCount,
    required this.onTapId,
    this.onTapRes,
    this.onTapResRange,
    this.onTapUrl,
    this.replyCount = 0,
    this.onTapReplies,
    this.onReply,
    this.isOwn = false,
  });

  final Res res;

  /// このスレでの同一 ID の総数（1 なら単発）。
  final int idCount;

  /// ID タップ時。同一 ID のレス一覧を出す。
  final ValueChanged<String>? onTapId;

  /// `>>N` タップ時。該当レスへスクロールする。
  final ValueChanged<int>? onTapRes;

  /// `>>N-M` タップ時。範囲内のレスをまとめて扱う。
  final ValueChanged<List<int>>? onTapResRange;

  /// URL タップ時。ブラウザで開く。
  final ValueChanged<Uri>? onTapUrl;

  /// このレスが受けた返信の数（0 なら表示しない）。
  final int replyCount;

  /// 返信数タップ時。このレスへの返信一覧を出す。
  final ValueChanged<int>? onTapReplies;

  /// 「このレスに返信」タップ時。コンポーザに `>>N` を入れる。
  final ValueChanged<int>? onReply;

  /// このアプリから投稿したレスか。
  final bool isOwn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (res.isAbone) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          '${res.number} あぼーん',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    final name = htmlToText(res.name).trim();
    final body = htmlToText(res.body);
    final images = imageUrlsIn(body);
    final videos = videoUrlsIn(body);

    return Container(
      color: isOwn
          ? scheme.secondaryContainer.withValues(alpha: 0.22)
          : Colors.transparent,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            res: res,
            name: name.isEmpty ? '名無し' : name,
            idCount: idCount,
            onTapId: onTapId,
            onReply: onReply,
            isOwn: isOwn,
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            ResBody(
              text: body,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
              onTapRes: (n) => onTapRes?.call(n),
              onTapResRange: (numbers) => onTapResRange?.call(numbers),
              onTapUrl: (u) => onTapUrl?.call(u),
            ),
          ],
          if (images.isNotEmpty || videos.isNotEmpty)
            PostImages(urls: images, videoUrls: videos, onTapVideo: onTapUrl),
          if (replyCount > 0) ...[
            const SizedBox(height: 8),
            _ReplyCountChip(
              count: replyCount,
              onTap: onTapReplies == null
                  ? null
                  : () => onTapReplies!(res.number),
            ),
          ],
        ],
      ),
    );
  }
}

/// このレスへの返信数を示すチップ。タップで返信一覧。
class _ReplyCountChip extends StatelessWidget {
  const _ReplyCountChip({required this.count, required this.onTap});
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.reply, size: 13, color: scheme.onSecondaryContainer),
            const SizedBox(width: 4),
            Text(
              '返信 $count',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.res,
    required this.name,
    required this.idCount,
    required this.onTapId,
    required this.onReply,
    required this.isOwn,
  });

  final Res res;
  final String name;
  final int idCount;
  final ValueChanged<String>? onTapId;
  final ValueChanged<int>? onReply;
  final bool isOwn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 左グループ（番号・名前・ID）を Expanded で残り幅ごと占有させ、
        // 日時・返信ボタンを画面幅に関わらず常に右端へ固定する。名前が短くても
        // 中途半端な位置に流れない。名前は Flexible で長い場合は省略。
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${res.number}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (res.id != null) ...[
                const SizedBox(width: 8),
                _IdChip(id: res.id!, count: idCount, onTap: onTapId),
              ],
              if (isOwn) ...[
                const SizedBox(width: 8),
                _OwnChip(color: scheme.secondary),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        _TimeLabel(res: res),
        if (onReply != null) ...[
          const SizedBox(width: 4),
          InkResponse(
            onTap: () => onReply!(res.number),
            radius: 18,
            // 余白は左右対称にして、ハイライト円の中心とアイコン中心を合わせる。
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.reply,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _OwnChip extends StatelessWidget {
  const _OwnChip({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        '自分',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// レス時刻。既定は HH:MM:SS のみ。タップでコンマ以下・日付まで含む完全な
/// 日時をスナックバーに出す。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.res});
  final Res res;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final full = res.dateText.trim();
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(_short(res), style: style),
    );
    if (full.isEmpty) return label;
    // タップ／ホバーでコンマ以下・日付まで含む完全な日時をその場に出す。画面下の
    // スナックバーだと入力欄に重なるため、近くに浮かぶツールチップにする。
    return Tooltip(
      message: full,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      child: label,
    );
  }

  /// 日付テキストから時刻部分（HH:MM:SS）を取り出す。無ければ全体。
  static String _short(Res res) {
    final m = RegExp(r'(\d{2}:\d{2}:\d{2})').firstMatch(res.dateText);
    return m?.group(1) ?? res.dateText;
  }
}

class _IdChip extends StatelessWidget {
  const _IdChip({required this.id, required this.count, required this.onTap});
  final String id;
  final int count;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final color = idColor(id, brightness);
    return InkWell(
      onTap: onTap == null ? null : () => onTap!(id),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          count > 1 ? 'ID:$id ($count)' : 'ID:$id',
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
