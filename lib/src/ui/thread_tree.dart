/// レス一覧の行組み。番号順表示（[layOutFlatRows]）とツリー表示
/// （[layOutThreadTree]）の両方をここで組む。どちらも**返信先を薄い引用行として
/// 手前に再掲する**（[QuotedResRow]）ところは同じで、並べ替えるかどうかが違う。
///
/// **既に読んだところだけをツリーにする。** レスを `>>N` の親子でぶら下げると、
/// 後から来たレスが古いレスの直下へ挿し込まれる。そうなると自動更新のたびに
/// 読んだところの途中で行が増えてスクロール位置が飛び、しかも増えたことに
/// 気づけない。chMate と同じく、**開いた時点までのレスをツリーに固め、その後に
/// 増えたレスはそのツリーへ混ぜずに下へ足していく**。
///
/// 下に積んだレスが**ツリー側**のレスへ返信している場合は、その返信先を薄い
/// 引用行として直前に再掲する（親は画面のずっと上にあって見えないため）。同じ
/// レスを指した新着は、間に別の新着を挟んでも 1 つの引用行の下へまとめる。逆に
/// 返信先も**新着側**にあるなら、あとから来た返信でもその直下へ入れてツリーに
/// する（下に積んだ会話はその場で伸びていく）。開き直せば境界が進み、それらの
/// レスはまとめてツリーへ吸収される。
library;

import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import '../net/ng_store.dart';
import 'id_icon.dart';
import 'image_urls.dart';
import 'link_urls.dart';
import 'remote_image.dart';
import 'res_body.dart';

/// レス一覧の 1 行。番号順表示では [depth] 0 の行が並ぶだけになる。
class ThreadTreeRow {
  const ThreadTreeRow({required this.res, this.depth = 0, this.quote = false});

  final Res res;

  /// ツリーの深さ（0 が根）。字下げに使う。
  final int depth;

  /// 返信先の再掲（薄字の引用行）か。レス本体ではないので、既読位置やスレ
  /// マップの対象にはしない。
  final bool quote;
}

/// 一覧の行。境界（新着ライン）を挟んで [settled] と [arrivals] に分かれる。
class ThreadTreeLayout {
  const ThreadTreeLayout({required this.settled, required this.arrivals});

  /// 開いた時点までのレス。ツリー表示では `>>N` の親子でぶら下げたツリー。
  final List<ThreadTreeRow> settled;

  /// 開いたあとに増えたレス。ツリー表示では根が届いた順に並び、新着どうしの
  /// 返信はその根の下でツリーになる。
  final List<ThreadTreeRow> arrivals;
}

/// 1 レスに添える引用行の上限。
///
/// `>>5 >>7 >>9 …` と何人にもまとめて返すレスでは、返信先を全部再掲すると引用
/// ばかりが積み上がって**返信の本体が画面の外へ押し出される**。溢れたぶんは
/// 出さない。本文の `>>N` はそのまま残るので、番号は読める。
const int maxQuotedResRows = 3;

/// 返信先（本文で指している既存の若いレス）を、本文に出てきた順・重複除去で
/// レス番号ごとに引けるようにする。`>>5 >>7` なら `[5, 7]`。
///
/// 番号が若い方へしか繋がないので循環しない。ツリーの親にするのは先頭の 1 つ
/// （[layOutThreadTree]）で、残りは引用行に回る。
Map<int, List<int>> _targetsOf(List<Res> res, Map<int, Res> byNumber) {
  final targetsOf = <int, List<int>>{};
  for (final r in res) {
    final targets = [
      for (final n in referencedResNumbers(r.body))
        if (n < r.number && byNumber.containsKey(n)) n,
    ];
    if (targets.isNotEmpty) targetsOf[r.number] = targets;
  }
  return targetsOf;
}

