/// レス本文から YouTube / ニコニコ動画のリンクを抜き出す。
///
/// 動画ファイル（[imageUrlsIn]/[videoUrlsIn]）と違い、拡張子ではなくホストと
/// パス形から判定する。抜き出した動画はサムネイルカードとして表示し、タップで
/// アプリ内 WebView を開く。
library;

import 'link_urls.dart';

/// 動画サービスの種別。
enum EmbedKind { youtube, niconico }

/// 本文から見つけた埋め込み動画 1 件。
class EmbedVideo {
  const EmbedVideo({
    required this.kind,
    required this.id,
    required this.url,
    required this.playerUrl,
    this.thumbnailUrl,
  });

  final EmbedKind kind;

  /// サービス内の動画 ID（YouTube の 11 文字 ID、ニコニコの `sm123` 等）。
  final String id;

  /// タップ時に外部で開く正規化済み URL。
  final Uri url;

  /// アプリ内 WebView で開く URL。YouTube は埋め込みプレーヤー URL。
  final Uri playerUrl;

  /// サムネイル画像 URL。取得手段が無い場合（ニコニコ）は null。
  final String? thumbnailUrl;

  /// サムネイル下部に出す見出し。
  String get label => switch (kind) {
    EmbedKind.youtube => 'YouTube',
    EmbedKind.niconico => 'ニコニコ動画',
  };
}

// YouTube の動画 ID は 11 文字の [A-Za-z0-9_-]。
const _youtubeId = r'([A-Za-z0-9_-]{11})';
final _youtubeIdRe = RegExp('^$_youtubeId\$');
final _youtubeHostRe = RegExp(
  r'^(?:www\.|m\.|music\.)?youtube\.com$',
  caseSensitive: false,
);
final _youtubePathRe = RegExp('^/(?:embed|shorts|v|live)/$_youtubeId');
final _youtuBeRe = RegExp('^/$_youtubeId');

// ニコニコの動画 ID は `sm123` `nm123` `so123` 等の英字 2 文字＋数字、
// もしくは旧来の数字のみ。
final _nicoIdRe = RegExp(r'^((?:[a-z]{2})?\d+)$', caseSensitive: false);

/// [text] 中の YouTube / ニコニコ動画を出現順・重複除去で返す。
List<EmbedVideo> embedVideosIn(String text) {
  final seen = <String>{};
  final result = <EmbedVideo>[];
  for (final m in linkUrlRe.allMatches(text)) {
    final uri = normalizedLinkUri(m.group(0)!);
    if (uri == null) continue;
    final video = _parse(uri);
    if (video == null) continue;
    if (seen.add(video.url.toString())) result.add(video);
  }
  return result;
}

EmbedVideo? _parse(Uri uri) {
  final host = uri.host.toLowerCase();
  if (_youtubeHostRe.hasMatch(host)) {
    final watchId = uri.queryParameters['v'];
    final id = watchId != null && _youtubeIdRe.hasMatch(watchId)
        ? watchId
        : _youtubePathRe.firstMatch(uri.path)?.group(1);
    if (id != null) return _youtube(id);
    return null;
  }
  if (host == 'youtu.be') {
    final id = _youtuBeRe.firstMatch(uri.path)?.group(1);
    if (id != null) return _youtube(id);
    return null;
  }
  if (host == 'www.nicovideo.jp' ||
      host == 'nicovideo.jp' ||
      host == 'sp.nicovideo.jp') {
    // /watch/sm12345
    if (uri.pathSegments.length == 2 && uri.pathSegments.first == 'watch') {
      return _niconico(uri.pathSegments[1]);
    }
    return null;
  }
  if (host == 'nico.ms') {
    // 短縮 URL nico.ms/sm12345
    if (uri.pathSegments.length == 1) return _niconico(uri.pathSegments.single);
    return null;
  }
  return null;
}

EmbedVideo _youtube(String id) => EmbedVideo(
  kind: EmbedKind.youtube,
  id: id,
  url: Uri.parse('https://www.youtube.com/watch?v=$id'),
  playerUrl: Uri.parse(
    'https://www.youtube.com/embed/$id?playsinline=1&autoplay=1&rel=0',
  ),
  thumbnailUrl: 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
);

EmbedVideo? _niconico(String rawId) {
  if (!_nicoIdRe.hasMatch(rawId)) return null;
  final id = rawId.toLowerCase();
  return EmbedVideo(
    kind: EmbedKind.niconico,
    id: id,
    url: Uri.parse('https://www.nicovideo.jp/watch/$id'),
    playerUrl: Uri.parse('https://www.nicovideo.jp/watch/$id'),
  );
}
