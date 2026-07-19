import 'package:flutter/material.dart';

/// ID のレス数に応じた段階色。ID 文字列ごとの色分けは賑やかになりやすいので、
/// よく書き込んでいる ID ほど少し目立つ程度に抑える。
Color idColorForCount(ColorScheme scheme, int count) {
  if (count >= 8) return scheme.error;
  if (count >= 5) return scheme.tertiary;
  if (count >= 2) return scheme.primary;
  return scheme.onSurfaceVariant;
}