/// 番号順表示の行を組む。dat の順にそのまま並べ、**返信レスの手前にその返信先を
/// 薄い引用行として再掲する**（ツリー表示の新着側と同じ [QuotedResRow]）。
///
/// 番号順では返信先が画面のずっと上にあることが多く、`>>N` の番号だけでは何への
/// 返信か分からない。かといって並べ替える（＝ツリーにする）と読む順が変わるので、
/// **並びはそのままに、返信先の頭だけを手前に添える**。
///
/// **返信レスには必ず添える**。直前のレスへの返信（すぐ上に本体がある）でも、
/// 同じ相手への連投でも省かない。返信レスの見た目がいつも「引用行＋本体」で
/// 揃うので、引用行の有無を手掛かりに「これは返信か」を一目で判じられる。
/// 省く条件を入れると、返信なのに引用が無い行が混ざって、その手掛かりが効かなく
/// なる。
///
/// 複数に返しているレス（`>>5 >>7`）は**指した順に全部**添える（[maxQuotedResRows]
/// まで）。1 つ目だけ出すと、残りの相手へ何を返したのかが読めないうえ、引用が
/// 1 つしかない見た目から「1 人への返信」と取り違える。
///
/// 境界（新着ライン）は [settledCount] 件目。
ThreadTreeLayout layOutFlatRows(List<Res> res, {required int settledCount}) {
  final byNumber = {for (final r in res) r.number: r};
  final targetsOf = _targetsOf(res, byNumber);
  final count = settledCount.clamp(0, res.length);

  List<ThreadTreeRow> rowsFor(Iterable<Res> part) => [
    for (final r in part) ...[
      for (final n in (targetsOf[r.number] ?? const <int>[]).take(
        maxQuotedResRows,
      ))
        ThreadTreeRow(res: byNumber[n]!, quote: true),
      ThreadTreeRow(res: r),
    ],
  ];

  return ThreadTreeLayout(
    settled: rowsFor(res.take(count)),
    arrivals: rowsFor(res.skip(count)),
  );
}

