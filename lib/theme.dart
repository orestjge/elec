import 'package:flutter/material.dart';

/// M3 の役割に無い、elec 固有の色。
///
/// ## なぜ要るか
/// M3 の `primary` は「主要な操作の色」と「主要な強調の色」を兼ねている。elec は
/// 文字が主役の板ビューアで、**押すもの**（スレ立て・送信・OK）と**意味を持つ色**
/// （リンク・`>>N`・自分宛・新着・勢い）の両方が `primary` に集まっていた。
/// 色相を変えると両方が同時に動いてしまい、「アクセントを使う場所を絞る」という
/// 調整ができない。
///
/// そこで **押すものの色を [action] に分けた**。地の反対側にある無彩色
/// （明るいテーマではほぼ黒、暗いテーマではほぼ白）で、色相を持たない。
/// アクセント（`ColorScheme.primary`）は意味のあるところにだけ残す。
@immutable
class ElecColors extends ThemeExtension<ElecColors> {
  const ElecColors({required this.action, required this.onAction});

  /// 押すものの塗り。スレ立て FAB、送信ボタンなど。
  final Color action;

  /// [action] の上に載る文字・アイコン。
  final Color onAction;

  /// 明るさなりの既定。テーマを組むときはここから始める。
  factory ElecColors.forBrightness(Brightness brightness) =>
      brightness == Brightness.dark
      ? const ElecColors(
          action: Color(0xFFF2F2F3),
          onAction: Color(0xFF111114),
        )
      : const ElecColors(
          action: Color(0xFF111114),
          onAction: Color(0xFFFFFFFF),
        );

  /// 今のテーマの [ElecColors]。
  ///
  /// 拡張を積んでいないテーマ（素の [ThemeData] を組むテストなど）でも壊れない
  /// よう、無ければ配色から導く。
  static ElecColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ElecColors>() ??
        ElecColors.forBrightness(theme.brightness);
  }

  @override
  ElecColors copyWith({Color? action, Color? onAction}) => ElecColors(
    action: action ?? this.action,
    onAction: onAction ?? this.onAction,
  );

  @override
  ElecColors lerp(ElecColors? other, double t) => other == null
      ? this
      : ElecColors(
          action: Color.lerp(action, other.action, t)!,
          onAction: Color.lerp(onAction, other.onAction, t)!,
        );
}

/// elec のテーマ。**無彩基調**（インク）の light / dark。
///
/// ## 決めごと
/// アプリのアイコンを白黒の線画にしたのに合わせて、画面からも色を抜いた。
/// `ColorScheme.fromSeed` は使わない——種 1 色から作ると**面にまで色みが乗り**、
/// M3 の既定そのものの見た目になるため、役割ごとに色を明示する。
///
///   - **面**（`surface*`）は無彩の灰。地から積み上がる 6 段で階層を作る。
///     暗いテーマの地は **#0B0B0D**。真っ黒にしないのは、下書き欄・検索バー・
///     ボトムバーを**すりガラスの島**として浮かせているから——地が真っ黒だと
///     島と地の差が出ず、枠線を足さないと読めなくなる。
///   - **押すもの**（スレ立て FAB・送信・OK）は [ElecColors.action]。ほぼ黒
///     （暗いテーマではほぼ白）で、色相を持たない。
///   - **意味の色**（`primary`）——リンク・`>>N`・自分宛・新着・勢い・連投 ID。
///     ここも**無彩**にした。色相で差を付けない代わり、新着バッジのように
///     「発見してほしいもの」は**ベタ塗り＋白抜き**にして濃度で立たせる。
///   - **自分のもの**（`secondary` / `tertiary`）——自分で立てたスレの帯とバッジ。
///     わずかに暖かい灰。他人のものとの差が「温度」だけになるので静かに出る。
///   - **赤**（`error`）は NG・あぼーん・よく書いている ID 専用。**画面に残る
///     唯一の色相**なので、他の用途に広げない。
///
/// 候補を並べて撮る枠は `test/preview/theme_palette_preview.dart`。
class ElecTheme {
  ElecTheme._();

  static ThemeData light() => themeFrom(lightScheme);
  static ThemeData dark() => themeFrom(darkScheme);

