import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'audio_player_widget.dart';
import 'embed_urls.dart';
import 'format.dart';
import 'image_urls.dart';
import 'mini_player.dart';
import 'nico_thumbnail.dart';
import 'remote_image.dart';
import 'video_thumbnail.dart';

/// 画像URL群を全画面ビューアで開く。
void openImageViewer(
  BuildContext context,
  List<Uri> urls, {
  int initialIndex = 0,
}) {
  if (urls.isEmpty) return;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) =>
          _ImageViewer(urls: urls, initialIndex: initialIndex),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

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

  /// YouTube / ニコニコ動画のリンク。タップでアプリ内 WebView を開く。
  final List<EmbedVideo> embedVideos;

  /// アプリ内で再生できなかった動画をブラウザへ回すための逃げ道。
  /// 未指定ならプレーヤーに「ブラウザで開く」を出さない。
  final ValueChanged<Uri>? onOpenVideoExternally;

  final ValueChanged<EmbedVideo>? onTapEmbed;

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
                          : () => onTapEmbed!(video),
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

  void _openViewer() =>
      openImageViewer(context, widget.urls, initialIndex: widget.index);

  /// 「読み込む」を選んだ。以後この URL は上限を上げて読む。
  void _load() => setState(() => ImageLoadPolicy.allow(_url));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // グロ指定があり、まだ解除していない間だけモザイクを掛ける。最初のタップは
    // 全画面を開かず解除に使い、不意にグロ画像を大きく表示しないようにする。
    final masked = widget.blurred && !_revealed;
    // 既に大きすぎると分かっている URL は、通信する前にカードへ落とす。
    // 初めて見る URL は読みに行き、上限で弾かれたら errorBuilder が同じ絵を出す。
    final skipped = ImageLoadPolicy.skipsAutoLoad(_url);
    return GestureDetector(
      onTap: masked ? () => setState(() => _revealed = true) : _openViewer,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            if (skipped)
              _TooLargeThumb(
                size: widget.size,
                bytes: ImageLoadPolicy.knownBytes(_url),
                onLoad: _load,
              )
            else
              Image(
                image: RemoteImage(
                  _url,
                  // サムネイルは一辺 [size] の正方形に cover で敷く。物理ピクセル
                  // に直した分だけデコードすれば足りる。
                  target: Size.square(
                    widget.size * MediaQuery.devicePixelRatioOf(context),
                  ),
                  cover: true,
                  maxBytes: ImageLoadPolicy.limitFor(_url),
                ),
                height: widget.size,
                width: widget.size,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return _Placeholder(
                    size: widget.size,
                    color: scheme.surfaceContainerHighest,
                    // 何割まで来たかが分かると、止まっているのか進んでいるのか
                    // が読める。バイト数はサムネイルが小さいときは出さない。
                    child: _LoadProgress(
                      progress: progress,
                      showBytes: widget.size >= 120,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
                errorBuilder: (context, error, stack) {
                  if (error is ImageTooLargeException) {
                    return _TooLargeThumb(
                      size: widget.size,
                      bytes: error.bytes,
                      onLoad: _load,
                    );
                  }
                  return _Placeholder(
                    size: widget.size,
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
            if (masked) const Positioned.fill(child: _GuroMask()),
          ],
        ),
      ),
    );
  }
}

/// 自動読み込みを見送った画像のサムネイル枠。タップで読み込む。
class _TooLargeThumb extends StatelessWidget {
  const _TooLargeThumb({
    required this.size,
    required this.bytes,
    required this.onLoad,
  });

  final double size;

  /// 分かっていればバイト数。未知なら大きさは出さない。
  final int? bytes;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // 親（全画面を開く）へは渡さない。まず読み込むかどうかの選択が先。
      onTap: onLoad,
      child: _Placeholder(
        size: size,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                bytes == null ? '大きい画像' : '大きい画像 ${formatBytes(bytes!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                'タップで読み込む',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
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

/// YouTube / ニコニコ動画のサムネイルカード。タップでアプリ内 WebView を開く。
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
    if (direct != null) {
      return _card(context, thumbnail: Uri.tryParse(direct));
    }
    if (video.kind == EmbedKind.niconico) {
      return FutureBuilder<Uri?>(
        future: NicoThumbnails.resolve(video.id),
        builder: (context, snapshot) =>
            _card(context, thumbnail: snapshot.data),
      );
    }
    return _card(context, thumbnail: null);
  }