/// ツリー表示の行を組む。[settledCount] 件目までがツリー、それ以降が新着。
///
/// 親は **本文で最初に指している既存の若いレス**（`>>5 >>7` なら 5）。指し先が
/// 無い・自分より新しい番号しか指していないレスは根になる。
///
/// **ぶら下げられるのは 1 人ぶんだけ**なので、2 つ目以降の返信先（`>>5 >>7` の 7）
/// はツリーのどこにも現れない。そういう相手は引用行としてそのレスの手前に添える
/// （[maxQuotedResRows] まで）。ツリーで表している親は引用しない——すぐ上の行が
/// その本体で、同じものが 2 度出ることになるため。
ThreadTreeLayout layOutThreadTree(List<Res> res, {required int settledCount}) {
  final byNumber = {for (final r in res) r.number: r};
  final targetsOf = _targetsOf(res, byNumber);

  /// [number] の返信先のうち、行の並びでは表せていないもの。[parent] はツリーで
  /// ぶら下げた親（根なら null）で、それだけは引用しない。
  List<int> quotedFor(int number, {int? parent}) => [
    for (final n in targetsOf[number] ?? const <int>[])
      if (n != parent) n,
  ].take(maxQuotedResRows).toList();

  final count = settledCount.clamp(0, res.length);
  final settledRes = res.take(count).toList();
  final settledNumbers = {for (final r in settledRes) r.number};

  /// ツリー側でぶら下げる親。先頭の返信先がツリー側にいなければ根になる。
  int? settledParentOf(Res r) {
    final parent = targetsOf[r.number]?.first;
    return parent != null && settledNumbers.contains(parent) ? parent : null;
  }

  // 親ごとの子（レスの並び順＝番号順のまま）と、親を持たない根。
  final children = <int, List<Res>>{};
  final roots = <Res>[];
  for (final r in settledRes) {
    final parent = settledParentOf(r);
    if (parent != null) {
      (children[parent] ??= <Res>[]).add(r);
    } else {
      roots.add(r);
    }
  }

  // 行きがけ順に展開する。1000 レスの数珠つなぎでも安全なよう再帰は使わない。
  final settled = <ThreadTreeRow>[];
  final stack = <({Res res, int depth})>[
    for (final r in roots.reversed) (res: r, depth: 0),
  ];
  while (stack.isNotEmpty) {
    final entry = stack.removeLast();
    // 親以外の返信先は、そのレスと同じ深さの引用行にして手前へ。
    for (final n in quotedFor(
      entry.res.number,
      parent: settledParentOf(entry.res),
    )) {
      settled.add(
        ThreadTreeRow(res: byNumber[n]!, depth: entry.depth, quote: true),
      );
    }
    settled.add(ThreadTreeRow(res: entry.res, depth: entry.depth));
    final kids = children[entry.res.number];
    if (kids == null) continue;
    for (final kid in kids.reversed) {
      stack.add((res: kid, depth: entry.depth + 1));
    }
  }

  // 新着側。**返信先も新着なら、その直下へ入れてツリーにする**（あとから来た
  // 返信でも同じ）。返信先がツリー側にあるレスは新着側の根で、その指し先を
  // 引用で手前に再掲する。根の並びは届いた順（＝番号順）のまま。
  final arrivalRes = res.skip(count).toList();
  final arrivalNumbers = {for (final r in arrivalRes) r.number};

  /// 新着側でぶら下げる親。先頭の返信先が新着でなければ（＝ツリー側なら）根。
  int? arrivalParentOf(Res r) {
    final parent = targetsOf[r.number]?.first;
    return parent != null && arrivalNumbers.contains(parent) ? parent : null;
  }

  final arrivalChildren = <int, List<Res>>{};
  final arrivalRoots = <Res>[];
  for (final r in arrivalRes) {
    final parent = arrivalParentOf(r);
    if (parent != null) {
      (arrivalChildren[parent] ??= <Res>[]).add(r);
    } else {
      arrivalRoots.add(r);
    }
  }

  // 根は引用先ごとにまとめる。同じレスを指した新着は、間に別の新着を挟んでも
  // 先に来たものと同じ引用行の下へ並べる（引用が何度も出てこないし、同じ話題
  // への返信がばらけない）。まとめるのは**指し先の並びがそっくり同じ**ときだけ
  // で、`>>1` と `>>1 >>3` は別のまとまりになる（後者の下へ入れると 3 へも
  // 返したように読めてしまう）。指し先の無い根はそれ 1 つでひとまとまり。
  final groups = <({List<int> quoted, List<Res> roots})>[];
  final groupOfQuoted = <String, int>{};
  for (final root in arrivalRoots) {
    // 根の返信先はどれもツリー側のレス（新着を指していれば根にならない）。
    final quoted = quotedFor(root.number);
    if (quoted.isEmpty) {
      groups.add((quoted: quoted, roots: <Res>[root]));
      continue;
    }
    final key = quoted.join(',');
    final at = groupOfQuoted[key];
    if (at != null) {
      groups[at].roots.add(root);
      continue;
    }
    groupOfQuoted[key] = groups.length;
    groups.add((quoted: quoted, roots: <Res>[root]));
  }

  final arrivals = <ThreadTreeRow>[];
  for (final group in groups) {
    for (final n in group.quoted) {
      arrivals.add(ThreadTreeRow(res: byNumber[n]!, quote: true));
    }
    final rootDepth = group.quoted.isEmpty ? 0 : 1;
    for (final root in group.roots) {
      final stack = <({Res res, int depth})>[(res: root, depth: rootDepth)];
      while (stack.isNotEmpty) {
        final entry = stack.removeLast();
        // 根の返信先は上のまとまりの見出しで出している。ぶら下がった返信だけ、
        // 親以外の返信先をここで添える。
        if (entry.depth > rootDepth) {
          for (final n in quotedFor(
            entry.res.number,
            parent: arrivalParentOf(entry.res),
          )) {
            arrivals.add(
              ThreadTreeRow(res: byNumber[n]!, depth: entry.depth, quote: true),
            );
          }
        }
        arrivals.add(ThreadTreeRow(res: entry.res, depth: entry.depth));
        final kids = arrivalChildren[entry.res.number];
        if (kids == null) continue;
        for (final kid in kids.reversed) {
          stack.add((res: kid, depth: entry.depth + 1));
        }
      }
    }
  }

  return ThreadTreeLayout(settled: settled, arrivals: arrivals);
}

/// ツリーの字下げ。深さ 0 では何も足さない（番号順表示と同じ見た目）。
///
/// **レスの左アクセント帯（自分宛・検索の現在位置）はこの帯に移す**（[accent]）。
/// レス側（[PostItem]）にも描かせると、字下げ帯の数 px 右にもう 1 本縦線が走って
/// 「揃っていない 2 本」に見える。色を持つのが 1 本だけなら、深さの筋と目印が
/// 同じ列に乗る。深さ 0 では字下げ帯そのものが無いので、レス側に任せる
/// （番号順表示と同じ見た目＝左端に帯）。
class ThreadTreeTier extends StatelessWidget {
  const ThreadTreeTier({
    super.key,
    required this.depth,
    required this.child,
    this.accent,
  });

  final int depth;
  final Widget child;

  /// 字下げ帯に移してきた目印の色。無ければ深さの筋として淡く描く。
  final Color? accent;

  /// 字下げを増やす上限。これ以上深くなっても下げない。深いツリーで本文幅が
  /// 潰れて表示が破綻するのを防ぐ（会話シートと同じ考え方）。
  static const _maxIndentLevels = 6;
  static const _indentStep = 14.0;

