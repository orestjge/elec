/// [RawGestureDetector] に組んだ認識器へ、端末のドラッグ判定を渡すための道具。
///
/// **[RawGestureDetector] は [DeviceGestureSettings] を配らない。** [GestureDetector]
/// は自前で `MediaQuery` から読んで各認識器に渡すが、生の方は何もしないので、
/// 渡し忘れた認識器だけが `kTouchSlop`（18px）で判定し続ける。
///
/// Android はここに端末の値（多くは 8px）を入れてくる。**スクロールや [PageView]
/// は端末の値を使う**ので、同じ指の動きでも外側が 8px で先に成立し、18px を待って
/// いる内側は競り合いに永久に負ける——Android だけでレスの左スワイプ（返信）が
/// 効かなかったのはこれで、指は動くのに外側の面が僅かに揺れるだけだった。
/// iOS・macOS は端末の値を返さないので両方 18px で揃い、この取りこぼしは出ない。
///
/// **build の中で読むこと。** 認識器を組み立てる関数（`GestureRecognizerFactory`
/// の初期化子）は [State.initState] からも呼ばれるので、その中で `MediaQuery` を
/// 引くと落ちる。読んだ値を閉じ込めて渡す。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// この端末のドラッグ判定（ジェスチャが成立するまでの距離）。
DeviceGestureSettings? deviceGesturesOf(BuildContext context) =>
    MediaQuery.maybeGestureSettingsOf(context);
