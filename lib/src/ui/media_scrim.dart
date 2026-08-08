/// 全画面の絵・映像の上に操作を重ねるときに敷く、上端の暗幕。
///
/// **濃さは保ったまま、下端だけ溶かす。** 一様な半透明の帯を置くと、絵の途中に
/// 横一文字の切れ目が入って「板を貼った」ように見える。文字とアイコンが乗って
/// いるあいだは同じ濃さで支え、そこから下へ抜けるあいだで透明にすると、境目が
/// どこか分からなくなる。映像の下端に敷いているシークバーの暗幕（
/// `video_player_view.dart` の `_Controls`）と同じ考えで、向きだけが逆。
library;

import 'package:flutter/material.dart';

/// [child]（題名バーや操作の行）の背後に敷く、上が濃く下へ抜ける暗幕。
///
/// **抜け方は直線ではなく S 字**にしてある。濃さを保ってから一定の割合で薄くして
/// いくと、透明に着く場所で傾きが折れる。そこだけ濃さの変わり方が急に止まるので、
/// **抜けきる手前が一番濃い線のように見えてしまう**（実際にはそこが一番薄い）。
/// 始まりと終わりの傾きを寝かせると、どこで終わったのか分からなくなる。
///
/// [child] の下に [fadeTail] ぶんの余地を足して使う——抜けるには距離が要るので、
/// 文字の乗っている高さだけでは足りない。
class TopScrim extends StatelessWidget {
  const TopScrim({super.key, required this.child});

  /// [child] の下に足す、暗幕が抜けきるための余地（絵の上に乗るものは無い）。
  static const fadeTail = 48.0;

  final Widget child;

  /// いちばん濃いところ。**絵の上の白文字が読めるだけ**に留める（暗幕そのものを
  /// 見せたいわけではない）。
  static const _opacity = 0.6;

  /// 抜け方。`(高さの割合, 濃さの割合)` で、最初の 1 点までは濃さを保つ。
  /// S 字（smoothstep）を折れ線で近似した `1 - s` を並べてある。
  static const _fade = <(double, double)>[
    (0.45, 1.0),
    (0.55, 0.915),
    (0.65, 0.705),
    (0.75, 0.425),
    (0.85, 0.180),
    (1.0, 0.0),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromRGBO(0, 0, 0, _opacity),
            for (final (_, level) in _fade)
              Color.fromRGBO(0, 0, 0, _opacity * level),
          ],
          stops: [0, for (final (at, _) in _fade) at],
        ),
      ),
      child: child,
    );
  }
}
