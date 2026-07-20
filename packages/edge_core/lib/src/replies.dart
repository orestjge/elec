import 'html_text.dart';
import 'models.dart';

final _anchorRe = RegExp(r'>>(\d+)(?:-(\d+))?');

/// 本文中の `>>N` / `>>N-M` が参照しているレス番号を返す。
///
/// 範囲指定は昇順に展開する。極端に大きい範囲は誤爆や重い表示を避けるため
/// 50 件で打ち切る。
List<int> referencedResNumbers(String text) {
  final result = <int>[];
  final seen = <int>{};
  for (final m in _anchorRe.allMatches(htmlToText(text))) {
    final start = int.parse(m.group(1)!);
    final endText = m.group(2);
    final end = endText == null ? start : int.parse(endText);
    final from = start <= end ? start : end;
    final to = start <= end ? end : start;
    for (var n = from; n <= to && n < from + 50; n++) {
      if (seen.add(n)) result.add(n);
    }
  }
  return result;
}

/// 各レスが受けた返信の数を数える。
///
/// あるレス番号 N に対し、本文に `>>N` を含むレスの数（＝返信数）を
/// `{N: 件数}` で返す。本文は [htmlToText] で正規化してから見る
/// （dat 上は `&gt;&gt;N` とエスケープされているため）。
///
/// 1 つのレスが同じ番号を複数回参照しても、その番号への返信は 1 と数える。
Map<int, int> replyCounts(List<Res> res) {
  final counts = <int, int>{};
  for (final r in res) {
    final seen = <int>{};
    for (final n in referencedResNumbers(r.body)) {
      if (seen.add(n)) {
        counts[n] = (counts[n] ?? 0) + 1;
      }
    }
  }
  return counts;
}

/// レス番号 [number] に返信している（本文に `>>number` を含む）レスを返す。
List<Res> repliesTo(List<Res> res, int number) {
  return res
      .where((r) => referencedResNumbers(r.body).contains(number))
      .toList();
}

/// 本文に「グロ」注意の文字が含まれるか。dat 上のエスケープや `<br>` を跨いだ
/// 表記も拾えるよう [htmlToText] で正規化してから素朴に部分一致で見る。
/// これで「グロ」「グロい」「グロ注意」「グロ画像」等をまとめて拾える。
bool _hasGuroMark(String body) => htmlToText(body).contains('グロ');

/// 画像サムネイルにモザイクを掛けるべきレス番号の集合を返す。
///
/// 次のいずれかに当てはまるレスの番号を含める。
/// - そのレスの本文自身に「グロ」の文字を含む（自己申告のグロ画像など）。
/// - そのレスへ `>>N` で返信したいずれかのレスの本文に「グロ」の文字を含む
///   （画像に対して他レスが「グロ」と付けた場合）。
///
/// 実際にモザイクを掛けるかは、対象レスが画像を含むかどうかも合わせて
/// 表示層で判断する。
Set<int> guroMaskedResNumbers(List<Res> res) {
  final marked = <int>{};
  for (final r in res) {
    if (!_hasGuroMark(r.body)) continue;
    // グロと書いたレス自身と、そのレスが返信している番号の双方に印を付ける。
    marked.add(r.number);
    marked.addAll(referencedResNumbers(r.body));
  }
  return marked;
}