  /// 帯と本文の間。**帯の太さと足して一定**にしてあり、目印が付いた行でも本文の
  /// 位置は動かない（[PostItem] が帯の分だけ左パディングを詰めるのと同じ理屈）。
  ///
  /// ここを広く取る必要はない。この先には [PostItem] 自身の左パディング（16）が
  /// 続くので、帯から中身までは足し算で空く。深さ 0 の行が画面端から 16 で始まる
  /// のに対し、字下げした行のほうが余白が広い、という逆転を作らない値にする。
  static const _barAndGap = 4.0;

  @override
  Widget build(BuildContext context) {
    if (depth <= 0) return child;
    final scheme = Theme.of(context).colorScheme;
    final levels = depth < _maxIndentLevels ? depth : _maxIndentLevels;
    final width = accent != null ? 3.0 : 2.0;
    return Padding(
      padding: EdgeInsets.only(left: levels * _indentStep),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: accent ?? scheme.outlineVariant.withValues(alpha: 0.8),
              width: width,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(left: _barAndGap - width),
          child: child,
        ),
      ),
    );
  }
}

/// レス本文を 1 行に潰した抜粋。引用行と、入力欄の返信先表示で使う。
/// 改行や連続する空白は 1 つの空白にまとめる（1 行に収めるため）。
String resExcerpt(Res res) =>
    res.isAbone ? 'あぼーん' : _oneLine(htmlToText(res.body));

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 引用行に出す返信先の中身。文章と、そこに貼られていた画像に分けたもの。
class QuotedResBody {
  const QuotedResBody({
    required this.excerpt,
    required this.images,
    this.asciiArt,
  });

  /// 1 行に潰した本文。画像 URL の文字列は除いてある。
  final String excerpt;

  /// 本文に貼られていた画像。出現順・重複除去。
  final List<Uri> images;

  /// 本文が AA だったときの、改行とインデントを残したままの本文（前後の空行だけ
  /// 落としたもの）。AA でなければ null。
  ///
  /// AA を 1 行に潰すと `∧＿∧ （ ´∀｀） （ ）` のような記号の列になり、元が
  /// 何の絵だったかは読み取れない。画像 URL をサムネイルに替えているのと同じ
  /// 理由で、**絵は絵のまま小さく出す**（[QuotedResRow]）。
  final String? asciiArt;
}

/// 返信先の本文を「文章」と「画像」へ分ける。
///
/// 画像 URL は長いうえに、文字列を読んでも何が写っているかは分からない。1 行しか
/// 無い引用行では URL 1 本で抜粋が埋まってしまい、「何への返信か」を思い出す手掛
/// かりにならない。**URL の文字列は落として、代わりに小さなサムネイルを出す**。
/// レス本体で本文中の URL をサムネイルへ置き換えている（[splitPostBody]）のと
/// 同じ扱いを、引用行でも小さくやる。
///
/// 動画・音声・埋め込み（YouTube 等）の URL は文章のまま残す。引用行に置ける
/// 大きさでは再生の札を出しても潰れるだけで、URL の文字列の方がまだ何のリンクか
/// が分かる。
QuotedResBody quotedResBody(Res res) {
  if (res.isAbone) return const QuotedResBody(excerpt: 'あぼーん', images: []);
  final text = htmlToText(res.body);
  final images = <Uri>[];
  final seen = <String>{};
  final rest = StringBuffer();
  var cursor = 0;
  for (final m in linkUrlRe.allMatches(text)) {
    final uri = normalizedLinkUri(m.group(0)!);
    if (uri == null || !isImageUrl(uri)) continue;
    rest.write(text.substring(cursor, m.start));
    cursor = m.end;
    if (seen.add(uri.toString())) images.add(uri);
  }
  rest.write(text.substring(cursor));
  final body = rest.toString();
  return QuotedResBody(
    excerpt: _oneLine(body),
    images: images,
    asciiArt: looksLikeAsciiArt(body) ? _trimBlankLines(body) : null,
  );
}

/// 前後の空行だけを落とす。行頭の空白は絵の一部なので触らない。
String _trimBlankLines(String text) {
  final lines = text.split('\n');
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].trim().isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  return lines.sublist(start, end).join('\n');
}

