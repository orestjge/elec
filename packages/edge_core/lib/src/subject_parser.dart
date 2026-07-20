import 'package:edge_sjis/edge_sjis.dart';

import 'models.dart';

/// `title [cap★] (resCount)` の末尾を分解する正規表現。
///
/// 末尾から順に、任意の `[xxx★]`（cap 名）と必須の `(数字)`（レス数）。
final _tailRe = RegExp(r'^(.*?)(?:\s\[([^\]]*)★\])?\s\((\d+)\)$');

/// subject.txt（SJIS バイト列）をパースしてスレッド一覧にする。
///
/// 各行の形式（`eddist-server/src/domain/thread_list.rs`）:
/// - 通常: `{key}.dat<>{title} ({resCount})`
/// - cap 付き: `{key}.dat<>{title} [{cap}★] ({resCount})`
///
/// [metadent] が true のときは `subject-metadent.txt` を想定し、`[xxx★]` を
/// cap 名ではなくスレ立て人の metadent として [ThreadSummary.metadent] に入れる
/// （このファイルでは全スレに metadent が付き、cap 名は出力されない）。
List<ThreadSummary> parseSubject(
  List<int> subjectBytes, {
  bool metadent = false,
}) {
  final text = decodeSjis(subjectBytes);
  final result = <ThreadSummary>[];
  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    final entry = parseSubjectLine(line, metadent: metadent);
    if (entry != null) result.add(entry);
  }
  return result;
}

/// subject.txt の 1 行をパースする。形式に合わなければ null。
///
/// [metadent] については [parseSubject] を参照。
ThreadSummary? parseSubjectLine(String line, {bool metadent = false}) {
  final sep = line.indexOf('<>');
  if (sep < 0) return null;

  final left = line.substring(0, sep);
  final right = line.substring(sep + 2);
  if (!left.endsWith('.dat')) return null;
  final key = left.substring(0, left.length - 4);
  if (key.isEmpty) return null;

  final m = _tailRe.firstMatch(right);
  if (m == null) {
    // `(n)` が無い異常系。タイトルだけ拾い、レス数 0 で通す。
    return ThreadSummary(key: key, title: right, resCount: 0, capName: null);
  }
  final tag = m.group(2);
  return ThreadSummary(
    key: key,
    title: m.group(1)!,
    resCount: int.parse(m.group(3)!),
    capName: metadent ? null : tag,
    metadent: metadent ? tag : null,
  );
}
