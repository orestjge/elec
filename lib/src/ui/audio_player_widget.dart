import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// レス本文中の音声 URL をその場で再生するインライン・ミニプレーヤー。
///
/// [AudioPlayer] は再生ボタンを押すまで生成しない（レスが多くても
/// 無駄にネイティブプレーヤーを確保しない）。別のタイルが再生を始めたら
/// 直前まで鳴っていたものは自動で一時停止する。
class AudioPlayerTile extends StatefulWidget {
  const AudioPlayerTile({super.key, required this.url});

  final Uri url;

  @override
  State<AudioPlayerTile> createState() => _AudioPlayerTileState();
}

class _AudioPlayerTileState extends State<AudioPlayerTile> {
  /// 現在（最後に）再生を開始したタイル。新しく再生を始める前に止める。
  static _AudioPlayerTileState? _active;

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  bool _loading = false;
  bool _failed = false;
  bool _playing = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration? _duration;

  /// スライダーをドラッグ中は position の更新でつまみが飛ばないよう固定する。
  double? _dragValue;

  String get _fileName => widget.url.pathSegments.isNotEmpty
      ? widget.url.pathSegments.last
      : widget.url.host;

  @override
  void dispose() {
    if (_active == this) _active = null;
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    final player = AudioPlayer();
    _player = player;
    _stateSub = player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state.playing;
        _completed = state.processingState == ProcessingState.completed;
        _loading =
            state.processingState == ProcessingState.loading ||
            state.processingState == ProcessingState.buffering;
      });
    });
    _positionSub = player.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });
    _durationSub = player.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur);
    });
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await player.setUrl(widget.url.toString());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    if (_failed) {
      // 失敗後の再タップはやり直し。プレーヤーを作り直す。
      await _reset();
    }
    await _ensurePlayer();
    final player = _player;
    if (player == null || _failed) return;

    if (_playing) {
      await player.pause();
      return;
    }

    // 別タイルが鳴っていたら止めてから再生する。
    if (_active != null && _active != this) {
      await _active!._player?.pause();
    }
    _active = this;
    if (_completed) await player.seek(Duration.zero);
    await player.play();
  }

  Future<void> _reset() async {
    await _stateSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _player?.dispose();
    _player = null;
    _stateSub = null;
    _positionSub = null;
    _durationSub = null;
    if (mounted) {
      setState(() {
        _failed = false;
        _playing = false;
        _completed = false;
        _position = Duration.zero;
        _duration = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final duration = _duration ?? Duration.zero;
    final maxMs = duration.inMilliseconds.toDouble();
    final posMs = _position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    final sliderValue = _dragValue ?? posMs;

    return SizedBox(
      width: 260,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _toggle,
                  color: scheme.primary,
                  icon: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _failed
                              ? Icons.refresh
                              : _playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          size: 32,
                        ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
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
                      onChanged: (_failed || maxMs == 0)
                          ? null
                          : (v) => setState(() => _dragValue = v),
                      onChangeEnd: (_failed || maxMs == 0)
                          ? null
                          : (v) async {
                              await _player?.seek(
                                Duration(milliseconds: v.round()),
                              );
                              if (mounted) setState(() => _dragValue = null);
                            },
                    ),
                  ),
                ),
                Text(
                  maxMs == 0
                      ? _fmt(_position)
                      : '${_fmt(Duration(milliseconds: sliderValue.round()))}'
                            ' / ${_fmt(duration)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.audiotrack,
                    size: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _failed ? '再生できませんでした（タップで再試行）' : _fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _failed ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
