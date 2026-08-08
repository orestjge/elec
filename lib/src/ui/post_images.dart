import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/auth_launcher.dart';
import '../net/image_fingerprint.dart';
import '../net/ng_store.dart';
import 'audio_player_widget.dart';
import 'embed_urls.dart';
import 'format.dart';
import 'image_urls.dart';
import 'media_scrim.dart';
import 'media_url_panel.dart';
import 'mini_player.dart';
import 'nico_thumbnail.dart';
import 'remote_image.dart';
import 'video_player_view.dart';
import 'video_thumbnail.dart';

/// 全画面ビューアが送る 1 件。画像と動画をひと続きの並びに混ぜるための型。
sealed class ViewerMedia {
  const ViewerMedia(this.url);

  final Uri url;
}

/// 直リンクの画像。
class ViewerImageMedia extends ViewerMedia {
  const ViewerImageMedia(super.url);
}

/// 直リンクの動画（mp4 等）。
class ViewerVideoMedia extends ViewerMedia {
  const ViewerVideoMedia(super.url);
}

/// レス本文から、ビューアで送る並びを本文の出現順どおりに組む。
List<ViewerMedia> viewerMediaIn(String text) => [
  for (final url in mediaUrlsIn(text))
    if (isVideoUrl(url)) ViewerVideoMedia(url) else ViewerImageMedia(url),
];

/// [urls] を全画面ビューアで開く（画像だけの並び）。
void openImageViewer(
  BuildContext context,
  List<Uri> urls, {
  int initialIndex = 0,
  ValueChanged<Uri>? onOpenExternally,
}) => openMediaViewer(
  context,
  [for (final url in urls) ViewerImageMedia(url)],
  initialIndex: initialIndex,
  onOpenExternally: onOpenExternally,
);

/// 画像・動画の並びを全画面ビューアで開く。
///
/// ビューアは Navigator ではなく [MiniPlayerHost] の層に載る。動画を小窓へ
/// 落としても再生器を作り直さずに済ませるためで、詳しくは `mini_player.dart`。
///
/// [onOpenExternally] を渡すと「ブラウザで開く」をそのハンドラに委ねる。
/// 未指定ならシステムブラウザで開く。
void openMediaViewer(
  BuildContext context,
  List<ViewerMedia> items, {
  int initialIndex = 0,
  ValueChanged<Uri>? onOpenExternally,
}) {
  if (items.isEmpty) return;
  MiniPlayerController.shared.open(
    context,
    SequenceMedia(items, onOpenExternally: onOpenExternally),
    initialIndex: initialIndex.clamp(0, items.length - 1),
  );
}

/// ビューアの「ブラウザで開く」に渡すハンドラを組む。
///
/// 画像は呼び出し側の処理（アプリ内の URL 振り分け）へ渡してよいが、**動画は
/// 既定でシステムブラウザへ回す**。振り分けは動画 URL を見るとアプリ内プレーヤー
/// へ送り返すので、そのまま渡すとビューアからビューアへ戻る堂々巡りになる。
ValueChanged<Uri> viewerBrowserHandoff(
  ValueChanged<Uri>? onImage,
  ValueChanged<Uri>? onVideo,
) => (url) {
  final handler = isVideoUrl(url) ? onVideo : onImage;
  if (handler != null) {
    handler(url);
    return;
  }
  const SystemBrowserLauncher().open(url);
};

/// [url] を頭にして [items] を開く。並びに無い URL はそれ 1 件だけを開く。
void openViewerAt(
  BuildContext context,
  List<ViewerMedia> items,
  Uri url, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  final index = items.indexWhere((item) => item.url == url);
  if (index < 0) {
    openMediaViewer(context, [
      if (isVideoUrl(url)) ViewerVideoMedia(url) else ViewerImageMedia(url),
    ], onOpenExternally: onOpenExternally);
    return;
  }
  openMediaViewer(
    context,
    items,
    initialIndex: index,
    onOpenExternally: onOpenExternally,
  );
}