/// 新着レスの手前に薄く再掲する返信先。
///
/// 本体はツリー側（画面のずっと上）にあって見えないので、番号と本文の頭だけを
/// 控えめに出して「何への返信か」を思い出せるようにする。押すと会話を開ける。
///
/// **1 行に収める。** 返信先そのものではなく思い出すための手掛かりなので、番号・
/// ID の絵・抜粋・サムネイルを横一列に置き、抜粋は 1 行で切る。返信の多いスレでは
/// レスの数だけこの行が挟まるため、2 行取ると一覧が引用で埋まってレス本体が
/// 追えなくなる。日時も出さない（同じ理由で、行に置ける情報を「誰の・何の話か」
/// ——ID の絵と本文の頭——に絞る）。
///
/// **画像と AA だけは 1 行を超える。** どちらも文字に直すと（長い URL・記号の列）
/// 何への返信かを思い出す手掛かりにならないので、サムネイル（[QuoteThumbs]）と
/// 縮めた絵（[QuoteAsciiArt]）に替えて、絵として読める高さを取る。
class QuotedResRow extends StatelessWidget {
  const QuotedResRow({
    super.key,
    required this.res,
    this.onTap,
    this.blurImages = false,
    this.joinsPrevious = false,
  });

  final Res res;
  final VoidCallback? onTap;

  /// 返信先に「グロ」注意が付いており、サムネイルをぼかしたまま出すか。
  final bool blurImages;

  /// すぐ上の行も引用行か。
  ///
  /// **複数に返しているレス**（`>>5 >>7`）では引用行が続けて並ぶ。間を空けると
  /// 1 本ずつ別の何かに見えるので、続くときは詰めて重ねる。左の縦線も繋がって、
  /// 「この返信が指している相手たち」がひと塊に読める。
  final bool joinsPrevious;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = scheme.onSurfaceVariant.withValues(alpha: 0.7);
    final body = quotedResBody(res);
    final excerpt = body.excerpt;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, joinsPrevious ? 0 : 10, 16, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.8),
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(8, 2, 0, 2),
          child: Row(
            children: [
              // 番号は `>>N` ではなく裸で出す。この行は返信先そのものなので、
              // `>>` を付けるとこの行が N への返信に見えてしまう。
              Text(
                '${res.number}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: dim,
                  fontWeight: FontWeight.w600,
                ),
              ),
              // 返信先が誰かはヘッダのアイコンと見比べて分かればいいので、
              // ここも同じ絵を出す。この行の ID は押せないため輪は付けない。
              if (res.id != null) ...[
                const SizedBox(width: 6),
                Semantics(
                  label: 'ID:${res.id}',
                  child: IdIcon(id: res.id!, size: 14),
                ),
              ],
              // AA は 1 行に潰すと記号の列にしかならないので、縮めた絵で出す。
              if (body.asciiArt case final art?) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: QuoteAsciiArt(text: art, color: dim),
                ),
              ] else if (excerpt.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    excerpt,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dim),
                  ),
                ),
              ],
              if (body.images.isNotEmpty)
                QuoteThumbs(urls: body.images, blurred: blurImages, color: dim),
            ],
          ),
        ),
      ),
    );
  }
}

/// 引用行に出す AA の高さの上限。
///
/// サムネイル（32）より少しだけ高い程度に留める。引用行はレスの数だけ挟まるので、
/// ここを伸ばすほど一覧が引用で埋まる。AA は縦に長いもの（10 行超）もあるが、
/// **読ませるためではなく「あの絵だ」と思い出させるため**に置くので、字が読める
/// 大きさまで確保する必要はない。行の高さより優先するのは形（シルエット）の方。
const double quoteAsciiArtMaxHeight = 48;

/// 返信先の AA を、収まる大きさへ縮めて出す。
///
/// 幅・高さの収まる分だけ**縦横同じ率で**縮める（[BoxFit.scaleDown]）。行ごとに
/// 折り返すと絵が崩れるので折り返さず、元より大きくもしない——小さい AA は本文と
/// 同じ大きさのまま出る。
///
/// 引用行（[QuotedResRow]）と、入力欄の上に出る返信先の帯の両方で使う。どちらも
/// 「何への返信か」を思い出すための添え物なので、同じ形で出す。
class QuoteAsciiArt extends StatelessWidget {
  const QuoteAsciiArt({
    super.key,
    required this.text,
    required this.color,
    this.maxHeight = quoteAsciiArtMaxHeight,
  });

  final String text;

  /// 引用行のほかの字と揃えた色。
  final Color color;

