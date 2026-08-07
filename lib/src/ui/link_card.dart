import 'package:flutter/material.dart';

import '../net/link_preview.dart';
import '../net/thread_link.dart';
import 'format.dart';
import 'remote_image.dart';

/// 本文に貼られたリンク 1 本ぶんの表示。
///
/// 画像と違い、**カードを出せるかは取りに行ってみるまで分からない**（OGP を
/// 書いていない、UA で弾かれる、落ちている）。そこで、
///  - 解決するまで／諦めたときは **URL をそのまま出す**。今までどおりの見た目で、
///    何のリンクなのかも失われない。
///  - 中身が取れたときだけカードに差し替え、URL の文字列は畳む。見出しとサイト名が
///    出ている以上、長い URL を並べても読む用が無いため。
///
/// 差し替えで 1 度だけ高さが変わるが、先に枠だけ確保して待つより、出ないときに
/// 空き地が残らない方を採った（出ないことの方が多い前提の機能なので）。
///
/// 知っている板のスレ URL（[ThreadLinks.targetOf]）だけは OGP ではなく **dat から
/// スレタイを取る**。read.cgi の OGP は板によって無く、dat落ちしたスレでは倉庫の
/// 案内ページが返ってきて中身と噛み合わないため。掲示板サーバから取るので
/// [enabled]（OGP の設定）に関わらず出す。
class LinkCard extends StatefulWidget {
  const LinkCard({
    super.key,
    required this.url,
    required this.raw,
    required this.onTap,
    this.enabled = true,
    this.showImage = true,
    this.linkStyle,
  });

  /// 開きに行く URL。
  final Uri url;

  /// 本文に書かれていた表記（`ttps://…` の省略形など）。カードにできないときは
  /// これをそのまま出して、書かれたとおりの本文を保つ。
  final String raw;

  final ValueChanged<Uri> onTap;

  /// 取りに行くか。設定でリンクプレビューを切っているときは false。
  final bool enabled;

  /// カードに絵を出すか。「グロ」注意の付いたレスでは false にして、リンク先の
  /// 絵が不意に出ないようにする（見出しだけのカードになる）。
  final bool showImage;

  /// カードにできないときに URL を出す文字スタイル。本文中のリンクと揃える。
  final TextStyle? linkStyle;

  @override
  State<LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<LinkCard> {
  Future<LinkPreview?>? _preview;
  Future<ThreadLinkInfo?>? _thread;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(LinkCard old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.enabled != widget.enabled) _start();
  }

  void _start() {
    _preview = null;
    _thread = null;
    final target = ThreadLinks.targetOf(widget.url);
    if (target != null) {
      _thread = ThreadLinks.resolve(target);
      return;
    }
    _preview = widget.enabled ? LinkPreviews.resolve(widget.url) : null;
  }

  @override
  Widget build(BuildContext context) {
    final thread = _thread;
    if (thread != null) {
      return FutureBuilder<ThreadLinkInfo?>(
        future: thread,
        builder: (context, snapshot) {
          final info = snapshot.data;
          if (info == null) return _plainLink();
          return _ThreadCard(info: info, onTap: () => widget.onTap(widget.url));
        },
      );
    }
    final future = _preview;
    if (future == null) return _plainLink();
    return FutureBuilder<LinkPreview?>(
      future: future,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (preview == null) return _plainLink();
        return _Card(
          preview: preview,
          showImage: widget.showImage,
          onTap: () => widget.onTap(widget.url),
        );
      },
    );
  }

  Widget _plainLink() => GestureDetector(
    onTap: () => widget.onTap(widget.url),
    child: Text(widget.raw, style: widget.linkStyle),
  );
}

/// カードの見た目。左に絵、右にサイト名・見出し・要約。
class _Card extends StatelessWidget {
  const _Card({
    required this.preview,
    required this.showImage,
    required this.onTap,
  });

  final LinkPreview preview;
  final bool showImage;
  final VoidCallback onTap;

  /// 絵の一辺。カードの高さもこれに合わせる（文字が短くても間延びしない）。
  static const _imageSize = 84.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final image = showImage ? preview.imageUrl : null;
    return _CardShell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (image != null) _Thumb(url: image, size: _imageSize),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.siteName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (preview.title case final title?) ...[
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ],
                    if (preview.description case final description?) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// スレ URL のカード。板名・スレタイ・1 レス目の冒頭を出す。
///
/// OGP のカードと違って絵は出さない。dat から取れるのは文字だけで、無い絵の
/// ぶんを空けても間が抜けるため。代わりに掲示板のアイコンを添えて、外部サイトの
/// カードと**ひと目で違うもの**として読めるようにする。
class _ThreadCard extends StatelessWidget {
  const _ThreadCard({required this.info, required this.onTap});

  final ThreadLinkInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final resSpec = _resSpecLabel(info.target.ref.resSpec);
    return _CardShell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.forum_outlined,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    info.board.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
                if (resSpec != null) ...[
                  const SizedBox(width: 6),
                  Text(resSpec, style: labelStyle),
                ],
                // スレ立てからの経過。実況スレも何年も前の過去ログもスレタイ
                // だけでは同じ顔で並ぶので、開く前に古さが分かるようにする。
                // 表記は一覧（`ThreadTile`）と同じ相対表記で揃える。
                if (info.createdAt case final createdAt?) ...[
                  const SizedBox(width: 6),
                  Text(formatAge(createdAt), style: labelStyle),
                ],
                // dat落ちは「開いても続きは書けない」ことなので、スレタイと同じ
                // 高さで見えるところに置く。
                if (info.pastLog) ...[
                  const SizedBox(width: 6),
                  _Badge(text: 'dat落ち'),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              info.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (info.excerpt case final excerpt?) ...[
              const SizedBox(height: 3),
              Text(
                excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.25,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// URL の末尾に付いたレス指定の表示。番号（`5`・`10-20`）だけ `>>` を付けて
  /// 出し、`l50` のような「読み方」の指定は出さない（読む側に用が無い）。
  static String? _resSpecLabel(String? resSpec) {
    if (resSpec == null) return null;
    if (RegExp(r'^\d+$').hasMatch(resSpec)) return '>>$resSpec';
    if (RegExp(r'^\d+-\d+$').hasMatch(resSpec)) return '>>$resSpec';
    return null;
  }
}

/// カードの外枠。OGP のカードとスレのカードで同じ形にする。
class _CardShell extends StatelessWidget {
  const _CardShell({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  /// これ以上広げても読みやすくならないので、広い画面では左に寄せて止める。
  static const _maxWidth = 420.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// スレの状態を示す小さな札。
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onTertiaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// カード左の絵。
///
/// 読み込み中も失敗時も同じ無地で埋め、幅を最初から確保しておく。カードは
/// 「URL からの差し替え」で 1 度高さが動くので、そのうえ絵の到着で横幅まで
/// 動かない方がよい。壊れた絵のアイコンも出さない（主役は見出しなので、
/// 取れなかったことを大きく報せる意味が無い）。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, required this.size});

  final Uri url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blank = ColoredBox(color: scheme.surfaceContainerHighest);
    return SizedBox(
      width: size,
      child: Image(
        image: RemoteImage(
          url,
          target: Size.square(size * MediaQuery.devicePixelRatioOf(context)),
          cover: true,
        ),
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : blank,
        errorBuilder: (context, error, stack) => blank,
      ),
    );
  }
}
