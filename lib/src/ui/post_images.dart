import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'audio_player_widget.dart';
import 'embed_urls.dart';
import 'image_urls.dart';
import 'nico_thumbnail.dart';
import 'video_player_screen.dart';
import 'video_thumbnail.dart';

/// レス本文に含まれる画像 URL のサムネイル群。タップで全画面表示。
class PostImages extends StatelessWidget {
  const PostImages({
    super.key,
    required this.urls,
    this.videoUrls = const [],
    this.audioUrls = const [],
    this.embedVideos = const [],
    this.onOpenVideoExternally,
    this.onTapEmbed,
    this.onRemove,
    this.thumbSize = 160,
    this.blurImages = false,
  });

  final List<Uri> urls;

  /// 本文中の動画 URL。タップでアプリ内の全画面プレーヤーを開く。
  final List<Uri> videoUrls;

  /// 本文中の音声 URL。インラインのミニプレーヤーで再生する。
  final List<Uri> audioUrls;

  /// YouTube / ニコニコ動画のリンク。タップで外部プレーヤーを開く。
  final List<EmbedVideo> embedVideos;

  /// アプリ内で再生できなかった動画をブラウザへ回すための逃げ道。
  /// 未指定ならプレーヤーに「ブラウザで開く」を出さない。
  final ValueChanged<Uri>? onOpenVideoExternally;

  final ValueChanged<Uri>? onTapEmbed;

  /// 指定すると各サムネイルに削除（×）ボタンを重ね、押すとその URL を渡す。
  /// 入力欄の添付プレビューで、本文から URL を取り消すために使う。
  final ValueChanged<Uri>? onRemove;

  /// サムネイルの一辺（px）。入力欄プレビューなどで小さく出したいとき使う。
  final double thumbSize;

  /// このレスの画像に「グロ」注意が付いており、サムネイルへモザイクを掛けるか。
  final bool blurImages;

  Widget _removable(Uri url, Widget child) {
    if (onRemove == null) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: 4,
          right: 4,
          child: _RemoveButton(onTap: () => onRemove!(url)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasThumbs =
        urls.isNotEmpty || videoUrls.isNotEmpty || embedVideos.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasThumbs)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < urls.length; i++)
                  _removable(
                    urls[i],
                    _Thumb(
                      urls: urls,
                      index: i,
                      size: thumbSize,
                      blurred: blurImages,
                    ),
                  ),
                for (final url in videoUrls)
                  _removable(
                    url,
                    _VideoThumb(
                      url: url,
                      size: thumbSize,
                      onOpenExternally: onOpenVideoExternally,
                    ),
                  ),
                for (final video in embedVideos)
                  _removable(
                    video.url,
                    _EmbedThumb(
                      video: video,
                      size: thumbSize,
                      onTap: onTapEmbed == null
                          ? null
                          : () => onTapEmbed!(video.url),
                    ),
                  ),
              ],
            ),
          for (var i = 0; i < audioUrls.length; i++)
            Padding(
              padding: EdgeInsets.only(top: (hasThumbs || i > 0) ? 8 : 0),
              child: onRemove == null
                  ? AudioPlayerTile(url: audioUrls[i])
                  : Row(
                      children: [
                        Expanded(child: AudioPlayerTile(url: audioUrls[i])),
                        const SizedBox(width: 4),
                        _RemoveButton(onTap: () => onRemove!(audioUrls[i])),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

/// サムネイル右上に重ねる削除ボタン。
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(3),
          child: Icon(Icons.close, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    required this.urls,
    required this.index,
    this.size = 160,
    this.blurred = false,
  });
  final List<Uri> urls;
  final int index;
  final double size;

  /// 「グロ」注意が付いた画像で、初期表示をモザイクにするか。
  final bool blurred;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  /// モザイクを一度タップで解除したか。解除後は通常どおりタップで全画面表示。
  bool _revealed = false;

  Uri get _url => widget.urls[widget.index];

  void _openViewer() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          _ImageViewer(urls: widget.urls, initialIndex: widget.index),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // グロ指定があり、まだ解除していない間だけモザイクを掛ける。最初のタップは
    // 全画面を開かず解除に使い、不意にグロ画像を大きく表示しないようにする。
    final masked = widget.blurred && !_revealed;
    return GestureDetector(
      onTap: masked ? () => setState(() => _revealed = true) : _openViewer,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            Image.network(
              _url.toString(),
              height: widget.size,
              width: widget.size,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return _Placeholder(
                  size: widget.size,
                  color: scheme.surfaceContainerHighest,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                );
              },
              errorBuilder: (context, error, stack) => _Placeholder(
                size: widget.size,
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (masked) const Positioned.fill(child: _GuroMask()),
          ],
        ),
      ),
    );
  }
}

