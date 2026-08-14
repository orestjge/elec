/// **「多い・速い」を色相ではなく量で見せる**ための目盛り。
///
/// テーマを無彩に振った（`theme.dart`）ので、段階を色相で表していたところが
/// 使えなくなった（灰と灰は見分けが付かない）。代わりに、量を 2 つの見せ方へ
/// 落とす:
///
/// 見せ方は 2 つあり、**使う場所を分けている**:
///
///   - **濃淡**——多いほど濃く、字は太い。使うのは**レスの中だけ**（同じ ID の
///     連投＝[idCountAmount]、集めた返信の数＝[replyCountAmount]）。
///   - **長さ**——薄い棒の伸び。使うのは**スレ一覧の勢いだけ**（[momentumAmount]）。
///     **色は動かさない**——一覧は「探す」画面で、目立たせるべきはスレタイの
///     ほう。既読／未読でタイトルの濃さを動かしているので、メタでも濃淡を使うと
///     2 つの合図が混ざる。棒は数字を絵にしただけの添え物に留める。
///
/// 素の値のままでは混み合うところで差が出ないので、どれも 0〜1 に均してから使う。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 濃淡の段数。**連続（無段）にはしない。** 隣り合う値の差が数 % だと「ただ
/// 薄い」に見えるだけで段として読めないので、はっきり分かる幅に丸める。
const _steps = 5;

/// いちばん薄いときの濃さ。これより下げると地に溶けて消えたように見える。
const _alphaLow = 0.35;

/// 量 [t]（0〜1）を [_steps] 段に丸める。両端を含む（5 段なら 0, .25, .5, .75, 1）。
double quantizeAmount(double t) {
  final i = (t.clamp(0, 1) * _steps).floor().clamp(0, _steps - 1);
  return i / (_steps - 1);
}

/// 量 [t] を持つ塗り（リングの弧、勢いの棒）の色。
Color emphasisFill(ColorScheme scheme, double t) => scheme.onSurface.withValues(
  alpha: _alphaLow + (1 - _alphaLow) * quantizeAmount(t),
);

/// 棒の下敷き。**まだ伸びしろがある**ことを見せるために全長ぶん敷く。
Color emphasisTrack(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.12);

/// 量 [t] を持つ字の色。
///
/// **透明度ではなく色そのものを混ぜる。** 字を透かすと後ろの塗り（自分のレスの
/// 面など）を拾って読みにくくなる。
Color emphasisText(ColorScheme scheme, double t) =>
    Color.lerp(scheme.onSurfaceVariant, scheme.onSurface, quantizeAmount(t))!;

/// 量 [t] を持つ字の太さ。太さは 3 段しか実質使えない（それ以上は差が出ない）。
FontWeight emphasisWeight(double t) {
  final q = quantizeAmount(t);
  if (q >= 0.75) return FontWeight.w700;
  if (q >= 0.25) return FontWeight.w600;
  return FontWeight.w500;
}

/// 同じ ID の連投数を 0〜1 の量へ。
///
/// **対数**で均す。実際の板では 2〜6 件がいちばん多く、10 件を超えるのは稀
/// なので、線形だとその混み合うところで差が出ない。[_countTop] 件で頭打ち。
///
/// 濃淡 5 段に落ちると、目に見える段は **2〜3 / 4〜7 / 8〜15 / 16 以上**の 4 つ
/// （単発は輪そのものが出ない）。
double idCountAmount(int count) =>
    count <= 1 ? 0 : math.min(1, math.log(count) / math.log(_countTop));

/// この数を超えたら、それ以上濃くならない。
const _countTop = 24;

/// スレの勢い（レス/日）を 0〜1 の量へ。
///
/// **常用対数**で、[_momentumFloor]（100 レス/日）から [_momentumFull]
/// （100000 レス/日）までの **3 桁**を目盛りにする。下限より遅いスレは 0。
///
/// ## なぜこの範囲か
/// 実況の総合板（liveedge）の一覧を実測すると、**勢いは 3 桁に散らばったうえ、
/// 大半が 1k〜10k に固まる**（2026-08-15、94 スレ）:
///
///   最速 95212 ／ 上位 10% 6654 ／ 中央値 1721 ／ 上位 75% 1155 ／ 最遅 202
///
/// 満杯を 10k に置くと 94 スレ中 42 本が棒を振り切って差が出ない。100k まで
/// 伸ばすと、中央値のスレで 4 割ほど、上位 1 割のスレで 6 割ほどの伸びになる。
///
/// 勢いを見るのはこの手の回転の早い板だけなので、そちらへ合わせてある。過疎板
/// では棒がほとんど伸びないが、それは実際に遅いということなので正しい。
///
/// なお `momentumPerDay` は経過時間で割るだけなので、**立ったばかりのスレは
/// 値が暴れる**（3 レス／2 分で 1.7k/日）。棒はその数字を絵にしたものなので
/// 同じように暴れる。レス数で割り引いて均す案は
/// `test/preview/popularity_preview.dart` で試したが、一覧をごちゃつかせる
/// わりに得るものが小さく、採らなかった。
double momentumAmount(double perDay) {
  if (perDay <= _momentumFloor) return 0;
  return math.min(
    1,
    math.log(perDay / _momentumFloor) /
        math.log(_momentumFull / _momentumFloor),
  );
}

const _momentumFloor = 100.0;
const _momentumFull = 100000.0;

/// 1 つのレスが受けた返信の数を 0〜1 の量へ。
///
/// **対数**。ここも 1〜4 件がいちばん多く、10 件を超えるのは目立つレスだけ。
/// [_replyFull] 件で満杯。
double replyCountAmount(int count) =>
    count <= 1 ? 0 : math.min(1, math.log(count) / math.log(_replyFull));

const _replyFull = 20;