  /// 縮めた絵の高さの上限。
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          softWrap: false,
          style: asciiArtStyle(
            (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 引用行のサムネイルの一辺。
///
/// 字の高さ（16 ほど）に揃えれば画像の有無で行の高さが変わらず一覧は静かになる
/// が、その大きさでは**何が写っているか分からない**。分からない絵は「何への返信
/// か」の手掛かりにならず、置く意味が無くなってしまう。**絵として読める方を取り**、
/// 画像のある引用行だけ 32 まで伸ばす。文章だけの引用行は 1 行のまま。
const double _quoteThumbSize = 32;

/// 引用行に並べるサムネイルの上限。返信先を思い出すには 1 枚目でだいたい足りる
/// ので、残りは「+N」で枚数だけ伝えて、抜粋の場所を潰さない。
const int _quoteThumbLimit = 3;

/// 引用行に添える小さなサムネイルの並び。
///
/// 入力欄の上に出る返信先の帯でも同じものを使う。どちらも「何への返信か」を
/// 1 行で思い出すための添え物なので、同じ大きさ・同じ枚数で揃える。
class QuoteThumbs extends StatelessWidget {
  const QuoteThumbs({
    super.key,
    required this.urls,
    required this.blurred,
    required this.color,
  });

  final List<Uri> urls;
  final bool blurred;

  /// 「+N」の色。引用行のほかの字と揃える。
  final Color color;

  @override
  Widget build(BuildContext context) {
    final shown = urls.take(_quoteThumbLimit);
    final rest = urls.length - _quoteThumbLimit;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final url in shown)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _QuoteThumb(url: url, blurred: blurred),
          ),
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '+$rest',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
      ],
    );
  }
}

/// 引用行のサムネイル 1 枚。
///
/// **押せない。** タップは引用行そのもの（会話を開く）に通す。ここで開けるように
/// すると、返信先を思い出すために置いた小さな絵が、行の中に別の当たり判定を作る
/// ことになる。絵を大きく見たいときは、行を押して会話を開けばレス本体がある。
///
/// 同じ理由で、NG・大きすぎる画像・読み込み失敗はどれも無地の枠に落とす。本体側
/// にある逃げ道（タップで解除・タップで読み込む）はここでは出せないので、**何かが
/// 貼られている**ことだけを伝える。
class _QuoteThumb extends StatelessWidget {
  const _QuoteThumb({required this.url, required this.blurred});

  final Uri url;
  final bool blurred;

  @override
  Widget build(BuildContext context) {
    // NG 画像の増減で枠に切り替わる（本体側と同じ扱い）。
    return ListenableBuilder(
      listenable: NgStore.shared,
      builder: (context, _) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: _quoteThumbSize,
          height: _quoteThumbSize,
          child: _picture(context),
        ),
      ),
    );
  }

  Widget _picture(BuildContext context) {
    if (NgStore.shared.isNgImageUrl(url)) {
      return const _QuoteThumbFrame(icon: Icons.hide_image_outlined);
    }
    // 既に大きすぎると分かっている URL は、通信する前に枠へ落とす。
    if (ImageLoadPolicy.skipsAutoLoad(url)) {
      return const _QuoteThumbFrame(icon: Icons.image_outlined);
    }
    final image = Image(
      image: RemoteImage(
        url,
        target: Size.square(
          _quoteThumbSize * MediaQuery.devicePixelRatioOf(context),
        ),
        cover: true,
        maxBytes: ImageLoadPolicy.limitFor(url),
      ),
      width: _quoteThumbSize,
      height: _quoteThumbSize,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const _QuoteThumbFrame(),
      errorBuilder: (context, error, stack) => _QuoteThumbFrame(
        icon: switch (error) {
          ImageTooLargeException() => Icons.image_outlined,
          ImageNgException() => Icons.hide_image_outlined,
          _ => Icons.broken_image_outlined,
        },
      ),
    );
    if (!blurred) return image;
    // 「グロ」注意の付いたレスは引用行でも中身を出さない。本体のモザイクと違って
    // 解除のタップが無い（タップは会話を開く）ので、ぼかしたままにする。
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: image,
    );
  }
}

/// サムネイルの代わりに出す無地の枠。読み込み中は絵記号なしで枠だけ。
class _QuoteThumbFrame extends StatelessWidget {
  const _QuoteThumbFrame({this.icon});

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: icon == null
          ? null
          : Icon(icon, size: 16, color: scheme.onSurfaceVariant),
    );
  }
}
