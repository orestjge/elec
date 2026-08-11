/// テスト環境で「実際の見た目」を描画できるようにする（日本語とアイコン）。
///
/// widget テストの既定フォントはグリフを持たない Ahem で、日本語もアイコンも
/// すべて豆腐（□）になる。スクリーンショットを撮って見た目を確認するときは
/// [loadPreviewFonts] を呼ぶ。
///
/// **通常のテストでは呼ばないこと。** 実フォントは Ahem と文字幅が違うので、
/// 折り返しや省略に依存したアサーションの結果が変わり得る。見た目確認の
/// レンダリング専用にする。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;

/// 読み込んだフォントのファミリ名。
const japaneseTestFontFamily = 'JapaneseTestFont';

/// 探すフォントの候補（上から順に、最初に見つかったものを使う）。
///
/// アプリ同梱の `assets/fonts/monapo.ttf` は **AA 表示用**（MS PGothic 互換の
/// 字形・字幅）なので、普通の画面の見た目確認には向かない。素の Gothic を
/// 優先し、どれも無ければ最後の手段として同梱フォントに落とす。
List<String> _candidates() => [
  if (Platform.environment['JP_TEST_FONT'] case final path?) path,
  '${Platform.environment['HOME']}/Library/Fonts/NotoSansJP-Regular.otf',
  '/Library/Fonts/NotoSansJP-Regular.otf',
  '/System/Library/Fonts/Supplemental/NotoSansJP-Regular.otf',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/fonts-japanese-gothic.ttf',
  'assets/fonts/monapo.ttf',
];

/// 日本語フォントをテストのフォントレジストリへ登録する。
///
/// [japaneseTestFontFamily] として登録するほか、**既定のファミリ名（Roboto）でも
/// 同じ実体を登録**する。こうするとフォント指定のない文字列（アプリ側のほとんど）
/// もそのまま日本語で出るので、テーマを差し替えなくても確認できる。
///
/// 候補が 1 つも見つからなければ例外を投げる（豆腐のまま撮れてしまい、何を
/// 見ているのか分からなくなるより、その場で気づけるほうがよい）。
/// 別のフォントを使いたいときは環境変数 `JP_TEST_FONT` にパスを渡す。
///
/// **`setUpAll` から呼ぶこと。** [testWidgets] の中は fake async のゾーンで、
/// 実 I/O やエンジン側の非同期処理が完了しないまま止まる（10 分のタイムアウトまで
/// 待たされる）。ファイル読み込みは同期 API を使ってあるが、`FontLoader.load` は
/// エンジンを跨ぐので、テスト本体の外で済ませるのが安全。
Future<void> loadJapaneseTestFont() async {
  final path = _candidates().firstWhere(
    (p) => File(p).existsSync(),
    orElse: () => throw StateError(
      '日本語フォントが見つかりません。JP_TEST_FONT にパスを指定してください。'
      '探した場所: ${_candidates().join(", ")}',
    ),
  );
  // fake async のゾーンで固まらないよう、読み込みは同期 API を使う。
  final bytes = ByteData.sublistView(
    Uint8List.fromList(File(path).readAsBytesSync()),
  );
  for (final family in [japaneseTestFontFamily, 'Roboto']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
}

/// Flutter SDK 同梱の Material Icons を登録する。
///
/// 読み込まないとアイコンが全部豆腐になり、スクリーンショットで形が確認できない。
/// SDK の場所は `FLUTTER_ROOT`（`flutter test` が渡す）から、無ければ実行中の
/// Dart のパスから辿る。
Future<void> loadMaterialIconsTestFont() async {
  final root = _flutterRoot();
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!file.existsSync()) return;
  final bytes = ByteData.sublistView(
    Uint8List.fromList(file.readAsBytesSync()),
  );
  await (FontLoader('MaterialIcons')..addFont(Future.value(bytes))).load();
}

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  // $FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart で動いているので、そこから辿る。
  const marker = '/bin/cache/dart-sdk/';
  final exe = Platform.resolvedExecutable;
  final i = exe.indexOf(marker);
  return i < 0 ? null : exe.substring(0, i);
}

/// AA 表示に使う同梱フォント（Monapo）を登録する。
///
/// [loadPreviewFonts] には含めない。素の日本語フォントで撮りたい画面まで AA の
/// 字幅になってしまうため、AA の出る画面を撮るときだけ足す。`setUpAll` から呼ぶ。
Future<void> loadAsciiArtFont() async {
  final bytes = ByteData.sublistView(
    Uint8List.fromList(File('assets/fonts/monapo.ttf').readAsBytesSync()),
  );
  await (FontLoader('Monapo')..addFont(Future.value(bytes))).load();
}

/// スクリーンショット確認に必要なフォントを一式読み込む。`setUpAll` から呼ぶ。
Future<void> loadPreviewFonts() async {
  await loadJapaneseTestFont();
  await loadMaterialIconsTestFont();
}

/// [theme] の文字を明示的に日本語フォントへ差し替える。
///
/// [loadJapaneseTestFont] だけで足りることが多いが、フォントを固定したい
/// レンダリングではこちらを使う。
ThemeData withJapaneseTestFont(ThemeData theme) => theme.copyWith(
  textTheme: theme.textTheme.apply(fontFamily: japaneseTestFontFamily),
  primaryTextTheme: theme.primaryTextTheme.apply(
    fontFamily: japaneseTestFontFamily,
  ),
);