/// グロ画像のサムネイルに重ねるモザイク（ぼかし）と注意ラベル。
class _GuroMask extends StatelessWidget {
  const _GuroMask();

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          alignment: Alignment.center,
          color: Colors.black.withValues(alpha: 0.35),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_off, color: Colors.white, size: 26),
              SizedBox(height: 4),
              Text(
                'グロ',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'タップで表示',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({
    required this.url,
    required this.onOpenExternally,
    this.size = 160,
  });
  final Uri url;

  /// プレーヤー側の「ブラウザで開く」に渡すハンドラ。
  final ValueChanged<Uri>? onOpenExternally;
  final double size;

  /// アプリ内の全画面プレーヤーを開く。ブラウザへは飛ばさない。
  void _open(BuildContext context) =>
      openVideoPlayer(context, url, onOpenExternally: onOpenExternally);

  @override
  Widget build(BuildContext context) {
    // Android/iOS/macOS では先頭フレームをサムネイル生成して敷く。生成前・失敗・
    // 非対応プラットフォームでは無地の再生カードにフォールバックする。
    if (!VideoThumbnails.isSupported) return _card(context, frame: null);
    return FutureBuilder<Uint8List?>(
      future: VideoThumbnails.resolve(url),
      builder: (context, snapshot) => _card(context, frame: snapshot.data),
    );
  }

  Widget _card(BuildContext context, {required Uint8List? frame}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        // 読取前（無地）と読取後（フレーム画像）で同じ構図にする。暗幕は敷かず、
        // 左下に「▶ サイト名」の小さなバッジだけを出す。
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null)
              Image.memory(
                frame,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const SizedBox(),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _VideoBadge(label: videoSiteLabel(url)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 動画サムネ左下の「▶ サイト名」バッジ。
class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow_rounded, size: 16, color: scheme.onSurface),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// YouTube / ニコニコ動画のサムネイルカード。タップで外部プレーヤーを開く。
/// サムネイル画像が取れる場合（YouTube）は背景に敷き、無い場合（ニコニコ）は
/// 無地の再生カードにする。
class _EmbedThumb extends StatelessWidget {
  const _EmbedThumb({
    required this.video,
    required this.onTap,
    this.size = 160,
  });
  final EmbedVideo video;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    // YouTube は静的サムネ URL を持つ。ニコニコは getthumbinfo API で解決してから
    // 敷く（解決前・失敗時は無地の再生カード）。
    final direct = video.thumbnailUrl;
    if (direct != null) return _card(context, thumbnailUrl: direct);
    if (video.kind == EmbedKind.niconico) {
      return FutureBuilder<Uri?>(
        future: NicoThumbnails.resolve(video.id),
        builder: (context, snapshot) =>
            _card(context, thumbnailUrl: snapshot.data?.toString()),
      );
    }
    return _card(context, thumbnailUrl: null);
  }

  Widget _card(BuildContext context, {required String? thumbnailUrl}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: size,
        width: size * 1.25,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailUrl != null)
              Image.network(
                thumbnailUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const SizedBox(),
              ),
            // サムネイルの上に薄い暗幕を敷き、再生アイコンと見出しを読みやすく。
            if (thumbnailUrl != null)
              const DecoratedBox(
                decoration: BoxDecoration(color: Colors.black26),
              ),
            Center(
              child: Icon(
                Icons.play_circle_fill,
                size: 52,
                color: thumbnailUrl != null ? Colors.white : scheme.primary,
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  child: Text(
                    video.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.color,
    required this.child,
    this.size = 160,
  });
  final Color color;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      color: color,
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// 全画面の画像ビューア。ピンチズーム・パン可能。
class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.urls, required this.initialIndex});
  final List<Uri> urls;
  final int initialIndex;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _page;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Uri get _url => widget.urls[_index];

  void _jumpBy(int delta) {
    if (widget.urls.length <= 1) return;
    final next = (_index + delta) % widget.urls.length;
    final normalized = next < 0 ? widget.urls.length - 1 : next;
    _page.animateToPage(
      normalized,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final multiple = widget.urls.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          multiple
              ? '${_index + 1}/${widget.urls.length}  ${_fileName(_url)}'
              : _fileName(_url),
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _page,
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _ZoomableImage(
              url: widget.urls[i].toString(),
              onDismiss: () => Navigator.of(context).pop(),
            ),
          ),
          if (multiple) ...[
            _NavButton(
              alignment: Alignment.centerLeft,
              icon: Icons.chevron_left,
              onPressed: () => _jumpBy(-1),
            ),
            _NavButton(
              alignment: Alignment.centerRight,
              icon: Icons.chevron_right,
              onPressed: () => _jumpBy(1),
            ),
          ],
        ],
      ),
    );
  }

  String _fileName(Uri url) => _mediaFileName(url);
}

