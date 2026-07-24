/// レス本文などに現れるスレッド URL から板キーとスレキーを取り出す。
///
/// 対応する形（5ch 互換・eddist）:
/// - `/test/read.cgi/{board}/{key}` （末尾に `/`, `/l50`, `/1-100` 等が付き得る）
/// - `/{board}/{key}` （フロントの正規 URL。read.cgi はここへ 30x する）
/// - `/{board}/dat/{key}.dat` （dat 直リンク）
/// - `/{board}/kako/{th4}/{th5}/{key}.dat` （過去ログ dat）
///
/// ホストの一致判定はここではしない（板固定のアプリ側で、自ホスト・自板かを
/// 照合してからアプリ内遷移に使う）。判別できなければ null。
library;

/// スレッド URL から取り出した参照。
class ThreadRef {
  const ThreadRef({required this.board, required this.threadKey, this.resSpec});

  /// 板キー（例: `liveedge`）。
  final String board;

  /// スレッドキー（UNIX 時刻由来の数値文字列）。
  final String threadKey;

  /// レス位置指定（`l50`, `1-100`, `5` 等）。無ければ null。今は保持だけ。
  final String? resSpec;

  @override
  bool operator ==(Object other) =>
      other is ThreadRef &&
      other.board == board &&
      other.threadKey == threadKey &&
      other.resSpec == resSpec;

  @override
  int get hashCode => Object.hash(board, threadKey, resSpec);

  @override
  String toString() =>
      'ThreadRef($board/$threadKey${resSpec == null ? '' : '/$resSpec'})';
}

/// 板キーとして妥当か（英数と `_` のみ）。板 URL 解析（[[board_url]]）でも使う。
final boardKeyPattern = RegExp(r'^[0-9a-zA-Z_]+$');

/// 板キーとして妥当か（英数と `_` のみ）。
final _boardRe = boardKeyPattern;

/// スレッドキーとして妥当か（10 桁以上の数字。UNIX 秒）。
final _keyRe = RegExp(r'^\d{9,}$');

/// [uri] がスレッド URL なら [ThreadRef] を返す。判別不能なら null。
ThreadRef? parseThreadUrl(Uri uri) {
  // 先頭・末尾の空セグメントを落とす（`/a/b/` → [a, b]）。
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;

  // /test/read.cgi/{board}/{key}[/{pos}]
  if (segs.length >= 4 && segs[0] == 'test' && segs[1] == 'read.cgi') {
    return _build(
      board: segs[2],
      key: segs[3],
      resSpec: segs.length >= 5 ? segs[4] : null,
    );
  }

  // /{board}/dat/{key}.dat
  if (segs.length == 3 && segs[1] == 'dat') {
    return _build(board: segs[0], key: _stripDat(segs[2]));
  }

  // /{board}/kako/{th4}/{th5}/{key}.dat
  if (segs.length == 5 && segs[1] == 'kako') {
    return _build(board: segs[0], key: _stripDat(segs[4]));
  }

  // /{board}/{key}[/{pos}]
  if (segs.length >= 2) {
    return _build(
      board: segs[0],
      key: segs[1],
      resSpec: segs.length >= 3 ? segs[2] : null,
    );
  }

  return null;
}

String _stripDat(String s) =>
    s.endsWith('.dat') ? s.substring(0, s.length - 4) : s;

ThreadRef? _build({
  required String board,
  required String key,
  String? resSpec,
}) {
  if (!_boardRe.hasMatch(board) || !_keyRe.hasMatch(key)) return null;
  return ThreadRef(board: board, threadKey: key, resSpec: resSpec);
}
