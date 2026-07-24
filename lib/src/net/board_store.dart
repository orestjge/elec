import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'board.dart';
import 'http_fetcher.dart';

/// 板追加時のエラー。利用者向けのメッセージを持つ。
class BoardAddException implements Exception {
  const BoardAddException(this.message);
  final String message;
  @override
  String toString() => 'BoardAddException($message)';
}

/// 追加した板の一覧と現在選択中の板を保持する。
///
/// 「URL から板を追加」の中核。エッヂ（liveedge）を初期シードに持ち、以後は
/// 貼られた URL の板を増やせる。[ChangeNotifier] で一覧・ドロワー・スレ一覧に
/// 切替を通知する。永続化は [BoardStorage]。
class BoardStore extends ChangeNotifier {
  BoardStore(this._storage);

  static final BoardStore shared = BoardStore(FileBoardStorage());

  final BoardStorage _storage;

  List<Board> _boards = const [Board.eddibb];
  String _currentId = Board.eddibb.id;

  List<Board> get boards => List.unmodifiable(_boards);

  Board get current => _boards.firstWhere(
    (b) => b.id == _currentId,
    orElse: () => _boards.first,
  );

  /// 保存済みの板一覧を読み込む。起動時に一度呼ぶ。何も無ければエッヂ 1 件。
  Future<void> load() async {
    final snapshot = await _storage.load();
    if (snapshot.boards.isEmpty) {
      _boards = const [Board.eddibb];
      _currentId = Board.eddibb.id;
    } else {
      _boards = snapshot.boards;
      _currentId = snapshot.boards.any((b) => b.id == snapshot.currentId)
          ? snapshot.currentId
          : snapshot.boards.first.id;
    }
  }

  /// 現在の板を切り替える。存在しない ID は無視。
  Future<void> select(String id) async {
    if (id == _currentId) return;
    if (!_boards.any((b) => b.id == id)) return;
    _currentId = id;
    await _save();
    notifyListeners();
  }

  /// 板を削除する。エッヂ（既定）は残す。現在板を消したら先頭へ移る。
  Future<void> remove(String id) async {
    if (id == Board.eddibb.id) return;
    final next = _boards.where((b) => b.id != id).toList();
    if (next.isEmpty) return;
    _boards = next;
    if (_currentId == id) _currentId = _boards.first.id;
    await _save();
    notifyListeners();
  }

  /// 貼られた URL から板を追加し、その板を選択する。追加済みなら選択だけする。
  ///
  /// URL 解析 → SETTING.TXT でメタ解決（ホスト正規化・表示名・種別）まで通す。
  /// 失敗すると [BoardAddException] を投げる。
  Future<Board> addFromUrl(String input, {HttpFetcher? fetcher}) async {
    final ref = parseBoardUrl(Uri.tryParse(input.trim()) ?? Uri());
    if (ref == null) {
      throw const BoardAddException('板の URL として認識できませんでした');
    }
    final ownsFetcher = fetcher == null;
    final f = fetcher ?? HttpClientFetcher();
    try {
      final board = await _resolveBoard(ref, f);
      final existing = _boards.indexWhere((b) => b.id == board.id);
      if (existing >= 0) {
        // 既にある板。メタを最新化しつつ選択する。
        _boards[existing] = board;
      } else {
        _boards = [..._boards, board];
      }
      _currentId = board.id;
      await _save();
      notifyListeners();
      return board;
    } finally {
      if (ownsFetcher && f is HttpClientFetcher) f.close();
    }
  }

  /// 板の実在確認とメタ解決。
  ///
  /// 貼られたホストで subject.txt を辿り、**本物のスレ一覧が返るか**を中身で判定
  /// する（5ch の itest 等インターフェースホストは 200 だが HTML を返すため、
  /// content で弾かないと空の板が登録されてしまう）。貼られたホストで取れない
  /// 5ch 板は BBSMENU で実サーバを解決してから再取得する。
  Future<Board> _resolveBoard(BoardRef ref, HttpFetcher f) async {
    // 1) まず貼られたホストで試す（`mi.5ch.net/news4vip/` のように既に実サーバ
    //    ならこれで済む）。
    var host = ref.host;
    String? boardName;
    var resolved = await _fetchSubject(f, host, ref.boardKey);

    // 2) 本物のスレ一覧でなく、5ch のホストなら BBSMENU で実サーバを解決して再取得。
    if (resolved == null && _isFivechHost(ref.host)) {
      final entry = await _resolveViaBbsmenu(ref.boardKey, f);
      if (entry != null) {
        boardName = entry.name;
        resolved = await _fetchSubject(f, entry.host, ref.boardKey);
      }
    }

    if (resolved == null) {
      throw const BoardAddException(
        'この URL から板を読めませんでした。掲示板（板）のスレ一覧ページの URL を貼ってください',
      );
    }
    host = resolved; // 正規化後（.net→.io）の実ホスト。

    // 3) SETTING.TXT はベストエフォート。取れれば表示名・種別の手掛かりに使う。
    BoardSetting? setting;
    try {
      final settingUri = Uri.https(host, '/${ref.boardKey}/SETTING.TXT');
      final (_, settingResp) = await _getFollowing(f, settingUri);
      if (settingResp.statusCode == 200) {
        setting = parseSettingTxt(settingResp.bodyBytes);
      }
    } catch (_) {
      // 取れなくても板は追加できる。
    }

    final kind = host == Board.eddibbHost ? BoardKind.eddist : BoardKind.fivech;
    final settingTitle = setting?.title?.trim();
    return Board(
      host: host,
      boardKey: ref.boardKey,
      title: (settingTitle != null && settingTitle.isNotEmpty)
          ? settingTitle
          : (boardName?.trim().isNotEmpty == true
                ? boardName!.trim()
                : ref.boardKey),
      defaultName: setting?.defaultName,
      kind: kind,
      messageMax: setting?.messageMaxCount,
      subjectMax: setting?.subjectMaxCount,
    );
  }

