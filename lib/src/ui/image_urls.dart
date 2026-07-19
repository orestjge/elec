/// レス本文から画像/動画 URL を抜き出す。
///
/// 拡張子が画像のものだけを対象にする（`.jpg/.jpeg/.png/.gif/.webp/.bmp`、
/// クエリ付きも可）。ページ URL（imgur のページ等、拡張子なし）は対象外。
library;

import 'link_urls.dart';

final _imageExtRe = RegExp(
  r'\.(jpe?g|png|gif|webp|bmp)$',
  caseSensitive: false,
);
final _videoExtRe = RegExp(r'\.(mp4|webm|mov|m4v)$', caseSensitive: false);

/// [text] 中の画像 URL を出現順・重複除去で返す。
List<Uri> imageUrlsIn(String text) {
  return _mediaUrlsIn(text, _imageExtRe);
}

/// [text] 中の動画 URL を出現順・重複除去で返す。
List<Uri> videoUrlsIn(String text) {
  return _mediaUrlsIn(text, _videoExtRe);
}

List<Uri> _mediaUrlsIn(String text, RegExp extRe) {
  final seen = <String>{};
  final result = <Uri>[];
  for (final m in linkUrlRe.allMatches(text)) {
    final raw = m.group(0)!;
    final uri = normalizedLinkUri(raw);
    if (uri == null) continue;
    // パス末尾（クエリ・フラグメントを除く）で拡張子判定。
    if (!extRe.hasMatch(uri.path)) continue;
    if (seen.add(uri.toString())) result.add(uri);
  }
  return result;
}
