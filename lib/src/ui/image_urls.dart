/// レス本文から画像/動画/音声 URL を抜き出す。
///
/// 基本は拡張子で判定する（`.jpg/.jpeg/.png/.gif/.webp/.bmp`、クエリ付きも可）。
/// ページ URL（imgur のページ等、拡張子なし）は対象外。ただし拡張子を持たず
/// クエリで種別が決まる例外（`pbs.twimg.com/media/...?format=jpg` 等）は
/// 個別に対象へ含める。
library;

import 'link_urls.dart';

final _imageExtRe = RegExp(
  r'\.(jpe?g|png|gif|webp|bmp)$',
  caseSensitive: false,
);
final _videoExtRe = RegExp(r'\.(mp4|webm|mov|m4v)$', caseSensitive: false);
final _audioExtRe = RegExp(
  r'\.(mp3|m4a|aac|ogg|oga|opus|wav|flac)$',
  caseSensitive: false,
);

/// pbs.twimg.com の画像 URL は拡張子を持たず、`format=jpg` 等のクエリで
/// 種別が決まる（例: `https://pbs.twimg.com/media/XXXX?format=jpg&name=large`）。
final _twimgFormatRe = RegExp(r'^(jpe?g|png|gif|webp)$', caseSensitive: false);

/// [text] 中の画像 URL を出現順・重複除去で返す。
List<Uri> imageUrlsIn(String text) {
  return _mediaUrlsIn(text, isImageUrl);
}

/// [text] 中の動画 URL を出現順・重複除去で返す。
List<Uri> videoUrlsIn(String text) {
  return _mediaUrlsIn(text, isVideoUrl);
}

/// [uri] が動画ファイルの直リンクか（アプリ内プレーヤーで開く対象か）。
bool isVideoUrl(Uri uri) => _videoExtRe.hasMatch(uri.path);

/// [text] 中の音声 URL を出現順・重複除去で返す。
List<Uri> audioUrlsIn(String text) {
  return _mediaUrlsIn(text, isAudioUrl);
}

/// [uri] が音声ファイルの直リンクか（インラインのプレーヤーで開く対象か）。
bool isAudioUrl(Uri uri) => _audioExtRe.hasMatch(uri.path);

/// [uri] が画像ファイルの直リンクか（サムネイルにする対象か）。
bool isImageUrl(Uri uri) {
  // パス末尾（クエリ・フラグメントを除く）で拡張子判定。
  if (_imageExtRe.hasMatch(uri.path)) return true;
  return _isTwimgImageUri(uri);
}

/// `pbs.twimg.com/media/...?format=jpg` 形式の拡張子なし画像 URL か。
bool _isTwimgImageUri(Uri uri) {
  if (uri.host != 'pbs.twimg.com') return false;
  if (!uri.path.startsWith('/media/')) return false;
  final format = uri.queryParameters['format'];
  return format != null && _twimgFormatRe.hasMatch(format);
}

/// 既知の動画ホストの分かりやすい表示名（ドメイン → 別名）。
const _videoSiteNames = <String, String>{
  'twimg.com': 'Twitter', // video.twimg.com
  'catbox.moe': 'catbox', // files.catbox.moe
  'po-kaki-to.com': 'po-kaki-to',
};

/// 動画ファイル URL のホストから、どのサイトかが分かる短いラベルを返す。
///
/// 既知サイトは別名（`Twitter` 等）に、未知はドメイン（`example.com`）に落とす。
/// 動画サムネのラベルに使う（ファイル名/ID より発信元が分かる）。
String videoSiteLabel(Uri url) {
  final host = url.host.toLowerCase();
  if (host.isEmpty) {
    return url.pathSegments.isNotEmpty ? url.pathSegments.last : url.toString();
  }
  final parts = host.split('.');
  final domain = parts.length >= 2
      ? parts.sublist(parts.length - 2).join('.')
      : host;
  return _videoSiteNames[domain] ?? domain;
}

List<Uri> _mediaUrlsIn(String text, bool Function(Uri) matches) {
  final seen = <String>{};
  final result = <Uri>[];
  for (final m in linkUrlRe.allMatches(text)) {
    final raw = m.group(0)!;
    final uri = normalizedLinkUri(raw);
    if (uri == null) continue;
    if (!matches(uri)) continue;
    if (seen.add(uri.toString())) result.add(uri);
  }
  return result;
}