/// [url] の画像を NG に登録する。登録できたら、その内容を返す（取り消し用）。
///
/// 指紋は本文からしか採れない。表示済みの画像なら本文は手元（メモリかディスク）
/// にあるので、通信はしない。手元に無ければ何もできないので null を返す。
Future<NgImage?> addNgImage(Uri url) async {
  final bytes = await RemoteImage.cachedBytes(url);
  if (bytes == null || bytes.isEmpty) return null;
  final fingerprint =
      ImageFingerprintIndex.shared.get(url) ??
      await computeImageFingerprint(bytes);
  if (fingerprint == null) return null;
  ImageFingerprintIndex.shared.put(url, fingerprint);
  final image = NgImage.from(
    fingerprint,
    thumbnail: await makeNgThumbnail(bytes),
  );
  await NgStore.shared.addImage(image);
  _evictDecodedImages();
  return image;
}

/// NG を解除して、伏せた画像を出し直す。
Future<void> removeNgImage(NgImage image) async {
  await NgStore.shared.removeImage(image);
  _evictDecodedImages();
}

/// 確認してから NG に登録する。登録できたら true。
///
/// 本文が手元に無い（まだ読み込めていない）画像は NG にできない。指紋を採れない
/// ので、黙って何もしないのではなく理由を出す。
Future<bool> confirmAddNgImage(BuildContext context, Uri url) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('この画像をNG'),
      content: const Text('同じ画像は、次から別の URL で貼られても隠します。貼り直しで多少変わった画像も隠します。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('NGにする'),
        ),
      ],
    ),
  );
  if (agreed != true || !context.mounted) return false;

  final messenger = ScaffoldMessenger.maybeOf(context);
  final image = await addNgImage(url);
  if (image == null) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('まだ読み込めていない画像はNGにできません')),
    );
    return false;
  }
  messenger?.showSnackBar(
    SnackBar(
      content: const Text('この画像をNGにしました'),
      // 操作の付いた通知は既定で出しっぱなしになる（[SnackBar.persist] は
      // action があると true）。取り消しは「今すぐ気が変わったら」のためのもので、
      // 押さなかった人の画面に居座らせる意味は無い。他の通知と同じく時間で消す。
      persist: false,
      // 消えるのを待たずに退けられるようにする。取り消す気は無いのに、
      // 見たい画像の上に数秒居座られるのは鬱陶しい。
      showCloseIcon: true,
      action: SnackBarAction(
        label: '取り消し',
        onPressed: () => unawaited(removeNgImage(image)),
      ),
    ),
  );
  return true;
}

/// 確認してから NG を解除する。
Future<void> confirmRemoveNgImage(BuildContext context, Uri url) async {
  final image = NgStore.shared.ngImageForUrl(url);
  if (image == null) return;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('この画像のNGを解除'),
      content: const Text('隠していた画像をまた表示します。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('解除'),
        ),
      ],
    ),
  );
  if (agreed == true) await removeNgImage(image);
}

