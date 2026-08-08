/// mp4 等の動画直リンクをアプリ内で再生するプレーヤー。
///
/// これまで動画サムネのタップはブラウザへ飛ばしていたが、スレの流れを切らずに
/// 見られるよう `video_player`（Android: ExoPlayer / iOS・macOS: AVFoundation）で
/// アプリ内再生する。再生できない形式・コーデックのために「ブラウザで開く」の
/// 逃げ道は残す。
///
/// 画面ではなく [MiniPlayerHost] に置かれる部品で、全画面と小窓の両方で使う。
/// 開くのは `mini_player.dart` の `openVideoPlayer`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../net/auth_launcher.dart';
import 'audio_player_widget.dart';

/// 動画 URL を再生する部品。
///
/// [mini] のときは**映像だけ**を出す。小窓の操作（移動・全画面へ戻す・閉じる）は
/// [MiniPlayerHost] 側が映像の上に敷くので、ここでは何も重ねない。
class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({
    super.key,
    required this.url,
    required this.onClose,
    required this.onMinimize,
    this.mini = false,
    this.title,
    this.onOpenExternally,
  });

  final Uri url;

  /// 操作一式と一緒に出す見出し（`2/5  clip.mp4`）。ビューアの並びの中で
  /// いま何本目を見ているかを示す。**ヘッダーとして常に出しはしない**——
  /// 映像を隠さないために、他の操作と同じくタップで出し入れする。
  final String? title;

  /// 再生をやめる。
  final VoidCallback onClose;

  /// 小窓へ落とす（再生は続く）。
  final VoidCallback onMinimize;

  /// 小窓として描くかどうか。
  final bool mini;

  /// 「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenExternally;

  /// テスト間でセッションのミュート設定（動画をまたいで覚えている）を戻す。
  @visibleForTesting
  static void debugResetMuted() =>
      _VideoPlayerViewState._mutedByDefault = false;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  late final VideoPlayerController _controller;

  /// ミュートの選択はアプリ起動中は覚えておく。スレを流し見していると動画は
  /// 次々に開くので、そのたびに音が鳴る／消すのを繰り返さずに済む。
  static bool _mutedByDefault = false;

  bool _muted = _mutedByDefault;
  bool _ready = false;
  bool _failed = false;
  bool _looping = false;

  /// 操作一式を出しているか。**タップで出し入れする**（再生は止まらない）。
  /// こうしないと、止めないと閉じる・小さくするに手が届かない＝「流しながら
  /// 小窓にする」ができない。
  bool _controlsVisible = false;

  /// 再生中に出した操作を自動で引っ込めるためのタイマー。
  Timer? _hideTimer;

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
    // 最後まで来たら操作を出す。次にすること（もう一度見る・閉じる）が
    // すぐ選べるようにするため。
    if (_ended && !_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
      return;
    }
    setState(() {});
  }

  /// 最後まで再生し終えて止まっている（ループ off）。
  bool get _ended {
    final value = _controller.value;
    return _ready &&
        !value.isPlaying &&
        !value.isLooping &&
        value.duration > Duration.zero &&
        value.position >= value.duration;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  /// 映像のどこをタップしても**操作一式を出し入れする**（再生は止めない）。
  /// 止めるのは操作の中央ボタン。
  void _toggleControls() {
    if (!_ready || _failed) return;
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleAutoHide();
  }

  /// 再生中に出した操作は数秒で引っ込める（映像を隠し続けない）。止めていると
  /// きは触りたいはずなので消さない。
  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible || !_controller.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
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
    _scheduleAutoHide();
  }

  Future<void> _toggleMuted() async {
    final next = !_muted;
    await _controller.setVolume(next ? 0 : 1);
    _mutedByDefault = next;
    if (mounted) setState(() => _muted = next);
    _scheduleAutoHide();
  }

  Future<void> _toggleLooping() async {
    final next = !_looping;
    await _controller.setLooping(next);
    if (mounted) setState(() => _looping = next);
    _scheduleAutoHide();
  }

  /// 操作一式（と閉じる・小さくする）を出すか。読み込み中と失敗時は、逃げ道が
  /// 要るので常に出す。
  bool get _showChrome => !_ready || _failed || _controlsVisible;

  void _resetDrag() {
    setState(() {
      _dragging = false;
      _dragDy = 0;
    });
  }

  /// 上下スワイプの移動量（px）。しきい値を超えて離すと確定する。
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

  /// **下＝小窓へ、上＝終了。** 指の向きと結果を合わせる（下へ払うと下へ縮む）。
  /// ボタン（タップで出る▼と×）と同じことができる近道で、見ている流れを
  /// 止めずに畳める。
  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    final farEnough = _dragDy.abs() > _dismissDistance;
    if (!farEnough && velocity.abs() <= _dismissVelocity) {
      // 届かなかったぶんは元の位置へ戻す（アニメーションは AnimatedSlide 側）。
      _resetDrag();
      return;
    }
    final down = farEnough ? _dragDy > 0 : velocity > 0;
    // 小窓は元の姿勢で出したいので、動かしたぶんは先に戻しておく
    // （onClose の後は State ごと消えるので setState できない）。
    _resetDrag();
    if (down) {
      widget.onMinimize();
    } else {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 小窓では中身に触らせない（窓の移動・全画面へ戻す・閉じるはホスト側が持つ）。
    if (widget.mini) return Center(child: _content(compact: true));

    final height = MediaQuery.sizeOf(context).height;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        // ヘッダーは置かない。閉じるのは上スワイプ（＋タップで出る×、Esc キー）、
        // 小窓へ落とすのは下スワイプ（＋タップで出る▼、戻るキー）。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: AnimatedSlide(
            offset: Offset(0, height == 0 ? 0 : _dragDy / height),
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            // 引っぱるほど薄くして「離すと決まる」を予告する。ボタンも中に
            // 入れて、映像と一緒に動かす。
            child: Opacity(
              opacity: (1 - _dragDy.abs() / 320).clamp(0.5, 1.0),
              child: Stack(
                children: [
                  Positioned.fill(child: Center(child: _content())),
                  if (_showChrome)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '閉じる',
                                color: Colors.white,
                                onPressed: widget.onClose,
                                icon: const Icon(Icons.close),
                              ),
                              IconButton(
                                tooltip: '小さくする',
                                color: Colors.white,
                                onPressed: widget.onMinimize,
                                icon: const Icon(Icons.keyboard_arrow_down),
                              ),
                              if (widget.title case final title?)
                                Flexible(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                            ],
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
    );
  }

  /// [compact] は小窓。操作は重ねず、下端の進捗線だけ残す（どこまで来たかは
  /// 小さくても読めるし、面積も取らない）。
  Widget _content({bool compact = false}) {
    if (_failed) {
      return compact
          ? const Icon(Icons.videocam_off_outlined, color: Colors.white54)
          : _Failed(onOpen: _openExternally);
    }
    if (!_ready) {
      return const SizedBox.square(
        dimension: 32,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final value = _controller.value;
    // タップ（再生/一時停止）とスワイプ（閉じる・小窓へ）は画面全体で受けるので、
    // ここでは重ねるものだけを組み立てる。
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(
          aspectRatio: value.aspectRatio,
          child: VideoPlayer(_controller),
        ),
        // 読み込み待ちは操作の有無に関わらず出す（無反応に見せない）。
        if (value.isBuffering)
          const SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        // 操作を出していない間は映像の前に何も置かず、下端の細い進捗線だけ。
        // タップで操作一式（中央ボタン・シークバー・時間・ミュート等）を出す。
        if (compact || !_showChrome)
          _ProgressLine(value: value)
        else
          _Controls(
            value: value,
            ended: _ended,
            dragValue: _dragValue,
            muted: _muted,
            looping: _looping,
            onTogglePlay: _togglePlay,
            onToggleMuted: _toggleMuted,
            onToggleLooping: _toggleLooping,
            onOpenExternally: _openExternally,
            onDrag: (v) {
              _hideTimer?.cancel();
              setState(() => _dragValue = v);
            },
            onDragEnd: (v) async {
              await _controller.seekTo(Duration(milliseconds: v.round()));
              if (mounted) setState(() => _dragValue = null);
              _scheduleAutoHide();
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

/// タップで出る操作一式（中央の大きな再生/一時停止ボタン、シークバー、時間、
/// ミュート・リピート・ブラウザ）。出していない間は [_ProgressLine] だけにする。
/// ヘッダーを持たないぶん、操作はすべてここに集める。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.value,
    required this.ended,
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

  /// 最後まで再生し終えて止まっている（中央ボタンを「もう一度」にする）。
  final bool ended;

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

    return Stack(
      fit: StackFit.expand,
      children: [
        // 次にすることが分かる大きなボタン。映像はタップしても同じ動きをする。
        Center(
          child: IconButton(
            iconSize: 64,
            color: Colors.white,
            onPressed: onTogglePlay,
            icon: Icon(switch ((value.isPlaying, ended)) {
              (true, _) => Icons.pause_circle_filled,
              (false, true) => Icons.replay_circle_filled,
              (false, false) => Icons.play_circle_fill,
            }),
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

/// 再生中（と小窓）に下端へ出す細い進捗線。映像を隠さず、どこまで来たかだけ
/// 分かればよいので操作は受けない。
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