String _mediaFileName(Uri url) =>
    url.pathSegments.isNotEmpty ? url.pathSegments.last : url.host;

/// 画面全体でピンチズーム・パンでき、画像の外側（余白）タップで閉じられる画像。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({required this.url, required this.onDismiss});
  final String url;
  final VoidCallback onDismiss;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final TransformationController _controller = TransformationController();
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  void _resolveImageSize() {
    final stream = NetworkImage(widget.url).resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _imageSize = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
      });
    });
    _stream?.removeListener(_listener!);
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _controller.dispose();
    super.dispose();
  }

  /// 変換前（fit 状態）に画像が占める矩形。
  Rect _fittedRect(Size viewport) {
    final size = _imageSize;
    if (size == null || size.width == 0 || size.height == 0) {
      return Offset.zero & viewport;
    }
    final scale = math.min(
      viewport.width / size.width,
      viewport.height / size.height,
    );
    final w = size.width * scale;
    final h = size.height * scale;
    return Rect.fromLTWH(
      (viewport.width - w) / 2,
      (viewport.height - h) / 2,
      w,
      h,
    );
  }

  void _handleTapUp(Offset position, Size viewport) {
    // タップ位置を変換前の座標へ戻し、画像矩形の外なら閉じる。
    final inverted = Matrix4.tryInvert(_controller.value);
    final scenePoint = inverted == null
        ? position
        : MatrixUtils.transformPoint(inverted, position);
    if (!_fittedRect(viewport).contains(scenePoint)) {
      widget.onDismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _controller,
              minScale: 1,
              maxScale: 5,
              child: Image.network(
                widget.url,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(child: CircularProgressIndicator()),
                errorBuilder: (context, error, stack) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 64,
                  ),
                ),
              ),
            ),
            // 画像より上に薄いレイヤーを重ね、タップだけを拾う。
            // ピンチ・パンは下の InteractiveViewer に流れる。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) =>
                    _handleTapUp(details.localPosition, viewport),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.alignment,
    required this.icon,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: IconButton.filledTonal(
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
          ),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}