/// デコード済みの画像を捨てて、NG 判定を掛け直させる。
///
/// [ImageCache] は URL と目標サイズを鍵に**デコード済みの絵**を持っている。
/// NG にした瞬間はそれが残っているので、捨てないと画面に出たままになる。
/// 利用者が明示的に NG にしたときだけ通るので、丸ごと捨ててよい（本文は
/// 手元に残っているから、出し直しに通信は要らない）。
void _evictDecodedImages() {
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
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
    this.onOpenImageExternally,
    this.onTapEmbed,
    this.onRemove,
    this.viewerMedia,
    this.thumbSize = 160,
    this.blurImages = false,
  });

  final List<Uri> urls;

  /// 全画面ビューアで巡回する並び。未指定なら [urls]＋[videoUrls] を並べたもの。
  ///
  /// 本文の途中にサムネイルを差し込むと [urls] はレスの一部だけになる。どの
  /// サムネイルから開いてもレス内の全メディアを送れるよう、ここへレス全体の
  /// 並びを渡す。タップした URL がこの並びに無ければ、その 1 件だけを開く。
  final List<ViewerMedia>? viewerMedia;

  /// 本文中の動画 URL。タップでアプリ内の全画面プレーヤーを開く。
  final List<Uri> videoUrls;

  /// 本文中の音声 URL。インラインのミニプレーヤーで再生する。
  final List<Uri> audioUrls;

  /// YouTube / ニコニコ動画のリンク。タップでアプリ内 WebView を開く。
  final List<EmbedVideo> embedVideos;

  /// アプリ内で再生できなかった動画をブラウザへ回すための逃げ道。
  /// 未指定ならプレーヤーに「ブラウザで開く」を出さない。
  final ValueChanged<Uri>? onOpenVideoExternally;

  /// 全画面ビューアの「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenImageExternally;

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
    // ビューアの並び。レス全体を渡されていないとき（入力欄の添付プレビュー等）は
    // ここに出ているぶんだけを、サムネイルと同じ並び順で送る。
    final sequence =
        viewerMedia ??
        [
          for (final url in urls) ViewerImageMedia(url),
          for (final url in videoUrls) ViewerVideoMedia(url),
        ];
    final openExternally = viewerBrowserHandoff(
      onOpenImageExternally,
      onOpenVideoExternally,
    );
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
                for (final url in urls)
                  _removable(
                    url,
                    _Thumb(
                      url: url,
                      sequence: sequence,
                      size: thumbSize,
                      blurred: blurImages,
                      // 入力欄の添付プレビューでは NG の出番が無い。
                      canNg: onRemove == null,
                      onOpenExternally: openExternally,
                    ),
                  ),
                for (final url in videoUrls)
                  _removable(
                    url,
                    _VideoThumb(
                      url: url,
                      sequence: sequence,
                      size: thumbSize,
                      onOpenExternally: openExternally,
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
    required this.url,
    required this.sequence,
    this.size = 160,
    this.blurred = false,
    this.canNg = true,
    this.onOpenExternally,
  });
  final Uri url;

  /// タップで開く全画面ビューアの並び（[PostImages.viewerMedia] 参照）。
  final List<ViewerMedia> sequence;
  final double size;

  /// 「グロ」注意が付いた画像で、初期表示をモザイクにするか。
  final bool blurred;

  /// 長押しで NG に登録できるか。
  final bool canNg;

  /// 全画面ビューアの「ブラウザで開く」の実処理（[PostImages.onOpenImageExternally]）。
  final ValueChanged<Uri>? onOpenExternally;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  /// モザイクを一度タップで解除したか。解除後は通常どおりタップで全画面表示。
  bool _revealed = false;

  Uri get _url => widget.url;

  void _openViewer() => openViewerAt(
    context,
    widget.sequence,
    _url,
    onOpenExternally: widget.onOpenExternally,
  );

  /// 「読み込む」を選んだ。以後この URL は上限を上げて読む。
  void _load() => setState(() => ImageLoadPolicy.allow(_url));

  Future<void> _confirmNg() => confirmAddNgImage(context, _url);

  @override
  Widget build(BuildContext context) {
    // NG 画像の増減で伏せ札に切り替わる（ビューア側で NG にした直後も含む）。
    return ListenableBuilder(
      listenable: NgStore.shared,
      builder: (context, _) => _buildThumb(context),
    );
  }

  Widget _buildThumb(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 指紋を覚えている URL なら、通信も描画もせずに伏せ札を出す。
    if (NgStore.shared.isNgImageUrl(_url)) {
      return _NgThumb(size: widget.size, url: _url);
    }
    // グロ指定があり、まだ解除していない間だけモザイクを掛ける。最初のタップは
    // 全画面を開かず解除に使い、不意にグロ画像を大きく表示しないようにする。
    final masked = widget.blurred && !_revealed;
    // 既に大きすぎると分かっている URL は、通信する前にカードへ落とす。
    // 初めて見る URL は読みに行き、上限で弾かれたら errorBuilder が同じ絵を出す。
    final skipped = ImageLoadPolicy.skipsAutoLoad(_url);
    return GestureDetector(
      onTap: masked ? () => setState(() => _revealed = true) : _openViewer,
      onLongPress: widget.canNg ? _confirmNg : null,
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
                  // 中身を見て初めて NG と分かった。デコード前に弾いているので、
                  // 絵は一度も出ていない。
                  if (error is ImageNgException) {
                    return _NgThumb(size: widget.size, url: _url);
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

/// NG にした画像の代わりに出す伏せ札。タップで解除できる。
class _NgThumb extends StatelessWidget {
  const _NgThumb({required this.size, required this.url});

  final double size;
  final Uri url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // 全画面には開かない。伏せている画像を開けてしまっては意味がない。
      onTap: () => unawaited(confirmRemoveNgImage(context, url)),
      child: _Placeholder(
        size: size,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hide_image_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                'NG画像',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (size >= 120) ...[
                const SizedBox(height: 2),
                Text(
                  'タップで解除',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.primary),
                ),
              ],
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
    required this.sequence,
    required this.onOpenExternally,
    this.size = 160,
  });
  final Uri url;

  /// タップで開く全画面ビューアの並び（[PostImages.viewerMedia] 参照）。
  final List<ViewerMedia> sequence;

  /// プレーヤー側の「ブラウザで開く」に渡すハンドラ。
  final ValueChanged<Uri>? onOpenExternally;
  final double size;

  /// アプリ内の全画面ビューアを開く。ブラウザへは飛ばさない。
  void _open(BuildContext context) =>
      openViewerAt(context, sequence, url, onOpenExternally: onOpenExternally);

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

/// 画像と動画をひと続きに送る全画面ビューア。画像はピンチズーム・パン可能。
///
/// **画面ではなく [MiniPlayerHost] に置かれる部品**で、全画面と小窓の両方で使う
/// （開くのは [openMediaViewer]）。小窓へ落としても [VideoPlayerView] の State
/// ＝再生器を作り直さないよう、[PageView] は常に組み立ての同じ位置に置き、
/// 上に重ねるもの（題名・◀▶）だけを出し入れする。
class MediaViewerView extends StatefulWidget {
  const MediaViewerView({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.onClose,
    required this.onMinimize,
    required this.onIndexChanged,
    this.mini = false,
    this.onOpenExternally,
  });

  final List<ViewerMedia> items;
  final int initialIndex;

  /// ビューアを閉じる。
  final VoidCallback onClose;

  /// 表示中の動画を小窓へ落とす（再生は続く）。
  final VoidCallback onMinimize;

  /// ページが変わった。戻るキーの行き先（動画なら小窓・画像なら終了）を
  /// 決めるために [MiniPlayerController] へ伝える。
  final ValueChanged<int> onIndexChanged;

  /// 小窓として描くかどうか。送りも操作も出さず、表示中のページだけを映す。
  final bool mini;

  /// 「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenExternally;

  @override
  State<MediaViewerView> createState() => _MediaViewerViewState();
}

class _MediaViewerViewState extends State<MediaViewerView> {
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

  /// ポインタを止めてからこれだけ経ったら、操作一式を引っ込める。
  static const _hoverLinger = Duration(seconds: 3);

  /// 画像のページで操作一式（題名バー・◀▶）を出しているか。
  ///
  /// **既定では何も重ねない。** ◀▶ を絵の左右に置きっぱなしにすると、送るのは
  /// 一瞬なのに見ている間じゅう邪魔になる。絵をタップすると出て、もう一度で
  /// 引っ込む——動画のページ（[VideoPlayerView]）と同じ規則に揃えてある。
  ///
  /// 出したままにするのは、静止画には「流れている」状態が無いため。動画のように
  /// 時間で引っ込めると、見比べている最中に消えてしまう。
  bool _imageChrome = false;

  /// 動画のページで [VideoPlayerView] が操作一式を出しているか（あちらから
  /// 知らせてもらう）。◀▶ は種別によらず操作一式と一緒に出す。
  bool _videoChrome = false;

  /// 題名をタップして URL 全体を開いているか（`media_url_panel.dart`）。
  bool _urlOpen = false;

  bool get _chromeVisible => _onVideo ? _videoChrome : _imageChrome;

  /// マウス（トラックパッド）を止めてから引っ込めるまでのタイマー。
  ///
  /// タッチでは hover が来ないので、これはポインタのある環境専用の道になる。
  Timer? _hoverTimer;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    _view.addListener(_onViewChanged);
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _view.removeListener(_onViewChanged);
    _view.dispose();
    _page.dispose();
    super.dispose();
  }

  /// 絵をタップした。操作一式を出し入れする（絵の外側のタップは閉じる操作なので、
  /// ここへは来ない）。
  void _toggleChrome() {
    _hoverTimer?.cancel();
    setState(() {
      _imageChrome = !_imageChrome;
      // 引っ込めたら URL も畳む。次に出したときは題名だけの姿から始める。
      if (!_imageChrome) _urlOpen = false;
    });
  }

  /// 題名をタップした。URL 全体を出し入れする。
  void _toggleUrl() {
    // マウスで見ているときは、手を止めると操作一式ごと消える。URL を読んでいる
    // 最中に消えないよう、開けている間は引っ込め待ちを止めておく。
    _hoverTimer?.cancel();
    setState(() => _urlOpen = !_urlOpen);
  }

  /// ポインタが動いた。マウスで見ているなら送るボタンが要るので出し、手を止めた
  /// ら引っ込める。タッチ端末では hover 自体が来ない。
  void _onHover(PointerHoverEvent event) {
    if (widget.mini || _onVideo) return;
    if (!_imageChrome) setState(() => _imageChrome = true);
    _hoverTimer?.cancel();
    // URL を開けている間は引っ込めない。読んでいる最中に消えられると困る。
    if (_urlOpen) return;
    _hoverTimer = Timer(_hoverLinger, () {
      if (mounted) setState(() => _imageChrome = false);
    });
  }

  void _onVideoChrome(bool visible) {
    if (_videoChrome == visible || !mounted) return;
    setState(() => _videoChrome = visible);
  }

  ViewerMedia get _current => widget.items[_index];
  Uri get _url => _current.url;

  /// 表示中が動画のページか。動画では拡大せず、上下ドラッグもタップも
  /// [VideoPlayerView] の側が受け持つので、こちらは指に触らない。
  bool get _onVideo => _current is ViewerVideoMedia;

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
    widget.onIndexChanged(page);
  }

  /// 表示中の画像をブラウザへ回す。アプリ内で読めない（大きすぎる・壊れている・
  /// 対応していない形式）ときの逃げ道であり、保存や共有もブラウザ側に任せられる。
  void _openExternally() {
    final handler = widget.onOpenExternally;
    if (handler != null) {
      handler(_url);
      return;
    }
    const SystemBrowserLauncher().open(_url);
  }

  /// いま見ている画像を NG にする。伏せた画像を開いたままにしておく意味は
  /// 無いので、登録できたらビューアを閉じる。
  Future<void> _ngCurrent() async {
    // この層は Navigator の外にいるので、ダイアログを出す文脈は
    // [MiniPlayerController] が覚えているものを借りる。
    final host = MiniPlayerController.shared.dialogContext ?? context;
    final added = await confirmAddNgImage(host, _url);
    if (added) widget.onClose();
  }

  void _close() => widget.onClose();

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
    // 動画のページでは指に触らない。左右は PageView がそのまま送り、上下
    // （下＝小窓・上＝終了）とタップは [VideoPlayerView] が受け持つ。
    _dragRejected = _onVideo;
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
    // 動画は拡大しないので横スクロールは PageView がそのまま送る。縦で終わらせ
    // ないのは、見ている最中に触れただけで再生が消えると困るため。
    if (_onVideo) return;
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
    if (next < 0 || next >= widget.items.length) return;
    _jumpBy(delta);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) _resetDrag();
  }

  void _jumpBy(int delta) {
    if (widget.items.length <= 1) return;
    final next = (_index + delta) % widget.items.length;
    final normalized = next < 0 ? widget.items.length - 1 : next;
    _page.animateToPage(
      normalized,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// ページ送りを PageView に任せない状態か。拡大中は指を画像のパンに使い、
  /// ピンチ中は拡大縮小に使う。
  bool get _pageLocked => _zoomed || _activePointers.length > 1;

  /// 題名（`2/5  clip.mp4`）。1 件だけならファイル名だけを出す。
  String get _title {
    final name = _mediaFileName(_url);
    if (widget.items.length <= 1) return name;
    return '${_index + 1}/${widget.items.length}  $name';
  }

  /// 1 ページぶんの中身。
  ///
  /// 動画は**表示中のページだけ**プレーヤーにする。裏のページまで再生器を作ると
  /// 通信も音も増えるので、そちらは先頭フレームのポスターに留める。
  Widget _buildPage(int i) {
    final item = widget.items[i];
    return switch (item) {
      ViewerImageMedia() => _ViewerImage(
        url: item.url,
        onDismiss: _close,
        onTap: _toggleChrome,
      ),
      ViewerVideoMedia() when i != _index => _ViewerVideoPoster(url: item.url),
      ViewerVideoMedia() => VideoPlayerView(
        url: item.url,
        mini: widget.mini,
        title: _title,
        onClose: widget.onClose,
        onMinimize: widget.onMinimize,
        onChromeVisibilityChanged: _onVideoChrome,
        onOpenExternally: widget.onOpenExternally,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final multiple = widget.items.length > 1;
    final height = MediaQuery.sizeOf(context).height;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      onPointerSignal: _onPointerSignal,
      // マウスで見ているなら送るボタンが要る。タッチでは hover が来ないので、
      // この道は自然とポインタのある環境だけのものになる。
      onPointerHover: _onHover,
      child: AnimatedSlide(
        offset: Offset(0, height == 0 ? 0 : _dragDy / height),
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: Opacity(
          opacity: (1 - _dragDy.abs() / 320).clamp(0.5, 1.0),
          // **[PageView] は必ず children[0]。** 小窓へ落とすときに重ねるものが
          // 減るだけで済ませ、[VideoPlayerView] の State ＝再生器を作り直さない。
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _view,
                minScale: 1,
                maxScale: 5,
                // 動画は拡大しない（映像は原寸を持たないので拡げても粗くなる
                // だけで、指はプレーヤーの操作に要る）。
                panEnabled: !_onVideo,
                scaleEnabled: !_onVideo,
                child: PageView.builder(
                  controller: _page,
                  itemCount: widget.items.length,
                  // 拡大中は PageView にページ送りをさせない。指の動きは画像を
                  // ずらして見る操作に使い、端まで寄せ切ってからのスワイプだけ
                  // [_onPointerUp] が隣のページへ回す。小窓では送らせない
                  // （窓の中の操作はホスト側が全部引き取る）。
                  physics: _pageLocked || widget.mini
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, i) => _buildPage(i),
                ),
              ),
              // 動画のページでは題名も閉じるも [VideoPlayerView] の操作一式に
              // 入っている（タップで出し入れする）。二重に出さない。
              if (!widget.mini && !_onVideo && _imageChrome)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TopScrim(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppBar(
                          backgroundColor: Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          leading: IconButton(
                            tooltip: '閉じる',
                            onPressed: _close,
                            icon: const Icon(Icons.close),
                          ),
                          // 題名は真ん中。動画のページ（`VideoPlayerView` が
                          // 自前で組む行）と揃える——同じ並びを送っている最中に
                          // 題名の位置が変わると、送るたびに目が泳ぐ。
                          centerTitle: true,
                          // 題名はタップの的。ファイル名だけでは元が分からない
                          // ので、押すと URL 全体が下に開く。
                          title: MediaTitleButton(
                            title: _title,
                            open: _urlOpen,
                            onTap: _toggleUrl,
                          ),
                          actions: [
                            IconButton(
                              tooltip: 'この画像をNG',
                              onPressed: _ngCurrent,
                              icon: const Icon(Icons.hide_image_outlined),
                            ),
                            IconButton(
                              tooltip: 'ブラウザで開く',
                              onPressed: _openExternally,
                              icon: const Icon(Icons.open_in_browser),
                            ),
                          ],
                        ),
                        if (_urlOpen) MediaUrlPanel(url: _url),
                        // 溶けきるための余地。ここまで暗幕は伸びるが、絵の上に
                        // 乗るものは無い（指も素通りする）。
                        const SizedBox(height: TopScrim.fadeTail),
                      ],
                    ),
                  ),
                ),
              // ◀▶ は操作一式の一部。種別を問わず、出しているときだけ添える。
              if (!widget.mini && multiple && _chromeVisible) ...[
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
  }
}

/// 送り先の動画ページ（まだ表示中ではないもの）に敷く先頭フレーム。
///
/// 裏のページで再生器を作らないための代わりで、絵はサムネイルと同じものを使う。
class _ViewerVideoPoster extends StatelessWidget {
  const _ViewerVideoPoster({required this.url});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    if (!VideoThumbnails.isSupported) return const _VideoPosterFrame();
    return FutureBuilder<Uint8List?>(
      future: VideoThumbnails.resolve(url),
      builder: (context, snapshot) => _VideoPosterFrame(frame: snapshot.data),
    );
  }
}

