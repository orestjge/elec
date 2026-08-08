import 'html_text.dart';
import 'models.dart';

/// レス参照の `>>` に続く番号の並び。単発（`1`）・範囲（`3-5`）と、それらを
/// `,` で繋いだまとめ書き（`1,3,5`・`1,3-5`）を 1 つの参照として表す。
///
/// 区切りは半角 `,` だけにする。`>>1、そうだね` のように読点は地の文の句読点
/// として使われるので、これを区切りに含めると続く文まで参照に飲み込んでしまう。
/// 捕獲グループを持たないので、他のパターンと並べても番号がずれない。
const resAnchorSpecPattern = r'\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*';

final _anchorRe = RegExp('>>($resAnchorSpecPattern)');

/// 1 つの参照あたりに読む番号の上限。誤爆や重い表示を避けるための打ち切り。
const _maxAnchorNumbers = 50;

/// レス参照の番号部分（[resAnchorSpecPattern] に一致する文字列）を、指している
/// レス番号の並びに開く。
///
/// 範囲は昇順に展開し、逆順（`5-3`）も同じ範囲として読む。書かれた順を保った
/// まま重複を落とし、1 つの参照あたり 50 件で打ち切る。
List<int> resNumbersInAnchor(String spec) {
  final result = <int>[];
  final seen = <int>{};
  for (final part in spec.split(',')) {
    final dash = part.indexOf('-');
    // 桁が多すぎて int にならない番号は、そんなレスが無いので読み飛ばす。
    final start = int.tryParse(dash < 0 ? part : part.substring(0, dash));
    if (start == null) continue;
    final end = dash < 0 ? start : int.tryParse(part.substring(dash + 1));
    if (end == null) continue;
    final from = start <= end ? start : end;
    final to = start <= end ? end : start;
    for (var n = from; n <= to; n++) {
      if (result.length >= _maxAnchorNumbers) return result;
      if (seen.add(n)) result.add(n);
    }
  }
  return result;
}

/// 本文中の `>>N` / `>>N-M` / `>>N,M` が参照しているレス番号を返す。
List<int> referencedResNumbers(String text) {
  final result = <int>[];
  final seen = <int>{};
  for (final m in _anchorRe.allMatches(htmlToText(text))) {
    for (final n in resNumbersInAnchor(m.group(1)!)) {
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
