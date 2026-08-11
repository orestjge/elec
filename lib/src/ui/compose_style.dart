import 'package:flutter/material.dart';

import 'res_body.dart';

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

/// 入力欄に AA を書いた（貼った）ときの、字と行数の組み替え。null なら AA では
/// ないので、入力欄はいつもどおりでよい。
///
/// 普通の字のまま出すと、AA は字幅が合わないうえ長い行が欄の幅で折り返され、
/// **何を貼ったのか書いている本人にも分からない**。出来上がり（[ResBody]）と
/// 同じ Monapo に切り替え、1 行が折り返さない大きさまで小さくして、書いている
/// 最中から絵として見えるようにする。
///
/// 複数行の入力欄は横スクロールできない（[TextField] は必ず折り返す）ので、
/// [minAsciiArtFontSize] まで縮めても収まらないぶんは折り返す。そこは本文表示と
/// 違うところで、これ以上小さくしても書きようがない。
class ComposeAsciiArtFit {
  const ComposeAsciiArtFit({required this.style, required this.lineScale});

  /// 入力欄に使う字。
  final TextStyle style;

  /// 同じ高さに入る行数の増え方。字を小さくしたぶん行は詰まるので、行数の上限を
  /// この率で伸ばすと**入力欄の高さは変わらないまま**、見える行数だけ増える。
  final double lineScale;

  /// 普通の字なら [lines] 行ぶんの高さに、いま何行入るか。
  int lines(int lines) => (lines * lineScale).round();
}

/// [text] が AA なら、それを入力欄に出すための字と行数を組む。
///
/// [maxWidth] は入力欄の**文字が置ける幅**（欄の幅から左右の padding と
/// suffixIcon を引いたもの）。
ComposeAsciiArtFit? composeAsciiArtFit(
  BuildContext context, {
  required TextStyle? base,
  required String text,
  required double maxWidth,
}) {
  if (!looksLikeAsciiArt(text)) return null;
  final baseStyle = base ?? const TextStyle(fontSize: 15, height: 1.4);
  final art = asciiArtStyle(baseStyle);
  final fontSize = art.fontSize ?? 15;
  final scale = asciiArtFitScale(
    naturalWidth: asciiArtNaturalWidth(context, text, art),
    maxWidth: maxWidth,
    fontSize: fontSize,
  );
  final style = scale == 1 ? art : art.copyWith(fontSize: fontSize * scale);
  final baseLine = (baseStyle.fontSize ?? 15) * (baseStyle.height ?? 1);
  final artLine = (style.fontSize ?? 15) * (style.height ?? 1);
  return ComposeAsciiArtFit(
    style: style,
    lineScale: artLine <= 0 ? 1 : (baseLine / artLine).clamp(1, 4),
  );
}

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
