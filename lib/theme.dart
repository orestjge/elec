import 'package:flutter/material.dart';

/// elec のテーマ。electric（電気）にちなんだインディゴ系のアクセント。
/// light / dark 両対応。
class ElecTheme {
  ElecTheme._();

  /// シードカラー（エレクトリック・インディゴ）。
  static const seed = Color(0xFF4C6EF5);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // 既定フォントを NotoSansJP に統一。英数と日本語を1フォントで賄うことで、
      // IME変換中の下線が英数/かな漢字でガタつく問題（フォントフォールバックで
      // メトリクスが混ざるのが原因）を解消する。
      // AA 表示（res_body.dart）は個別に Monapo を指定しているため影響しない。
      fontFamily: 'NotoSansJP',
      scaffoldBackgroundColor: scheme.surface,
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
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
