import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'post_item.dart';
import 'thread_tree.dart';

/// 返信のスワイプが成立する距離。ここまで引いて指を離すと `>>N` が入る。
///
/// 短くすると縦スクロールのついでに成立してしまい、長くすると片手で引ききれない。
const double _swipeThreshold = 56;

/// しきい値を越えた後、これ以上は引けない距離。
const double _swipeMaxDrag = 76;

/// しきい値を越えた分の減衰の強さ（大きいほどゆっくり [_swipeMaxDrag] へ
/// 近づく）。引ききった後も指なりに動き続けると、どこで成立したのか分からない。
const double _swipeDamping = 36;

/// 右へこれだけ動いたら、この行は横ドラッグから降りる
/// （[_LeftDragGestureRecognizer]）。
///
/// ドラッグが成立する距離（`kTouchSlop` = 18px）より十分手前にして、外側の
/// 「一覧へ戻る」が競り合いに勝てるようにする。指の細かい揺れでは降りない程度。
const double _swipeGiveUpDx = 4;

/// 指を離してから元の位置へ戻りきるまでの時間。
const Duration _swipeReturnDuration = Duration(milliseconds: 220);

/// 矢印を出し始める進み具合（0＝引き始め、1＝しきい値）。
///
/// ここまでは何も描かない。縦スクロールのついでに数 px 横へ動いただけで矢印が
/// ちらつくと、常時ボタンを畳んだ意味が無くなる。
const double _swipeArrowStart = 0.35;

/// スワイプ中に出る矢印の丸の直径。
const double _swipeArrowSize = 26;

/// 左へのスワイプで「このレスに返信」へ繋ぐラッパ。
///
/// 引いている間だけ中身が左へずれ、空いた右端に矢印が現れる。しきい値を越えると
/// 矢印が塗りつぶしに変わり、そこで指を離せば `>>N` がコンポーザに入る。越えた
/// 瞬間に一度だけ触覚で知らせるので、画面を見ていなくても分かる。
///
/// **レスそのものではなく、行まるごとを包むこと。** ツリー表示の字下げ帯
/// （[ThreadTreeTier]）や会話シートの枠（`_ConversationPost`）はレスの外側に
/// あるので、[PostItem] だけを包むと本文が自分の帯の下から抜け出していく。
/// 引いているのは行なので、行の持ち物は一緒に動く。
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.onReply, required this.child});

  /// 引ききって離したとき。コンポーザに `>>N` を入れる。
  final VoidCallback onReply;

  final Widget child;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  /// 指を離した後に元の位置へ戻すアニメーション。
  ///
  /// build から触らないので、フィールドの初期化子（`late final`）で作ると
  /// 一度も引かれなかったレスでは dispose の中で初めて作られることになり、
  /// 外れかけた context を引いてしまう。initState で作りきる。
  late final AnimationController _return;

  /// 指が動いた生の距離（左が正）。減衰を掛ける前の値。
  double _raw = 0;

  /// 実際にレスをずらしている距離。
  double _drag = 0;

  /// 指を離した時点の [_drag]（戻るアニメーションの始点）。
  double _returnFrom = 0;

  /// しきい値を越えているか。ここで離せば返信になる。
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _return = AnimationController(vsync: this, duration: _swipeReturnDuration)
      ..addListener(_stepBack);
  }

  @override
  void dispose() {
    _return.dispose();
    super.dispose();
  }

  void _stepBack() {
    setState(() {
      _drag = _returnFrom * (1 - Curves.easeOutCubic.transform(_return.value));
    });
  }

  void _start(DragStartDetails details) {
    // 戻っている途中で掴み直したら、その位置から続ける。
    _return.stop();
    _raw = _drag;
    _armed = false;
  }

  void _update(DragUpdateDetails details) {
    final raw = math.max(0.0, _raw - details.primaryDelta!);
    final armed = raw >= _swipeThreshold;
    // 越えた瞬間だけ合図する。指を離す前に「離せば返信になる」と分かる。
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _raw = raw;
      _drag = _resisted(raw);
      _armed = armed;
    });
  }

  void _end(DragEndDetails details) {
    if (_armed) widget.onReply();
    _settle();
  }

  /// 元の位置へ戻す。[_armed] はここでは落とさない（戻る間も成立したときの色を
  /// 残して、何が起きたか見えるようにする）。次に掴んだ時点で [_start] が落とす。
  void _settle() {
    _raw = 0;
    _returnFrom = _drag;
    if (_returnFrom == 0) return;
    _return.forward(from: 0);
  }

  /// しきい値から先は指より遅く付いてきて、[_swipeMaxDrag] へ漸近する。
  static double _resisted(double raw) {
    if (raw <= _swipeThreshold) return raw;
    final over = raw - _swipeThreshold;
    return _swipeThreshold +
        (_swipeMaxDrag - _swipeThreshold) *
            (1 - math.exp(-over / _swipeDamping));
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      // 縦スクロールや外側の横移動と競り合わせたいので、当たり判定は子に任せる。
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _LeftDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_LeftDragGestureRecognizer>(
              () => _LeftDragGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer.onStart = _start;
                recognizer.onUpdate = _update;
                recognizer.onEnd = _end;
                recognizer.onCancel = _settle;
              },
            ),
      },
      child: Stack(
        children: [
          // 行が左へ退いて空いた分だけの帯。行より先に描くので、矢印が本文に
          // 被ることはない。
          if (_drag > 0)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: _drag,
              child: IgnorePointer(
                // 帯が矢印より狭いうちは、はみ出させたまま中央に置く（右端から
                // 顔を出してくるように見える）。帯の幅で潰すと丸が歪む。
                child: OverflowBox(
                  minWidth: _swipeArrowSize,
                  maxWidth: _swipeArrowSize,
                  minHeight: _swipeArrowSize,
                  maxHeight: _swipeArrowSize,
                  child: _ReplySwipeArrow(
                    progress: (_drag / _swipeThreshold).clamp(0.0, 1.0),
                    armed: _armed,
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(-_drag, 0), child: widget.child),
        ],
      ),
    );
  }
}