class _VideoPosterFrame extends StatelessWidget {
  const _VideoPosterFrame({this.frame});

  final Uint8List? frame;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (frame != null)
          Image.memory(
            frame!,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const SizedBox(),
          ),
        const Center(
          child: Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
        ),
      ],
    );
  }
}

String _mediaFileName(Uri url) =>
    url.pathSegments.isNotEmpty ? url.pathSegments.last : url.host;

/// ビューアの 1 ページ。画像の外側（余白）タップで閉じられる。
///
/// 拡大縮小・パンは親（[PageView] の外側の [InteractiveViewer]）が受け持つので、
/// ここは表示だけを見る。
class _ViewerImage extends StatefulWidget {
  const _ViewerImage({
    required this.url,
    required this.onDismiss,
    required this.onTap,
  });
  final Uri url;

  /// 絵の外側（余白）をタップした。閉じる。
  final VoidCallback onDismiss;

  /// 絵そのものをタップした。操作一式を出し入れする。
  final VoidCallback onTap;

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
    // 画像矩形の外なら閉じる。中なら操作一式の出し入れ。
    if (_fittedRect(viewport).contains(position)) {
      widget.onTap();
    } else {
      widget.onDismiss();
    }
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
              errorBuilder: (context, error, stack) => error is ImageNgException
                  ? _NgImage(url: widget.url)
                  : const Center(
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

/// 全画面ビューアで、NG にした画像の代わりに出す案内。
class _NgImage extends StatelessWidget {
  const _NgImage({required this.url});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.hide_image_outlined,
            color: Colors.white54,
            size: 64,
          ),
          const SizedBox(height: 12),
          const Text('NGにした画像です', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => unawaited(confirmRemoveNgImage(context, url)),
            child: const Text('NGを解除'),
          ),
        ],
      ),
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
