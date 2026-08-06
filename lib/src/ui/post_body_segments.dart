/// レス本文を「文章」と「メディア」の交互の並びへ切り分ける。
///
/// サムネイルを本文の末尾へまとめると、どの絵がどの話に付いているのかが読んだ
/// 順から分からなくなる。貼られた位置で切って差し込めば、書いた人が並べたとおり
/// の順で読める。
///
/// 切り出した URL の文字列は本文から落とす。絵が出ている以上その URL を読む用は
/// 無く、長い URL が本文の途中に挟まると文章が寸断されるだけのため。サムネイルに
/// できない普通のリンクは、これまでどおり本文中のリンクとして残す。
library;

import 'embed_urls.dart';
import 'image_urls.dart';
import 'link_urls.dart';
import 'res_body.dart';

/// [splitPostBody] が返す 1 区画。
sealed class PostBodySegment {
  const PostBodySegment();
}

/// 文章の区画。
class PostBodyText extends PostBodySegment {
  const PostBodyText(this.text);

  final String text;
}

/// サムネイルにできないリンク 1 本の区画（OGP カードの置き場）。
///
/// **行を単独で占める URL だけ**をここへ切り出す。文の途中に埋まった URL
/// （`詳しくは https://… を見て`）まで区画にすると 1 文が 3 段に割れて読めた
/// ものではなくなるので、そちらは本文中のリンクのまま残す。
class PostBodyLink extends PostBodySegment {
  const PostBodyLink({required this.url, required this.raw});

  /// 正規化した URL。
  final Uri url;

  /// 本文に書かれていた表記（`ttps://…` 等）。カードが出せないときはこれを出す。
  final String raw;
}

/// 続けて貼られたメディアをひとまとめにした区画。
///
/// 1 区画には 1 種類しか入らない（[splitPostBody] が同じ種類の連続だけを束ねる）。
/// サムネイル群は画像→動画→埋め込みの順に並ぶので、種類の混ざった並びを 1 区画へ
/// 入れると本文の並び順と食い違うため。
class PostBodyMedia extends PostBodySegment {
  const PostBodyMedia({
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
    this.embeds = const [],
  });

  /// 画像ファイルの直リンク。
  final List<Uri> images;

  /// 動画ファイルの直リンク。
  final List<Uri> videos;

  /// 音声ファイルの直リンク。
  final List<Uri> audios;

  /// YouTube / ニコニコ動画のリンク。
  final List<EmbedVideo> embeds;
}

/// [text]（表示用に整形済みの本文）を文章とメディアの並びへ切り分ける。
///
/// 同じ種類のメディアが空白だけを挟んで続いていれば 1 区画にまとめ、サムネイルを
/// 横一列に並べられるようにする。ただし空行で区切られていれば別の区画にして、
/// 書いた人が空けた間を保つ。空になった文章の区画は落とす。
///
/// [linkPreviews] が true なら、サムネイルにできないリンクのうち**行を単独で
/// 占めるもの**を [PostBodyLink] として切り出す（OGP カードの置き場）。false の
/// ときは、これまでどおり本文中のリンクのままにする。
List<PostBodySegment> splitPostBody(String text, {bool linkPreviews = false}) {
  final segments = <PostBodySegment>[];
  // まだ区画にしていない本文の先頭。
  var cursor = 0;
  // 束ねている最中のメディアの並び（本文上の範囲と中身）。
  var runStart = -1;
  var runEnd = -1;
  final images = <Uri>[];
  final videos = <Uri>[];
  final audios = <Uri>[];
  final embeds = <EmbedVideo>[];

  void addText(String part) {
    final trimmed = trimUnlessAsciiArt(part);
    if (trimmed.isEmpty) return;
    segments.add(PostBodyText(trimmed));
  }

  void flushRun() {
    if (runStart < 0) return;
    addText(text.substring(cursor, runStart));
    segments.add(
      PostBodyMedia(
        images: List.unmodifiable(images),
        videos: List.unmodifiable(videos),
        audios: List.unmodifiable(audios),
        embeds: List.unmodifiable(embeds),
      ),
    );
    cursor = runEnd;
    runStart = -1;
    images.clear();
    videos.clear();
    audios.clear();
    embeds.clear();
  }

  for (final match in linkUrlRe.allMatches(text)) {
    final uri = normalizedLinkUri(match.group(0)!);
    if (uri == null) continue;
    final embed = embedVideoOf(uri);
    final isImage = embed == null && isImageUrl(uri);
    final isVideo = embed == null && !isImage && isVideoUrl(uri);
    final isAudio = embed == null && !isImage && !isVideo && isAudioUrl(uri);
    if (embed == null && !isImage && !isVideo && !isAudio) {
      // サムネイルにできないリンク。行を単独で占めているものだけカードの区画に
      // し、それ以外（文の途中に埋まった URL）は本文へ残す。
      if (!linkPreviews || !_ownsLine(text, match.start, match.end)) continue;
      flushRun();
      addText(text.substring(cursor, match.start));
      segments.add(PostBodyLink(url: uri, raw: match.group(0)!));
      cursor = match.end;
      continue;
    }

    final sameKind =
        (isImage && images.isNotEmpty) ||
        (isVideo && videos.isNotEmpty) ||
        (isAudio && audios.isNotEmpty) ||
        (embed != null && embeds.isNotEmpty);
    if (!(sameKind && _joinsRun(text, runEnd, match.start))) {
      flushRun();
      runStart = match.start;
    }
    if (embed != null) {
      embeds.add(embed);
    } else if (isImage) {
      images.add(uri);
    } else if (isVideo) {
      videos.add(uri);
    } else {
      audios.add(uri);
    }
    runEnd = match.end;
  }
  flushRun();
  addText(text.substring(cursor));
  return segments;
}

/// [text] の [start]–[end] にある URL が、その行を単独で占めているか。
///
/// 前後に空白しか無い（行頭・行末、または本文の端）なら真。ここを区画へ切り出して
/// もともと 1 行だったものが 1 ブロックになるだけなので、カードが出せなくても
/// 見た目は変わらない。
bool _ownsLine(String text, int start, int end) {
  for (var i = start - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '\n') break;
    if (ch.trim().isNotEmpty) return false;
  }
  for (var i = end; i < text.length; i++) {
    final ch = text[i];
    if (ch == '\n') break;
    if (ch.trim().isNotEmpty) return false;
  }
  return true;
}

/// 直前のメディア（[text] の [end] まで）と次のメディア（[start] から）が、
/// ひと続きとして 1 区画に収まるか。
///
/// 間が空白だけで、かつ空行を挟んでいなければ続きとみなす。
bool _joinsRun(String text, int end, int start) {
  if (end < 0 || start < end) return false;
  final gap = text.substring(end, start);
  if (gap.trim().isNotEmpty) return false;
  return '\n'.allMatches(gap).length <= 1;
}
