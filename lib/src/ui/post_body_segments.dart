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

/// 行を単独で占める `>>N` の区画（返信先の再掲の置き場）。
///
/// `>>5` だけで 1 行を使っているなら、書いた人はそこで「ここから誰かへの返信」と
/// 区切っている。返信先の再掲をレスの手前に積むのではなく、**書かれた位置へ
/// そのまま差し込む**（`>>5 それな` のように文の頭に付いているだけのものは、
/// 今までどおりレスの手前に出す）。
class PostBodyQuote extends PostBodySegment {
  const PostBodyQuote({required this.number, required this.raw});

  /// 指しているレス番号。
  final int number;

  /// 本文に書かれていた表記（`>>5`）。そのレスが手元に無いときはこれを出す。
  final String raw;
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
///
/// [inlineQuotes] に入れたレス番号は、行を単独で占める `>>N` を [PostBodyQuote]
/// として切り出す（返信先の再掲の置き場）。**渡すのは「並びがまだ示していない
/// 相手」だけ**——ツリーの親のように字下げが示している相手まで差し込むと、
/// 返信のたびに同じ再掲が挟まる。
///
/// [isThreadLink] が真を返すリンク（＝知っている板のスレ URL）は、
/// [linkPreviews] が false でも切り出す。スレカードの中身は貼られたリンク先
/// ではなく元から読みに行っている掲示板サーバから取るので、OGP を切っている
/// 理由（知らないホストへ通信が広がる）に当たらないため。
List<PostBodySegment> splitPostBody(
  String text, {
  bool linkPreviews = false,
  bool Function(Uri url)? isThreadLink,
  Set<int> inlineQuotes = const {},
}) {
  // 行を単独で占める `>>N` を先に切り出し、その前後をこれまでの処理にかける。
  // **AA では切らない**——`>>` を含む行が絵の一部かもしれず、そこで分けると
  // 絵が割れる。
  if (inlineQuotes.isEmpty || looksLikeAsciiArt(text)) {
    return _splitMedia(
      text,
      linkPreviews: linkPreviews,
      isThreadLink: isThreadLink,
    );
  }
  // 差し込むのは、呼ぶ側が「並びではまだ示していない」と判じた相手だけ
  // （`ThreadTreeRow.inlineQuotes`）。1 行に複数並べて指しているなら、その全部が
  // 対象のときだけ切り出す——片方だけ絵にすると、残りの `>>N` が宙に浮く。
  final quoteLines = [
    for (final line in quoteLinesIn(text))
      if (line.numbers.every(inlineQuotes.contains)) line,
  ];
  if (quoteLines.isEmpty) {
    return _splitMedia(
      text,
      linkPreviews: linkPreviews,
      isThreadLink: isThreadLink,
    );
  }
  final segments = <PostBodySegment>[];
  var cursor = 0;
  for (final line in quoteLines) {
    segments.addAll(
      _splitMedia(
        text.substring(cursor, line.start),
        linkPreviews: linkPreviews,
        isThreadLink: isThreadLink,
      ),
    );
    for (final number in line.numbers) {
      segments.add(PostBodyQuote(number: number, raw: '>>\$number'));
    }
    cursor = line.end;
  }
  segments.addAll(
    _splitMedia(
      text.substring(cursor),
      linkPreviews: linkPreviews,
      isThreadLink: isThreadLink,
    ),
  );
  return segments;
}

List<PostBodySegment> _splitMedia(
  String text, {
  bool linkPreviews = false,
  bool Function(Uri url)? isThreadLink,
}) {
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
      final cardable = linkPreviews || (isThreadLink?.call(uri) ?? false);
      if (!cardable || !_ownsLine(text, match.start, match.end)) continue;
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
