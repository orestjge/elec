/// YouTube / ニコニコ動画などのサービス動画をアプリ内で再生する WebView。
///
/// 画面ではなく [MiniPlayerHost] に置かれる部品で、全画面と小窓の両方で使う。
/// 開くのは `mini_player.dart` の `openEmbedPlayer`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
    _controller = WebViewController()
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
      )
      ..loadRequest(
        widget.video.playerUrl,
        headers: embedPlayerRequestHeaders(widget.video),
      );
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
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: mini ? EdgeInsets.zero : MediaQuery.paddingOf(context),
              child: frameEmbedSurface(
                widget.video,
                WebViewWidget(controller: _controller),
              ),
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
                        // WebView は指を取るのでスワイプで畳めない。小窓へ
                        // 落とす操作はボタンで出す。
                        _chromeButton(
                          tooltip: '小さくする',
                          icon: Icons.keyboard_arrow_down,
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

/// 映像を出す枠。
///
/// **YouTube の埋め込みプレーヤーは渡した枠に映像を収める。** 縦画面いっぱいの
/// WebView を渡すと、その縦長の枠に 16:9 を収めた絵——上下に大きな黒帯、
/// 再生前のサムネイルも縦長の枠の中——になる。枠のほうを 16:9 に切って中央に
/// 置けば、映像とサムネイルが枠いっぱいに出る（mp4 のプレーヤーが
/// `AspectRatio` で映像の比率どおりに出しているのと同じ考え）。
///
/// **ニコニコは枠を切らない。** 出しているのは動画だけでなく watch ページ
/// そのもの（コメント欄も含む）なので、画面いっぱいのほうが読める。
///
/// 小窓は枠自体が 16:9 なので、どちらの経路でも見た目は変わらない。
@visibleForTesting
Widget frameEmbedSurface(EmbedVideo video, Widget surface) {
  if (video.kind != EmbedKind.youtube) return surface;
  // Center を挟むのは AspectRatio に緩い制約を渡すため（きつい制約のままだと
  // AspectRatio は枠の大きさをそのまま返して何も効かない）。
  return Center(
    child: AspectRatio(aspectRatio: 16 / 9, child: surface),
  );
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
