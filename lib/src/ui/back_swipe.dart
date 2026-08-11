import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 右へのスワイプで前の画面へ戻れるページ遷移。
///
/// 戻る操作は指に追従する（[BackSwipe] がこのルートの遷移アニメーションを直接
/// 動かす）。指を離した位置と速さで、そのまま戻るか元の位置へ戻すかが決まるので、
/// 引きかけて「やっぱりやめる」ができる。
class SwipeBackPageRoute<T> extends PageRouteBuilder<T> {
  SwipeBackPageRoute({required super.pageBuilder})
    : super(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 220),
      );

  /// スワイプで動かしている間 true。
  ///
  /// この間はカーブを掛けない。指の移動量とページの位置を 1:1 にしないと、
  /// 指の下からページがずれて「掴んでいる」感じが消えるため。
  bool swipeInProgress = false;

  /// [BackSwipe] がページを動かすためのアニメーション。
  ///
  /// [TransitionRoute.controller] はルート自身のためのものなので、外から触れる
  /// ようにここで公開する。
  AnimationController get swipeController => controller!;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(
            swipeInProgress
                ? animation
                : CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  ),
          ),
      child: child,
    );
  }
}

/// 指を離したときに「戻る」と判断する速さ（px／秒）。
///
/// 画面幅に対する割合で見ると、横に広い画面ほど強く弾かないと戻らなくなるので
/// 絶対値で見る。軽く払った程度で越える速さ。
const double _swipeBackMinFlingVelocity = 250;

/// 速さで決まらないときに戻る距離（画面幅に対する割合）。
const double _swipeBackDismissFraction = 0.2;

/// 同じく、その距離の上限。デスクトップのように横長の画面だと割合だけでは
/// 遠すぎる（半分近くまで引かされる）ので頭打ちにする。
const double _swipeBackMaxDismissDistance = 110;

/// 指を離した後、残りを動かしきるときのカーブ。
const Curve _swipeBackSettleCurve = Curves.fastLinearToSlowEaseIn;

/// [width] の画面で、ここまで引いたら離しても遷移しきる距離。
double _swipeBackDismissDistance(double width) =>
    math.min(width * _swipeBackDismissFraction, _swipeBackMaxDismissDistance);

/// 右へのスワイプで [SwipeBackPageRoute] を指に追従させて閉じる領域。
///
/// [SwipeBackPageRoute] 以外（最初のルートなど）に置かれたときは何もしない。
/// 横スワイプかどうかの判断はジェスチャの競り合いに任せるので、縦スクロールや
/// 内側の横スクロールを邪魔しない。
class BackSwipe extends StatefulWidget {
  const BackSwipe({super.key, required this.child});

  final Widget child;

  @override
  State<BackSwipe> createState() => _BackSwipeState();
}

class _BackSwipeState extends State<BackSwipe> {
  /// 掴んでいる間だけ持つ。null なら今はスワイプ中ではない。
  SwipeBackPageRoute<dynamic>? _route;
  NavigatorState? _navigator;

  /// 今この画面がスワイプで戻れる状態か。
  SwipeBackPageRoute<dynamic>? get _swipeBackRoute {
    final route = ModalRoute.of(context);
    if (route is! SwipeBackPageRoute) return null;
    if (!route.isCurrent || route.isFirst) return null;
    return route;
  }

  double get _width {
    final width = context.size?.width ?? 0;
    return width > 0 ? width : 1;
  }

  void _start(DragStartDetails details) {
    final route = _swipeBackRoute;
    if (route == null) return;
    _route = route;
    _navigator = Navigator.of(context);
    route.swipeInProgress = true;
    // 遷移アニメーションをこちらで動かす間は、ナビゲータに手動操作中だと伝える。
    _navigator!.didStartUserGesture();
  }

  void _update(DragUpdateDetails details) {
    final route = _route;
    if (route == null) return;
    final controller = route.swipeController;
    controller.value = (controller.value - details.primaryDelta! / _width)
        .clamp(0.0, 1.0);
  }

  void _end(DragEndDetails details) {
    final route = _route;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (route == null || navigator == null) return;

    final controller = route.swipeController;
    // 右向き（正）へ弾いていれば戻る。弾いていないときは引いた距離で決める。
    final velocity = details.velocity.pixelsPerSecond.dx;
    final dragged = (1 - controller.value) * _width;
    final back = velocity.abs() >= _swipeBackMinFlingVelocity
        ? velocity > 0
        : dragged >= _swipeBackDismissDistance(_width);

    if (back) {
      // 残りは pop 側の戻りアニメーションが引き継ぐ（残り距離のぶんだけ動く）。
      navigator.pop();
    } else {
      controller.animateTo(1, curve: _swipeBackSettleCurve);
    }

    if (controller.isAnimating) {
      void done(AnimationStatus status) {
        controller.removeStatusListener(done);
        route.swipeInProgress = false;
        navigator.didStopUserGesture();
      }

      controller.addStatusListener(done);
    } else {
      route.swipeInProgress = false;
      navigator.didStopUserGesture();
    }
  }

  void _cancel() {
    if (_route == null) return;
    _end(DragEndDetails(velocity: Velocity.zero));
  }

  @override
  Widget build(BuildContext context) {
    // 戻れないところ（一覧の中に置かれている等）ではジェスチャを組み立てない。
    // 何もしない認識器が横スワイプを取ってしまうと、外側の横移動が効かなくなる。
    if (_swipeBackRoute == null) return widget.child;
    return RawGestureDetector(
      // 縦スクロールや内側の横スクロールと競り合わせたいので、当たり判定は
      // 子に任せる（この領域自体は塞がない）。
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer
            >(() => HorizontalDragGestureRecognizer(debugOwner: this), (
              recognizer,
            ) {
              // 指を置いた位置から数える。既定（start）だと、ドラッグと判定
              // されるまでに動いた数十 px ぶんページが指から遅れてしまう。
              recognizer.dragStartBehavior = DragStartBehavior.down;
              recognizer.onStart = _start;
              recognizer.onUpdate = _update;
              recognizer.onEnd = _end;
              recognizer.onCancel = _cancel;
            }),
      },
      child: widget.child,
    );
  }
}