/// スワイプ中に右端から現れる返信の目印。常時表示のボタンの代わりなので、
/// 引いていない間（progress が 0）は何も描かない。
class _ReplySwipeArrow extends StatelessWidget {
  const _ReplySwipeArrow({required this.progress, required this.armed});

  /// 0（引き始め）〜 1（しきい値）。
  final double progress;

  /// しきい値を越えているか。離せば返信になる状態を色で示す。
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = ((progress - _swipeArrowStart) / (1 - _swipeArrowStart))
        .clamp(0.0, 1.0);
    if (shown == 0) return const SizedBox.shrink();
    return Opacity(
      opacity: shown,
      child: Transform.scale(
        scale: 0.7 + 0.3 * shown,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 成立前は長押しの沈み込みと同じ濃さ。同じ「掴んでいる最中の影」
            // として読ませ、成立した瞬間だけ色が付く。
            color: armed
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.09),
          ),
          child: Icon(
            Icons.reply,
            size: 15,
            color: armed ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 左へ引いたときだけ成立する横ドラッグ。
///
/// 右へのスワイプは外側が「一覧へ戻る」に使っている（`BackSwipe`・スレ一覧の
/// `PageView`）。レスはそれより内側に居るぶん競り合いで先に勝ってしまうので、
/// 右へ動き始めた時点で自分から降りて外側へ譲る。
///
/// 向きを見るのは成立するまで。一度こちらが取った後は引き戻しにも付いていく
/// （[_SwipeToReplyState._update] が 0 で止める）。
class _LeftDragGestureRecognizer extends HorizontalDragGestureRecognizer {
  _LeftDragGestureRecognizer({super.debugOwner});

  /// 指（またはトラックパッドの指 2 本）を置いた位置。ここから右へどれだけ
  /// 動いたかを見る。成立したポインタは外す（それ以降は向きを見ない）。
  final _origins = <int, double>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position.dx;
    super.addAllowedPointer(event);
  }

  /// トラックパッドの 2 本指スワイプ。指と違ってポインタ自体は動かず、動いた量は
  /// [PointerPanZoomUpdateEvent.pan] で来る。macOS で戻る操作に使われる経路なので、
  /// タッチと同じように向きを見て降りる。
  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    _origins[event.pointer] = event.position.dx;
    super.addAllowedPointerPanZoom(event);
  }

  @override
  void acceptGesture(int pointer) {
    _origins.remove(pointer);
    super.acceptGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_origins.containsKey(event.pointer)) {
      final origin = _origins[event.pointer]!;
      // 置いた場所からどれだけ右へ動いたか。イベントの種類ごとに測り方が違う。
      final dx = switch (event) {
        PointerMoveEvent() => event.position.dx - origin,
        PointerPanZoomUpdateEvent() => event.pan.dx,
        _ => null,
      };
      if (dx != null && dx > _swipeGiveUpDx) {
        _origins.remove(event.pointer);
        resolve(GestureDisposition.rejected);
        return;
      }
      if (event is PointerUpEvent ||
          event is PointerCancelEvent ||
          event is PointerPanZoomEndEvent) {
        _origins.remove(event.pointer);
      }
    }
    super.handleEvent(event);
  }
}