  /// 明るいテーマの配色。地は白よりわずかに沈めて、真っ白の眩しさを抜く。
  static const lightScheme = ColorScheme(
    brightness: Brightness.light,
    // 意味の色。無彩なので、リンクは下線と濃度で読ませる。
    primary: Color(0xFF3A3A3F),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFE6E6E7),
    onPrimaryContainer: Color(0xFF1A1A1D),
    // 自分のもの。わずかに暖かい灰。
    secondary: Color(0xFF6B6259),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFEAE7E3),
    onSecondaryContainer: Color(0xFF2A2622),
    tertiary: Color(0xFF6B6259),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFEAE7E3),
    onTertiaryContainer: Color(0xFF2A2622),
    // 画面に残る唯一の色相。NG・あぼーん・よく書いている ID。
    error: Color(0xFFC0392B),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFBE3E0),
    onErrorContainer: Color(0xFF4E120C),
    surface: Color(0xFFFCFCFD),
    onSurface: Color(0xFF17171A),
    onSurfaceVariant: Color(0xFF5C5C66),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF6F6F8),
    surfaceContainer: Color(0xFFF1F1F4),
    surfaceContainerHigh: Color(0xFFEAEAEE),
    surfaceContainerHighest: Color(0xFFE4E4E9),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceDim: Color(0xFFEAEAEE),
    outline: Color(0xFFA9A9B4),
    outlineVariant: Color(0xFFDEDEE3),
    // 反転した面（スナックバーなど）。
    inverseSurface: Color(0xFF2B2B31),
    onInverseSurface: Color(0xFFF1F1F4),
    inversePrimary: Color(0xFFC9C9CE),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// 暗いテーマの配色。地は #0B0B0D（真っ黒にはしない。上の決めごとを参照）。
  static const darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFC9C9CE),
    onPrimary: Color(0xFF15151A),
    primaryContainer: Color(0xFF2E2E31),
    onPrimaryContainer: Color(0xFFE7E7E9),
    secondary: Color(0xFFA8A29A),
    onSecondary: Color(0xFF1E1B18),
    secondaryContainer: Color(0xFF2C2A27),
    onSecondaryContainer: Color(0xFFE8E5E0),
    tertiary: Color(0xFFA8A29A),
    onTertiary: Color(0xFF1E1B18),
    tertiaryContainer: Color(0xFF2C2A27),
    onTertiaryContainer: Color(0xFFE8E5E0),
    error: Color(0xFFFF6B5E),
    onError: Color(0xFF3A0B06),
    errorContainer: Color(0xFF5A1D16),
    onErrorContainer: Color(0xFFFFDAD5),
    surface: Color(0xFF0B0B0D),
    onSurface: Color(0xFFE7E7EB),
    onSurfaceVariant: Color(0xFF98989F),
    surfaceContainerLowest: Color(0xFF060607),
    surfaceContainerLow: Color(0xFF101013),
    surfaceContainer: Color(0xFF161619),
    surfaceContainerHigh: Color(0xFF1D1E22),
    surfaceContainerHighest: Color(0xFF25262B),
    surfaceBright: Color(0xFF25262B),
    surfaceDim: Color(0xFF060607),
    outline: Color(0xFF56565E),
    outlineVariant: Color(0xFF2C2D32),
    inverseSurface: Color(0xFFE4E4E9),
    onInverseSurface: Color(0xFF1B1C20),
    inversePrimary: Color(0xFF3A3A3F),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// 配色から [ThemeData] を組む。色以外の作り（ヘッダ・区切り・FAB・スナック
  /// バー）はここに集めてあるので、配色を差し替えても形は変わらない。
  static ThemeData themeFrom(ColorScheme scheme, {ElecColors? colors}) {
    final elec = colors ?? ElecColors.forBrightness(scheme.brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [elec],
      // 大きめ・折りたたみ式のヘッダを既定に。
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        space: 1,
        thickness: 1,
      ),
      // 押すものは無彩に落とす（アクセントは意味のあるところへ残す）。
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: elec.action,
        foregroundColor: elec.onAction,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: elec.action,
          foregroundColor: elec.onAction,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: elec.action),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
