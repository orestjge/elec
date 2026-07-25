/// mp4 等の動画直リンクをアプリ内で再生する全画面プレーヤー。
///
/// これまで動画サムネのタップはブラウザへ飛ばしていたが、スレの流れを切らずに
/// 見られるよう `video_player`（Android: ExoPlayer / iOS・macOS: AVFoundation）で
/// アプリ内再生する。再生できない形式・コーデックのために「ブラウザで開く」の
/// 逃げ道は残す。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../net/auth_launcher.dart';
import 'audio_player_widget.dart';

/// [url] をアプリ内の全画面プレーヤーで開く。
///
/// [onOpenExternally] を渡すと「ブラウザで開く」をそのハンドラに委ねる（画面側の
/// ランチャーを使いたい場合）。未指定ならシステムブラウザで開く。
///
/// 遷移はフェード。スワイプで閉じるとき、映像は指を離した位置に残したまま消えて
/// ほしいので、スライド系（fullscreenDialog の下方向）だと動きが二重になる。
void openVideoPlayer(
  BuildContext context,
  Uri url, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) =>
          VideoPlayerScreen(url: url, onOpenExternally: onOpenExternally),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
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

  /// ミュートの選択はアプリ起動中は覚えておく。スレを流し見していると動画は
  /// 次々に開くので、そのたびに音が鳴る／消すのを繰り返さずに済む。
  static bool _mutedByDefault = false;

  bool _muted = _mutedByDefault;
  bool _ready = false;
  bool _failed = false;
  bool _looping = false;

  /// シークバーをドラッグ中はつまみが再生位置で飛ばないよう固定する。
  double? _dragValue;

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
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  /// 映像のどこをタップしても再生/一時停止する。操作の出し入れは再生状態に
  /// 従うので（再生中＝進捗線だけ／停止中＝操作一式）、別のトグルは持たない。
  Future<void> _togglePlay() async {
    final value = _controller.value;
    if (value.isPlaying) {
      await _controller.pause();
      return;
    }
    // 最後まで再生済み（ループ off）なら頭に戻してから再生する。
    if (!value.isLooping && value.position >= value.duration) {
      await _controller.seekTo(Duration.zero);
    }
    await _controller.play();
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

  /// 再生中以外（読み込み中・一時停止・再生終了・失敗）は「閉じる」を出す。
  /// 再生中は映像だけにしたいので出さない（タップで止めれば戻ってくる）。
  bool get _showClose => !_ready || _failed || !_controller.value.isPlaying;

  /// 閉じる。閉じられなかったとき（この画面がルートで pop 先が無い等）は、
  /// スワイプで動かしたぶんを元に戻す。放っておくとズレたまま固まって見える。
  Future<void> _close() async {
    final popped = await Navigator.of(context).maybePop();
    if (popped || !mounted) return;
    _resetDrag();
  }

  void _resetDrag() {
    setState(() {
      _dragging = false;
      _dragDy = 0;
    });
  }

  /// 上下スワイプの移動量（px）。しきい値を超えて離すと閉じる。
  double _dragDy = 0;
  bool _dragging = false;

  static const _dismissDistance = 96.0;
  static const _dismissVelocity = 700.0;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dragDy += details.delta.dy;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dragDy.abs() > _dismissDistance || velocity.abs() > _dismissVelocity) {
      _close();
      return;
    }
    // 届かなかったぶんは元の位置へ戻す（アニメーションは AnimatedSlide 側）。
    _resetDrag();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Scaffold(
      backgroundColor: Colors.black,
      // ヘッダーは置かない。閉じるのは上下スワイプ（＋停止中の×、Esc キー）。
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: Focus(
          autofocus: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: (_ready && !_failed) ? _togglePlay : null,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: AnimatedSlide(
              offset: Offset(0, height == 0 ? 0 : _dragDy / height),
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              // 引っぱるほど薄くして「離すと閉じる」を予告する。閉じるボタンも
              // 中に入れて、映像と一緒に動かす。
              child: Opacity(
                opacity: (1 - _dragDy.abs() / 320).clamp(0.5, 1.0),
                child: Stack(
                  children: [
                    Positioned.fill(child: Center(child: _content())),
                    if (_showClose)
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: IconButton(
                              tooltip: '閉じる',
                              color: Colors.white,
                              onPressed: _close,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_failed) return _Failed(onOpen: _openExternally);
    if (!_ready) return const CircularProgressIndicator();

    final value = _controller.value;
    // タップ（再生/一時停止）とスワイプ（閉じる）は画面全体で受けるので、
    // ここでは重ねるものだけを組み立てる。
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(
          aspectRatio: value.aspectRatio,
          child: VideoPlayer(_controller),
        ),
        // 読み込み待ちは操作の有無に関わらず出す（無反応に見せない）。
        if (value.isBuffering) const CircularProgressIndicator(),
        // 再生中は映像の前に何も置かず、下端の細い進捗線だけにする。止めると
        // 操作一式（中央ボタン・シークバー・時間・ミュート等）を出す。
        if (value.isPlaying)
          _ProgressLine(value: value)
        else
          _Controls(
            value: value,
            dragValue: _dragValue,
            muted: _muted,
            looping: _looping,
            onTogglePlay: _togglePlay,
            onToggleMuted: _toggleMuted,
            onToggleLooping: _toggleLooping,
            onOpenExternally: _openExternally,
            onDrag: (v) => setState(() => _dragValue = v),
            onDragEnd: (v) async {
              await _controller.seekTo(Duration(milliseconds: v.round()));
              if (mounted) setState(() => _dragValue = null);
            },
          ),
      ],
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
        const Icon(
          Icons.videocam_off_outlined,
          color: Colors.white54,
          size: 64,
        ),
        const SizedBox(height: 12),
        const Text('再生できませんでした', style: TextStyle(color: Colors.white70)),
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

/// 止まっているときの操作一式（中央の大きな再生ボタン、シークバー、時間、
/// ミュート・リピート・ブラウザ）。再生中はこれを出さず [_ProgressLine] だけに
/// する。ヘッダーを持たないぶん、操作はすべてここに集める。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.value,
    required this.dragValue,
    required this.muted,
    required this.looping,
    required this.onTogglePlay,
    required this.onToggleMuted,
    required this.onToggleLooping,
    required this.onOpenExternally,
    required this.onDrag,
    required this.onDragEnd,
  });

  final VideoPlayerValue value;
  final double? dragValue;
  final bool muted;
  final bool looping;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleMuted;
  final VoidCallback onToggleLooping;
  final VoidCallback onOpenExternally;
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
        // 次にすることが分かる大きなボタン。映像はタップしても同じ動きをする。
        Center(
          child: IconButton(
            iconSize: 64,
            color: Colors.white,
            onPressed: onTogglePlay,
            icon: Icon(
              ended ? Icons.replay_circle_filled : Icons.play_circle_fill,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            // シークバーが明るい映像に溶けないよう、下端だけ薄く落とす。
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 24, 8, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
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
                // ヘッダーの代わり。止めているときだけ出る補助操作。
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: muted ? 'ミュート解除' : 'ミュート',
                      color: Colors.white,
                      onPressed: onToggleMuted,
                      icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
                    ),
                    IconButton(
                      tooltip: looping ? 'リピート中' : 'リピート',
                      color: looping
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      onPressed: onToggleLooping,
                      icon: Icon(looping ? Icons.repeat_one : Icons.repeat),
                    ),
                    IconButton(
                      tooltip: 'ブラウザで開く',
                      color: Colors.white,
                      onPressed: onOpenExternally,
                      icon: const Icon(Icons.open_in_browser),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 再生中に下端へ出す細い進捗線。映像を隠さず、どこまで来たかだけ分かればよい
/// ので操作は受けない（タップは映像と同じく再生/一時停止に流す）。
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.value});

  final VideoPlayerValue value;

  @override
  Widget build(BuildContext context) {
    final totalMs = value.duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (value.position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 2,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation(Colors.white70),
        ),
      ),
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
