/// YouTube / ニコニコ動画などのサービス動画をアプリ内で再生する WebView。
///
/// 画面ではなく [MiniPlayerHost] に置かれる部品で、全画面と小窓の両方で使う。
/// 開くのは `mini_player.dart` の `openEmbedPlayer`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../net/auth_launcher.dart';
import 'embed_urls.dart';

@visibleForTesting
TargetPlatform? debugEmbedPlayerTargetPlatform;

/// アプリ内 WebView でサービス動画を再生できるか。macOS には WebView の実装が
/// 無いので、その場合はブラウザへ回す。
bool get supportsEmbedWebView {
  return switch (debugEmbedPlayerTargetPlatform ?? defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

/// 映像を**この画面の中で**鳴らすための WebView の作り方。
///
/// 共通の API には無く、プラットフォームの実装に直接触るしかない設定が 2 つある。
///
/// - iOS: `allowsInlineMediaPlayback` を立てないと、映像は WebView の中ではなく
///   OS のフルスクリーンプレーヤーで開く。小窓に落としても映像が付いてこない。
/// - iOS: `mediaTypesRequiringUserAction` を空にして自動再生を許す（Android は
///   `AndroidWebViewController` 側の設定なので、コントローラを作ってから）。
///
/// 実装が入れ替わっていた場合（テストのフェイクなど）は既定の引数で作る。
PlatformWebViewControllerCreationParams _mediaPlaybackParams() {
  if (WebViewPlatform.instance is WebKitWebViewPlatform) {
    return WebKitWebViewControllerCreationParams(
      allowsInlineMediaPlayback: true,
      mediaTypesRequiringUserAction: <PlaybackMediaTypes>{},
    );
  }
  return const PlatformWebViewControllerCreationParams();
}

/// サービス動画を再生する WebView と、その周りの操作。
///
/// [mini] のときは**映像だけ**を出す。小窓の操作（移動・全画面へ戻す・閉じる）は
/// [MiniPlayerHost] 側が映像の上に敷くので、ここでは何も重ねない。
class EmbedPlayerView extends StatefulWidget {
  const EmbedPlayerView({
    super.key,
    required this.video,
    required this.onClose,
    required this.onMinimize,
    this.mini = false,
    this.onOpenExternally,
  });

  final EmbedVideo video;

  /// 再生をやめる。
  final VoidCallback onClose;

  /// 小窓へ落とす（再生は続く）。
  final VoidCallback onMinimize;

  /// 小窓として描くかどうか。
  final bool mini;

  /// 「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenExternally;

  @override
  State<EmbedPlayerView> createState() => _EmbedPlayerViewState();
}

class _EmbedPlayerViewState extends State<EmbedPlayerView> {
  late final WebViewController _controller;
  var _progress = 0;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    final controller = WebViewController.fromPlatformCreationParams(
      _mediaPlaybackParams(),
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _failed = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            if (mounted) setState(() => _failed = true);
          },
        ),
      );
    // Android は**読み込む前に**許しておく（後から変えても、すでに動いている
    // ページの自動再生には効かない）。
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    controller.loadRequest(
      widget.video.playerUrl,
      headers: embedPlayerRequestHeaders(widget.video),
    );
    _controller = controller;
  }

  void _openExternally() {
    final handler = widget.onOpenExternally;
    if (handler != null) {
      handler(widget.video.url);
      return;
    }
    const SystemBrowserLauncher().open(widget.video.url);
  }

  @override
  Widget build(BuildContext context) {
    final mini = widget.mini;
    // **WebView の居場所を全画面と小窓で変えない。** 組み直すとネイティブの
    // WebView ごと作り直され、再生が頭に戻る。ノッチ避けも SafeArea を出し入れ
    // せず、常に居る Padding の値だけを切り替える。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: EmbedSwipeArea(
          // **小窓では見張らない**（窓の移動・全画面へ戻す・閉じるはホスト側が
          // 持つ）。全画面ならサービスを問わず見張る——どちらも出しているのは
          // 埋め込みプレーヤーで、縦に流れるものが無い。
          enabled: !mini,
          onMinimize: widget.onMinimize,
          onClose: widget.onClose,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // **枠は切らない（映像の比率に合わせない）。** 埋め込みプレーヤー
              // は渡した枠に映像を収めるので、縦長の枠でも映像の大きさは同じ
              // （幅なり）——変わるのは YouTube 側が出す操作の方で、枠を 16:9 に
              // 切ると「小さな埋め込み」と見なされて操作が詰まり、触れるのも
              // 真ん中の帯だけになる。枠いっぱいを渡せば題名バーと大きな
              // シークバーが付き、画面のどこを触っても操作が出る。
              //
              // 引き換えに、再生前のサムネイルは縦長の枠いっぱいに出る。
              // `autoplay=1`（`embed_urls.dart`）で開いた直後だけの絵なので、
              // 見ている間ずっと効く操作の方を取る。
              Padding(
                padding: mini ? EdgeInsets.zero : MediaQuery.paddingOf(context),
                child: WebViewWidget(controller: _controller),
              ),
              if (!mini) ...[
                if (_progress < 100 && !_failed)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_failed)
                  Center(
                    child: _FailedEmbed(
                      label: widget.video.label,
                      onRetry: () => _controller.loadRequest(
                        widget.video.playerUrl,
                        headers: embedPlayerRequestHeaders(widget.video),
                      ),
                      onOpenExternally: _openExternally,
                    ),
                  ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _chromeButton(
                            tooltip: '閉じる',
                            icon: Icons.close,
                            onPressed: widget.onClose,
                          ),
                          const SizedBox(width: 4),
                          // 下スワイプの近道は [EmbedSwipeArea] にあるが、指で
                          // 覚えるまで見えない操作なのでボタンも残す（ニコニコは
                          // こちらだけ）。
                          _chromeButton(
                            tooltip: '小さくする',
                            icon: Icons.picture_in_picture_alt,
                            onPressed: widget.onMinimize,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _chromeButton(
                        tooltip: 'ブラウザで開く',
                        icon: Icons.open_in_browser,
                        onPressed: _openExternally,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chromeButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    tooltip: tooltip,
    color: Colors.white,
    style: IconButton.styleFrom(
      backgroundColor: Colors.black.withValues(alpha: 0.45),
    ),
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

/// 全画面の映像を上下スワイプで畳めるようにする層。**下＝小窓へ、上＝終了**で、
/// mp4 のプレーヤー（`video_player_view.dart`）と同じ割り当てにしてある。
///
/// **指の取り合いには参加しない。** WebView は降りた指を自分のものにするので、
/// [GestureDetector] を重ねると再生／一時停止もシークも効かなくなる。[Listener]
/// は当たり判定の道すじに居るだけで生のポインタを覗ける——指は WebView にも
/// そのまま流れるので、向こうの操作は今までどおり動く。
///
/// 覗いた指を畳む操作と読むのは、**縦に大きく動いたときだけ**。滑り出しが横なら
/// シークバーのものとして手を引く（少し動いた時点の向きで一度決めたら、途中で
/// 向きが変わっても取り上げない）。2本目が降りたら WebView の拡大縮小なので、
/// そこでも手を引く。
///
/// [enabled] が false のときは何もしないが、**ウィジェットの木からは外さない**。
/// この上下に居る WebView を組み直すと再生が頭に戻るので、小窓⇔全画面や種別で
/// 包みを出し入れしてはいけない。
@visibleForTesting
class EmbedSwipeArea extends StatefulWidget {
  const EmbedSwipeArea({
    super.key,
    required this.enabled,
    required this.onMinimize,
    required this.onClose,
    required this.child,
  });

  /// 上下スワイプを見張るか。
  final bool enabled;

  /// 下へ払った。小窓へ落とす（再生は続く）。
  final VoidCallback onMinimize;

  /// 上へ払った。再生をやめる。
  final VoidCallback onClose;

  final Widget child;

  @override
  State<EmbedSwipeArea> createState() => _EmbedSwipeAreaState();
}

class _EmbedSwipeAreaState extends State<EmbedSwipeArea> {
  /// しきい値は mp4 のプレーヤーと同じ値に揃える（同じ操作なので手応えも同じに）。
  static const _dismissDistance = 96.0;
  static const _dismissVelocity = 700.0;
  static const _dragSlop = 8.0;

  final _pointers = <int>{};
  Duration? _dragStart;
  double _dragDx = 0;
  double _dragDy = 0;
  bool _dragging = false;
  bool _rejected = false;

  void _resetDrag({bool rejected = false}) {
    if (!mounted) return;
    setState(() {
      _dragStart = null;
      _dragDx = 0;
      _dragDy = 0;
      _dragging = false;
      _rejected = rejected;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      // 2本目＝WebView 側のピンチ。指はまるごと向こうへ渡す。
      _resetDrag(rejected: true);
      return;
    }
    _dragStart = event.timeStamp;
    _dragDx = 0;
    _dragDy = 0;
    _dragging = false;
    _rejected = !widget.enabled;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointers.length != 1 || _rejected) return;
    final nextDx = _dragDx + event.delta.dx;
    final nextDy = _dragDy + event.delta.dy;
    if (!_dragging) {
      final absDx = nextDx.abs();
      final absDy = nextDy.abs();
      if (absDx <= _dragSlop && absDy <= _dragSlop) {
        // まだ向きが決まらない。動いた分だけ控えて次を待つ。
        _dragDx = nextDx;
        _dragDy = nextDy;
        return;
      }
      // 横向きに滑り出した指は WebView のもの（シークバー等）。
      if (absDx >= absDy) {
        _rejected = true;
        return;
      }
      _dragging = true;
    }
    setState(() {
      _dragDx = nextDx;
      _dragDy = nextDy;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_dragging) {
      final elapsed = event.timeStamp - (_dragStart ?? event.timeStamp);
      final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final velocity = seconds <= 0 ? 0.0 : _dragDy / seconds;
      final farEnough = _dragDy.abs() > _dismissDistance;
      if (farEnough || velocity.abs() > _dismissVelocity) {
        final down = farEnough ? _dragDy > 0 : velocity > 0;
        // 小窓は元の姿勢で出したいので、動かしたぶんは先に戻しておく。
        _resetDrag();
        if (down) {
          widget.onMinimize();
        } else {
          widget.onClose();
        }
        return;
      }
    }
    // 届かなかったぶんは元の位置へ戻す（アニメーションは [AnimatedSlide] 側）。
    if (_pointers.isEmpty) _resetDrag();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) _resetDrag();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Listener(
      // 枠いっぱいで受ける（子が当たり判定を持たない隙間でも指を拾う）。
      // [HitTestBehavior.opaque] でも子は先に当たり判定に入るので、WebView から
      // 指を取り上げはしない。
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: AnimatedSlide(
        offset: Offset(0, height == 0 ? 0 : _dragDy / height),
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        // 引っぱるほど薄くして「離すと決まる」を予告する。
        child: Opacity(
          opacity: (1 - _dragDy.abs() / 320).clamp(0.5, 1.0),
          child: widget.child,
        ),
      ),
    );
  }
}

@visibleForTesting
Map<String, String> embedPlayerRequestHeaders(EmbedVideo video) {
  if (video.kind != EmbedKind.youtube) return const {};
  return const {
    // YouTube embed は Android WebView など Referer が空になり得る環境で
    // Error 153 になるため、アプリの origin を明示して読み込む。
    'Referer': 'https://io.github.orestjge.elec/',
  };
}

class _FailedEmbed extends StatelessWidget {
  const _FailedEmbed({
    required this.label,
    required this.onRetry,
    required this.onOpenExternally,
  });

  final String label;
  final VoidCallback onRetry;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.public_off, color: Colors.white54, size: 64),
          const SizedBox(height: 12),
          Text(
            '$label を読み込めませんでした',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('再読み込み'),
              ),
              TextButton.icon(
                onPressed: onOpenExternally,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('ブラウザで開く'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