  /// [host] の subject.txt を辿って**本物のスレ一覧**が返るか確かめる。返れば
  /// 正規化後（リダイレクト追従後）のホストを返す。ダメなら null。
  Future<String?> _fetchSubject(
    HttpFetcher f,
    String host,
    String boardKey,
  ) async {
    try {
      final uri = Uri.https(host, '/$boardKey/subject.txt');
      final (finalUri, resp) = await _getFollowing(f, uri);
      if (resp.statusCode == 200 && _looksLikeSubject(resp.bodyBytes)) {
        return finalUri.host;
      }
    } catch (_) {
      // 到達不可などは null 扱い。
    }
    return null;
  }

  /// スレ一覧（subject.txt）らしいバイト列か。`{key}.dat<>タイトル (n)` 形式の
  /// 先頭数百バイトに `.dat<>` が含まれるかで判定する。HTML のインターフェース
  /// ページ（itest 等）を弾くのが狙い。`.dat<>` は ASCII なので SJIS のまま
  /// latin1 で覗いても壊れない。
  static bool _looksLikeSubject(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final n = bytes.length < 512 ? bytes.length : 512;
    final head = String.fromCharCodes(bytes.sublist(0, n));
    return head.contains('.dat<>');
  }

  static bool _isFivechHost(String host) =>
      host.endsWith('.5ch.net') || host.endsWith('.5ch.io');

  /// BBSMENU（`menu.5ch.net/bbsmenu.json`）で板キー → 実サーバ・板名を引く。
  /// 5ch はインターフェースホスト（itest 等）から実サーバ名が分からないため、
  /// ここで解決する。見つからなければ null。
  Future<({String host, String name})?> _resolveViaBbsmenu(
    String boardKey,
    HttpFetcher f,
  ) async {
    try {
      final (_, resp) = await _getFollowing(
        f,
        Uri.https('menu.5ch.net', '/bbsmenu.json'),
      );
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      final menuList = (json is Map) ? json['menu_list'] : null;
      if (menuList is! List) return null;
      for (final category in menuList) {
        final content = (category is Map) ? category['category_content'] : null;
        if (content is! List) continue;
        for (final entry in content) {
          if (entry is! Map) continue;
          if (entry['directory_name'] != boardKey) continue;
          final url = entry['url'];
          if (url is! String) continue;
          final host = Uri.tryParse(url)?.host;
          if (host == null || host.isEmpty) continue;
          final name = entry['board_name'];
          return (host: host, name: name is String ? name : boardKey);
        }
      }
    } catch (_) {
      // BBSMENU が取れない・壊れているときは解決なし。
    }
    return null;
  }

  /// 30x を辿って最終応答と最終 URL を返す（最大 5 ホップ）。
  Future<(Uri, FetchResponse)> _getFollowing(HttpFetcher f, Uri url) async {
    var target = url;
    var resp = await f.get(target);
    for (var hop = 0; _isRedirect(resp.statusCode) && hop < 5; hop++) {
      final location = resp.header('location');
      if (location == null || location.isEmpty) break;
      target = target.resolve(location);
      resp = await f.get(target);
    }
    return (target, resp);
  }

  static const _redirectStatuses = {301, 302, 303, 307, 308};
  static bool _isRedirect(int s) => _redirectStatuses.contains(s);

  Future<void> _save() =>
      _storage.save(BoardSnapshot(boards: _boards, currentId: _currentId));
}

/// 板一覧の保存内容。
class BoardSnapshot {
  const BoardSnapshot({this.boards = const [], this.currentId = ''});
  final List<Board> boards;
  final String currentId;
}

/// 板一覧の保存先の抽象。
abstract interface class BoardStorage {
  Future<BoardSnapshot> load();
  Future<void> save(BoardSnapshot snapshot);
}

/// アプリのサポートディレクトリに JSON で保存する実装。
class FileBoardStorage implements BoardStorage {
  FileBoardStorage({Directory? directory}) : _override = directory;
  final Directory? _override;
  static const _fileName = 'elec_boards.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<BoardSnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const BoardSnapshot();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return const BoardSnapshot();
      final boardsJson = json['boards'];
      final boards = boardsJson is List
          ? boardsJson
                .whereType<Map<String, dynamic>>()
                .map(Board.fromJson)
                .toList(growable: false)
          : const <Board>[];
      return BoardSnapshot(
        boards: boards,
        currentId: json['currentId'] as String? ?? '',
      );
    } catch (_) {
      return const BoardSnapshot();
    }
  }

  @override
  Future<void> save(BoardSnapshot snapshot) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({
        'boards': snapshot.boards.map((b) => b.toJson()).toList(),
        'currentId': snapshot.currentId,
      }),
    );
  }
}

/// メモリ保持のみ（テスト用）。
class MemoryBoardStorage implements BoardStorage {
  MemoryBoardStorage([BoardSnapshot? initial])
    : _snapshot = initial ?? const BoardSnapshot();
  BoardSnapshot _snapshot;

  @override
  Future<BoardSnapshot> load() async => _snapshot;

  @override
  Future<void> save(BoardSnapshot snapshot) async => _snapshot = snapshot;
}
