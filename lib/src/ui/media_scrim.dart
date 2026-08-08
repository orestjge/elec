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
class TopScrim extends StatelessWidget {
  const TopScrim({super.key, required this.child});

  final Widget child;

  /// いちばん濃いところ。**絵の上の白文字が読めるだけ**に留める（暗幕そのものを
  /// 見せたいわけではない）。
  static const _opacity = 0.6;

  /// 濃さを保つ割合。ここから下端までで透明へ抜ける。
  static const _solidUntil = 0.6;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromRGBO(0, 0, 0, _opacity),
            Color.fromRGBO(0, 0, 0, _opacity),
            Color.fromRGBO(0, 0, 0, 0),
          ],
          stops: [0, _solidUntil, 1],
        ),
      ),
      child: child,
    );
  }
}
