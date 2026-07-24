/// 貼られた板 URL から掲示板ホストと板キーを取り出す。
///
/// 「URL から板を追加」の入口。5ch 互換掲示板はホストが分散する（eddibb /
/// mi.5ch.net / greta.5ch.net …）ため、BBSMENU を持たず、貼られた URL の
/// ホストをそのまま使う方針。ホストの一致判定はしない（解析だけ）。
///
/// 対応する形:
/// - `https://host/{board}/`（板トップ。末尾スラッシュ有無どちらも）
/// - `https://host/{board}/subject.txt` / `SETTING.TXT`（生ファイル）
/// - `https://host/test/read.cgi/{board}/{key}...`（スレ URL）
/// - `https://host/{server}/test/read.cgi/{board}/{key}...`（5ch itest のスレ URL。
///   `read.cgi` がパス途中に来る）
/// - `https://host/subback/{board}[.html]`（5ch の subback スレ一覧ページ）
/// - `https://host/{board}/{key}` や `.../dat/{key}.dat`（スレ URL）
///
/// スレ URL・一覧ページを貼られても板だけを拾う。ホストは URL のものをそのまま
/// 返す（5ch のインターフェースホスト itest 等の実サーバ解決は呼び出し側の責務）。
/// 判別できなければ null。
library;

import 'thread_url.dart' show boardKeyPattern;

/// 板 URL から取り出した参照。
class BoardRef {
  const BoardRef({required this.host, required this.boardKey});

  /// 掲示板ホスト（例: `bbs.eddibb.cc`, `mi.5ch.net`）。
  final String host;

  /// 板キー（例: `liveedge`, `news4vip`）。
  final String boardKey;

  @override
  bool operator ==(Object other) =>
      other is BoardRef && other.host == host && other.boardKey == boardKey;

  @override
  int get hashCode => Object.hash(host, boardKey);

  @override
  String toString() => 'BoardRef($host/$boardKey)';
}

/// 板 URL 以外で先頭に来うる予約パス。これを板キーと誤認しない。
const _reserved = {
  'test',
  'read.cgi',
  'subback',
  'subbbs.cgi',
  'bbs.cgi',
  'api',
  'dat',
  'kako',
};

/// [uri] が板 URL なら [BoardRef] を返す。判別不能なら null。
BoardRef? parseBoardUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;

  // 先頭・末尾の空セグメントを落とす（`/liveedge/` → [liveedge]）。
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;

  // read.cgi はパス途中にも現れる（5ch itest: `/{server}/test/read.cgi/{board}/…`）。
  // その次のセグメントが板キー。
  final rc = segs.indexOf('read.cgi');
  if (rc >= 0 && rc + 1 < segs.length) return _build(uri.host, segs[rc + 1]);

  // subback（5ch のスレ一覧 HTML）: `/subback/{board}[.html]`。
  final sb = segs.indexOf('subback');
  if (sb >= 0 && sb + 1 < segs.length) {
    return _build(uri.host, _stripSuffix(segs[sb + 1]));
  }

  // それ以外は先頭セグメントを板キーとみなす（板トップ・subject.txt・正規スレ URL）。
  return _build(uri.host, _stripSuffix(segs[0]));
}

/// 末尾の `.html` / `.htm` を落とす（subback の `{board}.html` 対策）。
String _stripSuffix(String s) {
  for (final ext in const ['.html', '.htm']) {
    if (s.endsWith(ext)) return s.substring(0, s.length - ext.length);
  }
  return s;
}

BoardRef? _build(String host, String board) {
  if (_reserved.contains(board)) return null;
  if (!boardKeyPattern.hasMatch(board)) return null;
  return BoardRef(host: host, boardKey: board);
}