  Widget _card(BuildContext context, {required Uri? thumbnail}) {
    final scheme = Theme.of(context).colorScheme;
    final aspectRatio = video.kind == EmbedKind.youtube ? 16 / 9 : 1.25;
    // **幅が足りないときは高さも一緒に縮める。** 高さを固定して幅だけ詰めると、
    // ツリー表示の深いインデントや狭い端末で横長の動画が縦長のカードになり、
    // 16:9 のサムネイルが左右から大きく切り落とされる。
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: size * aspectRatio),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumbnail != null)
                  Image(
                    image: RemoteImage(
                      thumbnail,
                      target:
                          Size(size * aspectRatio, size) *
                          MediaQuery.devicePixelRatioOf(context),
                      cover: true,
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => const SizedBox(),
                  ),
                // サムネイルの上に薄い暗幕を敷き、再生アイコンと見出しを読みやすく。
                if (thumbnail != null)
                  const DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black26),
                  ),
                Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    size: 52,
                    color: thumbnail != null ? Colors.white : scheme.primary,
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
        ),
      ),
    );
  }
}

/// 読み込み中の進み具合。全体の大きさが分かっていれば「1.2MB / 3.4MB」と
/// 何割まで来たかを出す。Content-Length を返さないホストでは総量が分からない
/// ので、受け取ったぶんだけを出して回り続ける。
class _LoadProgress extends StatelessWidget {
  const _LoadProgress({
    required this.progress,
    required this.showBytes,
    required this.color,
  });

