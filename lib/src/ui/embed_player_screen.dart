/// YouTube / ニコニコ動画などのサービス動画をアプリ内で開く WebView 画面。
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../net/auth_launcher.dart';
import 'embed_urls.dart';

void openEmbedPlayer(
  BuildContext context,
  EmbedVideo video, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  if (!_supportsEmbedWebView) {
    if (onOpenExternally != null) {
      onOpenExternally(video.url);
    } else {
      const SystemBrowserLauncher().open(video.url);
    }
    return;
  }

  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) =>
          EmbedPlayerScreen(video: video, onOpenExternally: onOpenExternally),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

@visibleForTesting
TargetPlatform? debugEmbedPlayerTargetPlatform;

bool get _supportsEmbedWebView {
  return switch (debugEmbedPlayerTargetPlatform ?? defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

class EmbedPlayerScreen extends StatefulWidget {
  const EmbedPlayerScreen({
    super.key,
    required this.video,
    this.onOpenExternally,
  });

  final EmbedVideo video;
  final ValueChanged<Uri>? onOpenExternally;

  @override
  State<EmbedPlayerScreen> createState() => _EmbedPlayerScreenState();
}

class _EmbedPlayerScreenState extends State<EmbedPlayerScreen> {
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
      ..loadRequest(widget.video.playerUrl);
  }

  Future<void> _close() => Navigator.of(context).maybePop();

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
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              SafeArea(child: WebViewWidget(controller: _controller)),
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
                    onRetry: () =>
                        _controller.loadRequest(widget.video.playerUrl),
                    onOpenExternally: _openExternally,
                  ),
                ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      tooltip: '閉じる',
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                      ),
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      tooltip: 'ブラウザで開く',
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                      ),
                      onPressed: _openExternally,
                      icon: const Icon(Icons.open_in_browser),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
