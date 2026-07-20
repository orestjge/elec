import 'dart:math' as math;

import 'package:flutter/material.dart';

/// レス本文に含まれる画像 URL のサムネイル群。タップで全画面表示。
class PostImages extends StatelessWidget {
  const PostImages({
    super.key,
    required this.urls,
    this.videoUrls = const [],
    this.onTapVideo,
  });

  final List<Uri> urls;
  final List<Uri> videoUrls;
  final ValueChanged<Uri>? onTapVideo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < urls.length; i++) _Thumb(urls: urls, index: i),
          for (final url in videoUrls)
            _VideoThumb(
              url: url,
              onTap: onTapVideo == null ? null : () => onTapVideo!(url),
            ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.urls, required this.index});
  final List<Uri> urls;
  final int index;

  Uri get url => urls[index];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _ImageViewer(urls: urls, initialIndex: index),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          url.toString(),
          height: 160,
          width: 160,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _Placeholder(
              color: scheme.surfaceContainerHighest,
              child: const CircularProgressIndicator(strokeWidth: 2),
            );
          },
          errorBuilder: (context, error, stack) => _Placeholder(
            color: scheme.surfaceContainerHighest,
            child: Icon(
              Icons.broken_image_outlined,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.url, required this.onTap});
  final Uri url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 160,
        width: 160,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Icon(
                Icons.play_circle_fill,
                size: 52,
                color: scheme.primary,
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
                    _mediaFileName(url),
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
  const _Placeholder({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      width: 160,
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
    final stream = NetworkImage(
      widget.url,
    ).resolve(const ImageConfiguration());
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