  final ImageChunkEvent progress;
  final bool showBytes;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final total = progress.expectedTotalBytes;
    final loaded = progress.cumulativeBytesLoaded;
    final ratio = total == null || total <= 0 ? null : loaded / total;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: ratio,
            color: color,
          ),
        ),
        if (showBytes) ...[
          const SizedBox(height: 8),
          Text(
            total == null
                ? formatBytes(loaded)
                : '${formatBytes(loaded)} / ${formatBytes(total)}',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ],
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
  final _activePointers = <int>{};

  /// 拡大・パンの変換。[PageView] の外側に置いた [InteractiveViewer] が持つ。
  ///
  /// ページの中に置くと、ページ送りが流れている間は [Scrollable] が中身を
  /// [IgnorePointer] で塞いでしまい、指がビューアまで届かず拡大できない。外側なら
  /// いつでも届く。ページを移ったら等倍へ戻す。
  final _view = TransformationController();

  /// 直近に見た拡大中かどうか。切り替わったときだけ組み直す。
  bool _wasZoomed = false;

  Duration? _dragStartTime;
  double _dragDx = 0;
  double _dragDy = 0;
  bool _dragging = false;
  bool _dragRejected = false;

  /// 拡大中の左右ドラッグを見張っている。指を離した時点ではみ出しが足りていれば
  /// 隣の画像へ送る。
  bool _swiping = false;

  /// 左右ドラッグを見張り始めた時点の、指の移動量と画像の位置。離した時点の値と
  /// 引き比べると「動かそうとしたのに画像が動かなかった分」＝端から引っぱった分
  /// が出る。これがページ送りの合図になる。
  double _swipeAnchorDx = 0;
  double _swipeAnchorX = 0;

  /// トラックパッドのひと続きのスクロール量と、それで既に1回効かせたか。
  Duration? _lastScrollTime;
  Offset _scrolled = Offset.zero;
  bool _scrollSpent = false;

  static const _dismissDistance = 96.0;
  static const _dismissVelocity = 700.0;
  static const _dragSlop = 8.0;

  /// 端からどれだけ引っぱったら「隣の画像へ」と受け取るか。
  static const _swipeDistance = 64.0;

  /// これだけ間が空いたらスクロールは別の操作として数え直す。
  static const _scrollGap = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    _view.addListener(_onViewChanged);
  }

  @override
  void dispose() {
    _view.removeListener(_onViewChanged);
    _view.dispose();
    _page.dispose();
    super.dispose();
  }

  Uri get _url => widget.urls[_index];

  /// 表示中のページが拡大されているか。等倍のときだけ上下スワイプを閉じる操作・
  /// 左右スワイプをページ送りに割り当て、拡大中はドラッグを画像のパンとして通す。
  bool get _zoomed => _view.value.getMaxScaleOnAxis() > 1.01;

  /// 表示中の画像が画面上で横にどこまで動いているか。端に着くと動かなくなるので、
  /// これが動かないことで「もうずらせない」と分かる。
  double get _imageX => MatrixUtils.transformPoint(_view.value, Offset.zero).dx;

  /// 見え方が変わった。等倍かどうかが切り替わったときだけ組み直す（左右スワイプの
  /// 行き先を PageView と画像のパンで入れ替えるため）。端に着いたかどうかは
  /// ドラッグ中に読むだけなので、組み直しは要らない。
  void _onViewChanged() {
    if (_zoomed == _wasZoomed) return;
    setState(() => _wasZoomed = _zoomed);
  }

  /// ページが変わった。次の画像は等倍から見せる。
  void _onPageChanged(int page) {
    setState(() {
      _view.value = Matrix4.identity();
      _index = page;
    });
  }

  Future<void> _close() async {
    final popped = await Navigator.of(context).maybePop();
    if (popped || !mounted) return;
    _resetDrag();
  }

  void _resetDrag() {
    setState(() {
      _dragStartTime = null;
      _dragDx = 0;
      _dragDy = 0;
      _dragging = false;
      _dragRejected = false;
      _swiping = false;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      // 2本目が降りた＝ピンチ。ページ送りを止めて（[_pageLocked] が立つ）指を
      // まるごと拡大縮小へ回す。止めないと PageView のドラッグが先に成立して
      // しまい、拡大が効かないままページだけ動くことがある。
      _resetDrag();
      _dragRejected = true;
      return;
    }
    _dragStartTime = event.timeStamp;
    _dragDx = 0;
    _dragDy = 0;
    _dragging = false;
    _swiping = false;
    _dragRejected = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointers.length != 1 || _dragRejected) return;
    final nextDx = _dragDx + event.delta.dx;
    final nextDy = _dragDy + event.delta.dy;
    final absDx = nextDx.abs();
    final absDy = nextDy.abs();
    if (!_dragging && !_swiping && math.max(absDx, absDy) > _dragSlop) {
      if (absDx > absDy) {
        // 横向き。等倍なら PageView がそのままページ送りに使う。拡大中は画像の
        // パンに任せつつ、端に着いてからのはみ出しだけ数える。
        if (!_zoomed) {
          _dragRejected = true;
          return;
        }
        _swiping = true;
        // この時点の指と画像の位置を控える。どちらもまだこのイベント分は動いて
        // いない（画像を動かすのは下の InteractiveViewer で、こちらが先に呼ばれ
        // る）ので、離した時点の値と素直に引き比べられる。
        _swipeAnchorDx = _dragDx;
        _swipeAnchorX = _imageX;
      } else {
        // 縦向き。拡大中は「画像をずらして確認する」操作なので閉じる判定に使わ
        // ない。等倍へ戻す（ピンチアウト）と再び上下スワイプで閉じられる。
        if (_zoomed) {
          _dragRejected = true;
          return;
        }
        _dragging = true;
      }
    }
    if (!_dragging) {
      _dragDx = nextDx;
      _dragDy = nextDy;
      return;
    }
    setState(() {
      _dragDx = nextDx;
      _dragDy = nextDy;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_swiping) {
      // 指が動いた分のうち、画像が動かなかった分＝端から引っぱった分。
      final overscroll = (_dragDx - _swipeAnchorDx) - (_imageX - _swipeAnchorX);
      if (overscroll.abs() > _swipeDistance) {
        _turnPage(overscroll < 0 ? 1 : -1);
      }
    } else if (_dragging) {
      final elapsed = event.timeStamp - (_dragStartTime ?? event.timeStamp);
      final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final velocity = seconds <= 0 ? 0 : _dragDy / seconds;
      if (_dragDy.abs() > _dismissDistance ||
          velocity.abs() > _dismissVelocity) {
        _close();
        return;
      }
    }
    if (_activePointers.isEmpty) _resetDrag();
  }

  /// トラックパッドの2本指スクロール。デスクトップではドラッグの代わりにこれが
  /// 来るので、横は隣の画像へ、縦は閉じる操作に割り当てる。マウスホイールは
  /// InteractiveViewer の拡大縮小なので触らない。
  ///
  /// 指を離す合図が無いので、溜まった時点で1回だけ効かせ、慣性が止む（間が空く）
  /// まで次を受け取らない。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.kind != PointerDeviceKind.trackpad) return;
    final last = _lastScrollTime;
    _lastScrollTime = event.timeStamp;
    if (last == null || event.timeStamp - last > _scrollGap) {
      _scrolled = Offset.zero;
      _scrollSpent = false;
    }
    if (_scrollSpent) return;
    _scrolled += event.scrollDelta;
    if (_scrolled.dx.abs() > _scrolled.dy.abs()) {
      // 横。等倍なら PageView がそのまま送るので、拡大中だけ引き取る。
      if (!_zoomed || _scrolled.dx.abs() <= _swipeDistance) return;
      _scrollSpent = true;
      _turnPage(_scrolled.dx < 0 ? -1 : 1);
    } else {
      // 縦。拡大中は画像を上下にずらして見る操作なので閉じない。
      if (_zoomed || _scrolled.dy.abs() <= _swipeDistance) return;
      _scrollSpent = true;
      _close();
    }
  }

  /// 隣の画像へ送る。等倍のスワイプと同じく、最初と最後では巻き戻さずそこで
  /// 止まる（巡回するのは左右のボタンだけ）。
  void _turnPage(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.urls.length) return;
    _jumpBy(delta);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) _resetDrag();
  }

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

  /// ページ送りを PageView に任せない状態か。拡大中は指を画像のパンに使い、
  /// ピンチ中は拡大縮小に使う。
  bool get _pageLocked => _zoomed || _activePointers.length > 1;

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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            onPointerSignal: _onPointerSignal,
            child: AnimatedSlide(
              offset: Offset(0, height == 0 ? 0 : _dragDy / height),
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: Opacity(
                opacity: (1 - _dragDy.abs() / 320).clamp(0.5, 1.0),
                child: Stack(
                  children: [
                    InteractiveViewer(
                      transformationController: _view,
                      minScale: 1,
                      maxScale: 5,
                      child: PageView.builder(
                        controller: _page,
                        itemCount: widget.urls.length,
                        // 拡大中は PageView にページ送りをさせない。指の動きは
                        // 画像をずらして見る操作に使い、端まで寄せ切ってからの
                        // スワイプだけ [_onPointerUp] が隣の画像へ回す。
                        physics: _pageLocked
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, i) => _ViewerImage(
                          url: widget.urls[i],
                          onDismiss: _close,
                        ),
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
              ),
            ),
          );
        },
      ),
    );
  }

  String _fileName(Uri url) => _mediaFileName(url);
}

