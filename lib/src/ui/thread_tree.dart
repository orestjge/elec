/// ツリー表示の行組み。
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

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import 'format.dart';
import 'id_icon.dart';
import 'now_ticker.dart';

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

/// ツリー表示の行。境界（新着ライン）を挟んで [settled] と [arrivals] に
/// 分かれる。
class ThreadTreeLayout {
  const ThreadTreeLayout({required this.settled, required this.arrivals});

  /// 開いた時点までのレス。`>>N` の親子でぶら下げたツリー。
  final List<ThreadTreeRow> settled;

  /// 開いたあとに増えたレス。根は届いた順に並び、新着どうしの返信はその根の
  /// 下でツリーになる。
  final List<ThreadTreeRow> arrivals;
}

/// 番号順表示の行。dat の順にそのまま並べる。
List<ThreadTreeRow> flatThreadRows(List<Res> res) => [
  for (final r in res) ThreadTreeRow(res: r),
];

/// ツリー表示の行を組む。[settledCount] 件目までがツリー、それ以降が新着。
///
/// 親は **本文で最初に指している既存の若いレス**（`>>5 >>7` なら 5）。番号が
/// 若い方へしか繋がないので循環しない。指し先が無い・自分より新しい番号しか
/// 指していないレスは根になる。
ThreadTreeLayout layOutThreadTree(List<Res> res, {required int settledCount}) {
  final byNumber = {for (final r in res) r.number: r};
  final parentOf = <int, int>{};
  for (final r in res) {
    for (final n in referencedResNumbers(r.body)) {
      if (n < r.number && byNumber.containsKey(n)) {
        parentOf[r.number] = n;
        break;
      }
    }
  }

  final count = settledCount.clamp(0, res.length);
  final settledRes = res.take(count).toList();
  final settledNumbers = {for (final r in settledRes) r.number};

  // 親ごとの子（レスの並び順＝番号順のまま）と、親を持たない根。
  final children = <int, List<Res>>{};
  final roots = <Res>[];
  for (final r in settledRes) {
    final parent = parentOf[r.number];
    if (parent != null && settledNumbers.contains(parent)) {
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
  final arrivalChildren = <int, List<Res>>{};
  final arrivalRoots = <Res>[];
  for (final r in arrivalRes) {
    final parent = parentOf[r.number];
    if (parent != null && arrivalNumbers.contains(parent)) {
      (arrivalChildren[parent] ??= <Res>[]).add(r);
    } else {
      arrivalRoots.add(r);
    }
  }

  // 根は引用先ごとにまとめる。同じレスを指した新着は、間に別の新着を挟んでも
  // 先に来たものと同じ引用行の下へ並べる（引用が何度も出てこないし、同じ話題
  // への返信がばらけない）。指し先の無い根はそれ 1 つでひとまとまり。
  final groups = <({int? quoted, List<Res> roots})>[];
  final groupOfQuoted = <int, int>{};
  for (final root in arrivalRoots) {
    // 根の返信先があれば、それはツリー側のレス（新着なら根にならない）。
    final quoted = parentOf[root.number];
    final at = quoted == null ? null : groupOfQuoted[quoted];
    if (at != null) {
      groups[at].roots.add(root);
      continue;
    }
    if (quoted != null) groupOfQuoted[quoted] = groups.length;
    groups.add((quoted: quoted, roots: <Res>[root]));
  }

  final arrivals = <ThreadTreeRow>[];
  for (final group in groups) {
    final quoted = group.quoted;
    if (quoted != null) {
      arrivals.add(ThreadTreeRow(res: byNumber[quoted]!, quote: true));
    }
    final rootDepth = quoted == null ? 0 : 1;
    for (final root in group.roots) {
      final stack = <({Res res, int depth})>[(res: root, depth: rootDepth)];
      while (stack.isNotEmpty) {
        final entry = stack.removeLast();
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
String resExcerpt(Res res) => res.isAbone
    ? 'あぼーん'
    : htmlToText(res.body).replaceAll(RegExp(r'\s+'), ' ').trim();

/// 引用行に添える日時。24 時間以内なら「たった今 / n分前 / n時間前」、それより
/// 古ければ `MM/DD HH:MM`。日時の分からないレス（あぼーん・1001）では空。
///
/// 古い側で日付まで出すのはヘッダ（HH:MM だけ）と違う扱いだが、引用先は画面の
/// ずっと上＝別の日のことも多く、時刻だけでは「いつの話か」が分からないため。
/// [now] は試験用。
String quotedResTime(Res res, {DateTime? now}) {
  final relative = relativeResTime(res.dateTime, now: now);
  if (relative != null) return relative;
  final m = RegExp(
    r'(\d{4})/(\d{2})/(\d{2}).*?(\d{2}:\d{2})',
  ).firstMatch(res.dateText);
  if (m == null) return '';
  return '${m.group(2)}/${m.group(3)} ${m.group(4)}';
}

/// 新着レスの手前に薄く再掲する返信先。
///
/// 本体はツリー側（画面のずっと上）にあって見えないので、番号と本文の頭だけを
/// 控えめに出して「何への返信か」を思い出せるようにする。押すと会話を開ける。
class QuotedResRow extends StatelessWidget {
  const QuotedResRow({super.key, required this.res, this.onTap});

  final Res res;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = scheme.onSurfaceVariant.withValues(alpha: 0.7);
    final excerpt = resExcerpt(res);
    final time = quotedResTime(res);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
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
                  // いつのレスへの返信かは、それが前の日の話かどうかで意味が
                  // 変わる。引用先は画面のずっと上＝時間も離れていることが多い
                  // ので、ヘッダの時刻（HH:MM のみ）より情報を足して出す。
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    LiveResTime(
                      when: res.dateTime,
                      text: (now) => quotedResTime(res, now: now),
                      builder: (context, text) => Text(
                        text,
                        style: theme.textTheme.labelSmall?.copyWith(color: dim),
                      ),
                    ),
                  ],
                ],
              ),
              if (excerpt.isNotEmpty)
                Text(
                  excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dim),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
