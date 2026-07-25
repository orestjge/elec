/// mp4 等の動画直リンクをアプリ内で再生する全画面プレーヤー。
///
/// これまで動画サムネのタップはブラウザへ飛ばしていたが、スレの流れを切らずに
/// 見られるよう `video_player`（Android: ExoPlayer / iOS・macOS: AVFoundation）で
/// アプリ内再生する。再生できない形式・コーデックのために「ブラウザで開く」の
/// 逃げ道は残す。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../net/auth_launcher.dart';
import 'audio_player_widget.dart';

/// [url] をアプリ内の全画面プレーヤーで開く。
///
/// [onOpenExternally] を渡すと「ブラウザで開く」をそのハンドラに委ねる（画面側の
/// ランチャーを使いたい場合）。未指定ならシステムブラウザで開く。
void openVideoPlayer(
  BuildContext context,
  Uri url, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          VideoPlayerScreen(url: url, onOpenExternally: onOpenExternally),
    ),
  );
}

/// 動画 URL を全画面で再生する画面。
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.url,
    this.onOpenExternally,
  });

  final Uri url;

  /// 「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenExternally;

  /// テスト間でセッションのミュート設定（画面をまたいで覚えている）を戻す。
  @visibleForTesting
  static void debugResetMuted() =>
      _VideoPlayerScreenState._mutedByDefault = false;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller;

  /// コントロールを自動で隠すまでの時間。再生中だけ作動する。
  static const _autoHide = Duration(seconds: 3);

  /// ミュートの選択はアプリ起動中は覚えておく。スレを流し見していると動画は
  /// 次々に開くので、そのたびに音が鳴る／消すのを繰り返さずに済む。
  static bool _mutedByDefault = false;

  bool _muted = _mutedByDefault;
  bool _ready = false;
  bool _failed = false;
  bool _controlsVisible = true;
  bool _looping = false;
  Timer? _hideTimer;

  /// シークバーをドラッグ中はつまみが再生位置で飛ばないよう固定する。
  double? _dragValue;

  String get _fileName => widget.url.pathSegments.isNotEmpty
      ? widget.url.pathSegments.last
      : widget.url.host;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(widget.url)
      ..addListener(_onControllerUpdate);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
    } catch (_) {
      // 非対応コーデック・到達不可・削除済みなど。ブラウザへの逃げ道を案内する。
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() => _ready = true);
    await _controller.setVolume(_muted ? 0 : 1);
    // 本文の音声ミニプレーヤーが鳴っていたら止める（音が重ならないように）。
    await AudioPlayerTile.pauseActive();
    await _controller.play();
    _scheduleHide();
  }

  /// 再生位置・バッファ状態の更新をそのまま画面へ反映する。
  void _onControllerUpdate() {
    if (!mounted) return;
    if (_controller.value.hasError && !_failed) {
      setState(() => _failed = true);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controller.value.isPlaying) return;
    _hideTimer = Timer(_autoHide, () {
      if (!mounted || !_controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final value = _controller.value;
    if (value.isPlaying) {
      _hideTimer?.cancel();
      await _controller.pause();
      return;
    }
    // 最後まで再生済み（ループ off）なら頭に戻してから再生する。
    if (!value.isLooping && value.position >= value.duration) {
      await _controller.seekTo(Duration.zero);
    }
    await _controller.play();
    if (mounted) {
      setState(() => _controlsVisible = true);
      _scheduleHide();
    }
  }

  Future<void> _toggleMuted() async {
    final next = !_muted;
    await _controller.setVolume(next ? 0 : 1);
    _mutedByDefault = next;
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _toggleLooping() async {
    final next = !_looping;
    await _controller.setLooping(next);
    if (mounted) setState(() => _looping = next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          // ミュートはコントロールを隠していても押せるよう AppBar に置く。
          IconButton(
            tooltip: _muted ? 'ミュート解除' : 'ミュート',
            onPressed: _ready ? _toggleMuted : null,
            icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
          ),
          IconButton(
            tooltip: _looping ? 'リピート中' : 'リピート',
            onPressed: _ready ? _toggleLooping : null,
            icon: Icon(_looping ? Icons.repeat_one : Icons.repeat),
            color: _looping ? Theme.of(context).colorScheme.primary : null,
          ),
          IconButton(
            tooltip: 'ブラウザで開く',
            onPressed: _openExternally,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
      ),
      body: Center(child: _body()),
    );
  }

  Widget _body() {
    if (_failed) return _Failed(onOpen: _openExternally);
    if (!_ready) return const CircularProgressIndicator();

    final value = _controller.value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
          // 読み込み待ちは操作の有無に関わらず出す（無反応に見せない）。
          if (value.isBuffering) const CircularProgressIndicator(),
          AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: _Controls(
                value: value,
                dragValue: _dragValue,
                onTogglePlay: _togglePlay,
                onDrag: (v) => setState(() => _dragValue = v),
                onDragEnd: (v) async {
                  await _controller.seekTo(Duration(milliseconds: v.round()));
                  if (mounted) setState(() => _dragValue = null);
                  _scheduleHide();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openExternally() {
    final handler = widget.onOpenExternally;
    if (handler != null) {
      handler(widget.url);
      return;
    }
    const SystemBrowserLauncher().open(widget.url);
  }
}

/// 再生に失敗したときの表示。ブラウザへの逃げ道を出す。
class _Failed extends StatelessWidget {
  const _Failed({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 64),
        const SizedBox(height: 12),
        const Text(
          '再生できませんでした',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_browser),
          label: const Text('ブラウザで開く'),
        ),
      ],
    );
  }
}

/// 中央の再生/一時停止ボタンと、下部のシークバー。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.value,
    required this.dragValue,
    required this.onTogglePlay,
    required this.onDrag,
    required this.onDragEnd,
  });

  final VideoPlayerValue value;
  final double? dragValue;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final duration = value.duration;
    final maxMs = duration.inMilliseconds.toDouble();
    final posMs = value.position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    final sliderValue = dragValue ?? posMs;
    final ended = !value.isLooping && maxMs > 0 && posMs >= maxMs;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 操作系を読みやすくする薄い暗幕。
        const DecoratedBox(decoration: BoxDecoration(color: Colors.black26)),
        Center(
          child: IconButton(
            iconSize: 64,
            color: Colors.white,
            onPressed: onTogglePlay,
            icon: Icon(
              value.isPlaying
                  ? Icons.pause_circle_filled
                  : ended
                  ? Icons.replay_circle_filled
                  : Icons.play_circle_fill,
            ),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    value: sliderValue.clamp(0, maxMs == 0 ? 1 : maxMs),
                    max: maxMs == 0 ? 1 : maxMs,
                    onChanged: maxMs == 0 ? null : onDrag,
                    onChangeEnd: maxMs == 0 ? null : onDragEnd,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${formatVideoTime(Duration(milliseconds: sliderValue.round()))}'
                ' / ${formatVideoTime(duration)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ],
    );
  }
}

/// `m:ss`（1 時間以上は `h:mm:ss`）で再生時間を表す。
String formatVideoTime(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours == 0) return '${d.inMinutes}:$ss';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
}
