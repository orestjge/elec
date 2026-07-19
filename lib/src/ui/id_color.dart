import 'package:flutter/material.dart';

/// ID 文字列から決定的な色を作る。同じ ID は常に同じ色になり、レスの
/// 発言者を目で追いやすくする。テーマの明暗に合わせて可読性を保つ。
Color idColor(String id, Brightness brightness) {
  // hashCode は実行間で不安定なので使わない。文字コードの安定な畳み込みで hue を出す。
  var h = 0;
  for (final code in id.codeUnits) {
    h = (h * 31 + code) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  final lightness = brightness == Brightness.dark ? 0.72 : 0.42;
  return HSLColor.fromAHSL(1, hue, 0.55, lightness).toColor();
}