String _mediaFileName(Uri url) =>
    url.pathSegments.isNotEmpty ? url.pathSegments.last : url.host;

/// ビューアの 1 ページ。画像の外側（余白）タップで閉じられる。
///
/// 拡大縮小・パンは親（[PageView] の外側の [InteractiveViewer]）が受け持つので、
/// ここは表示だけを見る。
class _ViewerImage extends StatefulWidget {
  const _ViewerImage({required this.url, required this.onDismiss});
  final Uri url;
  final VoidCallback onDismiss;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  RemoteImage? _provider;
  Size? _imageSize;

  /// 大きすぎて自動読み込みを見送った。タップされるまで通信しない。
  bool _tooLarge = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateProvider();
  }

  /// 「読み込む」を選んだ。以後この URL は上限を上げて読む。
  void _load() {
    ImageLoadPolicy.allow(widget.url);
    setState(() => _tooLarge = false);
    _updateProvider();
  }

  /// 画面いっぱいの表示に必要な分だけデコードする provider を組み直し、
  /// 原寸の縦横比を取りに行く（余白タップで閉じる判定に使う）。
  ///
  /// 表示に使う provider と同じものを見るのが要点。標準の [NetworkImage] を
  /// 別に resolve すると、原寸デコードがもう 1 枚メモリに載ってしまう。
  void _updateProvider() {
    if (_tooLarge || ImageLoadPolicy.skipsAutoLoad(widget.url)) {
      _tooLarge = true;
      return;
    }
    final media = MediaQuery.of(context);
    final target = media.size * media.devicePixelRatio;
    final provider = RemoteImage(
      widget.url,
      target: target,
      maxBytes: ImageLoadPolicy.limitFor(widget.url),
    );
    if (provider == _provider) return;
    _provider = provider;

    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        // 縮めてデコードしていても縦横比は変わらないので、fit 矩形はこれで出せる。
        setState(() {
          _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      },
      onError: (error, _) {
        if (!mounted) return;
        setState(() => _tooLarge = error is ImageTooLargeException);
      },
    );
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
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
    // 拡大縮小は親が外側で掛けているので、ここに届く位置は既に変換前の座標。
    // 画像矩形の外なら閉じる。
    if (!_fittedRect(viewport).contains(position)) widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (_tooLarge) {
      return _TooLargeImage(
        bytes: ImageLoadPolicy.knownBytes(widget.url),
        onLoad: _load,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: _provider!,
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Center(
                      child: _LoadProgress(
                        progress: progress,
                        showBytes: true,
                        color: Colors.white70,
                      ),
                    ),
              errorBuilder: (context, error, stack) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 64,
                ),
              ),
            ),
            // 画像より上に薄いレイヤーを重ね、タップだけを拾う。
            // ピンチ・パンは外側の InteractiveViewer に流れる。
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

/// 全画面ビューアで、自動読み込みを見送った画像に出す案内。
class _TooLargeImage extends StatelessWidget {
  const _TooLargeImage({required this.bytes, required this.onLoad});

  /// 分かっていればバイト数。
  final int? bytes;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, color: Colors.white54, size: 64),
          const SizedBox(height: 12),
          Text(
            bytes == null
                ? '大きい画像なので読み込んでいません'
                : '${formatBytes(bytes!)} の大きい画像です',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onLoad, child: const Text('読み込む')),
        ],
      ),
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
