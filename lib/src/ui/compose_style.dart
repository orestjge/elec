import 'package:flutter/material.dart';

/// 文章を書く画面（スレ画面のレス入力欄・スレ立て画面）で共有する見た目。
///
/// 入力欄の作りはスレ一覧の「スレタイ検索」に揃える方針＝**角丸は弱く（14）、
/// 枠線は持たず、塗りは薄いティント**。ピル型や濃いベタ塗りだと画面の端で塊に
/// 見え、複数行に伸びたときも間延びするため。値をここに集めて、2 画面で
/// ばらけないようにする。

/// 入力欄・添付・送信ボタンの共通の高さ。1 行のときはこれで横一列に揃う。
const double kComposeControlHeight = 42;

/// 共通の角丸。スレ一覧の検索欄と同じ。
const double kComposeRadius = 14;

/// 塗りを持つボタン（送信など）の形。真円だと入力欄の角丸から浮く。
final composeShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(kComposeRadius),
);

/// 入力欄の枠。全状態で線は消し、角丸だけ [kComposeRadius] に揃える。
final composeFieldBorder = OutlineInputBorder(
  borderRadius: BorderRadius.circular(kComposeRadius),
  borderSide: BorderSide.none,
);

/// 入力欄の塗り。surfaceContainerHighest のベタ塗りより弱いティントにして、
/// 「書ける場所」だけを示し面としては主張させない。
Color composeFieldFill(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.06);

/// 本文入力の文字。投稿後の本文（[PostItem] の 15px・行高 1.4）と揃えて、
/// 書いているものと出来上がりの見え方を一致させる。
///
/// テーマから copyWith で作るのが要点で、素の [TextStyle] だと行間の配り方
/// （leadingDistribution）が既定に戻り、字が行の下寄りになって入力欄の上に
/// 余白が空いたように見えてしまう。
TextStyle? composeBodyTextStyle(ThemeData theme) =>
    theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4);

/// 添付など、塗りを持たない脇役ボタンの見た目。押したときの反応も角丸の四角に
/// して、真円のリップルが入力欄や送信ボタンから浮かないようにする。
ButtonStyle composeQuietButtonStyle(ColorScheme scheme) => IconButton.styleFrom(
  foregroundColor: scheme.onSurfaceVariant,
  shape: composeShape,
);

/// 入力欄の共通デコレーション。個別の事情（[InputDecoration.suffixIcon] など）は
/// 呼び出し側で [InputDecoration.copyWith] して足す。
InputDecoration composeFieldDecoration({
  required ColorScheme scheme,
  required String hintText,
  TextStyle? textStyle,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  ),
}) => InputDecoration(
  hintText: hintText,
  hintStyle: (textStyle ?? const TextStyle()).copyWith(
    color: scheme.onSurfaceVariant,
  ),
  counterText: '',
  filled: true,
  fillColor: composeFieldFill(scheme),
  // isDense で余分な最小高さを外し、高さを contentPadding だけで決められる
  // ようにする。
  isDense: true,
  contentPadding: contentPadding,
  border: composeFieldBorder,
  enabledBorder: composeFieldBorder,
  focusedBorder: composeFieldBorder,
  disabledBorder: composeFieldBorder,
  // 既定の密度はプラットフォーム任せで、デスクトップでは compact になり上下
  // パディングが 8 削られる（＝入力欄だけ縮んで、固定サイズのボタンとずれる）。
  // 密度に振り回されないよう standard に固定する。
  visualDensity: VisualDensity.standard,
);
