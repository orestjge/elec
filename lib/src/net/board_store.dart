import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:edge_sjis/edge_sjis.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'board.dart';
import 'board_catalog.dart';
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

  /// [source] から追加候補の板カタログを取得する。
  ///
  /// 掲示板ごとに板リストの置き場所が違う（5ch は menu.5ch.net の JSON、eddist は
  /// `/api/boards`、2ch 系サーバは `/bbsmenu.html`）ので、取得先の違いはここに
  /// 閉じ込め、UI にはカテゴリ付きの [BoardCatalog] だけを見せる。
  Future<BoardCatalog> fetchCatalog(
    BoardCatalogSource source, {
    HttpFetcher? fetcher,
  }) async {
    final ownsFetcher = fetcher == null;
    final f = fetcher ?? HttpClientFetcher();
    try {
      final catalog = switch (source.kind) {
        BoardCatalogSourceKind.fivechMenu => await _fetchFivechCatalog(f),
        BoardCatalogSourceKind.host => await _fetchHostCatalog(source, f),
      };
      if (catalog.categories.isEmpty) {
        throw BoardAddException('${source.label} の板リストを読み取れませんでした');
      }
      return catalog;
    } catch (e) {
      if (e is BoardAddException) rethrow;
      throw BoardAddException('${source.label} の板リストを取得できませんでした');
    } finally {
      if (ownsFetcher && f is HttpClientFetcher) f.close();
    }
  }

  Future<BoardCatalog> _fetchFivechCatalog(HttpFetcher f) async {
    final (_, resp) = await _getFollowing(
      f,
      Uri.https('menu.5ch.net', '/bbsmenu.json'),
    );
    if (resp.statusCode != 200) {
      throw const BoardAddException('5ch の板リストを取得できませんでした');
    }
    return _parseFivechCatalog(resp.bodyBytes);
  }

  /// 単一ホストの板リスト。eddist の `/api/boards`（JSON）を先に試し、無ければ
  /// 2ch 系サーバが置く `/bbsmenu.html` にフォールバックする。同じ eddist でも
  /// 前者しか無いサーバ・後者しか無いサーバの両方が実在するため両対応する。
  Future<BoardCatalog> _fetchHostCatalog(
    BoardCatalogSource source,
    HttpFetcher f,
  ) async {
    try {
      final (_, resp) = await _getFollowing(
        f,
        Uri.https(source.host, '/api/boards'),
      );
      if (resp.statusCode == 200) {
        final catalog = _parseEddistBoards(resp.bodyBytes, source);
        if (catalog.categories.isNotEmpty) return catalog;
      }
    } catch (_) {
      // JSON が無いサーバは HTML の板リストへ。
    }
    final (_, resp) = await _getFollowing(
      f,
      Uri.https(source.host, '/bbsmenu.html'),
    );
    if (resp.statusCode != 200) {
      throw BoardAddException('${source.label} は板リストを配信していません');
    }
    return _parseBbsmenuHtml(resp.bodyBytes, source);
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
    final shitaraba = _isShitarabaHost(host);
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
      final settingUri = shitaraba
          ? Uri.https(host, '/bbs/api/setting.cgi/${ref.boardKey}/')
          : Uri.https(host, '/${ref.boardKey}/SETTING.TXT');
      final (_, settingResp) = await _getFollowing(f, settingUri);
      if (settingResp.statusCode == 200) {
        setting = parseSettingTxt(
          settingResp.bodyBytes,
          encoding: shitaraba ? BbsTextEncoding.eucJp : BbsTextEncoding.sjis,
        );
      }
    } catch (_) {
      // 取れなくても板は追加できる。
    }

    final kind = shitaraba
        ? BoardKind.shitaraba
        : host == Board.eddibbHost
        ? BoardKind.eddist
        : BoardKind.fivech;
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

  /// スレ一覧（subject.txt）らしいバイト列か。5ch 互換の
  /// `{key}.dat<>タイトル (n)` と、したらばの `{key}.cgi,タイトル(n)` を見る。
  /// HTML のインターフェースページ（itest 等）を弾くのが狙い。
  static bool _looksLikeSubject(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final n = bytes.length < 512 ? bytes.length : 512;
    final head = String.fromCharCodes(bytes.sublist(0, n));
    return head.contains('.dat<>') || RegExp(r'\d+\.cgi,').hasMatch(head);
  }

  static bool _isFivechHost(String host) =>
      host.endsWith('.5ch.net') || host.endsWith('.5ch.io');

  static bool _isShitarabaHost(String host) =>
      host == Board.shitarabaHost || host == 'jbbs.livedoor.jp';

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
      for (final entry in _parseFivechCatalog(resp.bodyBytes).entries) {
        if (entry.boardKey == boardKey && entry.host.isNotEmpty) {
          return (host: entry.host, name: entry.name);
        }
      }
    } catch (_) {
      // BBSMENU が取れない・壊れているときは解決なし。
    }
    return null;
  }

  static BoardCatalog _parseFivechCatalog(List<int> bodyBytes) {
    final json = jsonDecode(utf8.decode(bodyBytes));
    final menuList = (json is Map) ? json['menu_list'] : null;
    if (menuList is! List) {
      return const BoardCatalog(sourceName: '5ch', categories: []);
    }
    final categories = <BoardCatalogCategory>[];
    for (final category in menuList) {
      if (category is! Map) continue;
      final categoryName = category['category_name'];
      final content = category['category_content'];
      if (content is! List) continue;
      final entries = <BoardCatalogEntry>[];
      for (final rawEntry in content) {
        if (rawEntry is! Map) continue;
        final boardKey = rawEntry['directory_name'];
        final boardName = rawEntry['board_name'];
        final urlText = rawEntry['url'];
        if (boardKey is! String || boardKey.isEmpty) continue;
        if (boardName is! String || boardName.isEmpty) continue;
        if (urlText is! String) continue;
        final url = Uri.tryParse(urlText);
        if (url == null || !url.hasScheme || url.host.isEmpty) continue;
        entries.add(
          BoardCatalogEntry(name: boardName, boardKey: boardKey, url: url),
        );
      }
      if (entries.isEmpty) continue;
      categories.add(
        BoardCatalogCategory(
          name: categoryName is String && categoryName.isNotEmpty
              ? categoryName
              : 'その他',
          entries: entries,
        ),
      );
    }
    return BoardCatalog(sourceName: '5ch', categories: categories);
  }

  /// eddist の `/api/boards`。`[{name, board_key, default_name}, …]` の配列で、
  /// カテゴリは無いので 1 カテゴリにまとめる。板の URL はホスト＋板キー。
  static BoardCatalog _parseEddistBoards(
    List<int> bodyBytes,
    BoardCatalogSource source,
  ) {
    final json = jsonDecode(utf8.decode(bodyBytes));
    if (json is! List) {
      return BoardCatalog(sourceName: source.label, categories: const []);
    }
    final entries = <BoardCatalogEntry>[];
    for (final raw in json) {
      if (raw is! Map) continue;
      final boardKey = raw['board_key'];
      final name = raw['name'];
      if (boardKey is! String || boardKey.isEmpty) continue;
      entries.add(
        BoardCatalogEntry(
          name: name is String && name.isNotEmpty ? name : boardKey,
          boardKey: boardKey,
          url: Uri.https(source.host, '/$boardKey/'),
        ),
      );
    }
    if (entries.isEmpty) {
      return BoardCatalog(sourceName: source.label, categories: const []);
    }
    return BoardCatalog(
      sourceName: source.label,
      categories: [BoardCatalogCategory(name: source.label, entries: entries)],
    );
  }

  /// 昔ながらの `bbsmenu.html`。`<B>カテゴリ</B>` に続く `<A HREF=…>板名</A>` を
  /// 順に拾う。板 URL かどうかは [parseBoardUrl] に判定させるので、トップページ
  /// へのリンクなどは自然に落ちる。文字コードは Shift_JIS が主流だが UTF-8 の
  /// サーバもあるため、厳格 UTF-8 で読めたときだけ UTF-8 として扱う。
  static BoardCatalog _parseBbsmenuHtml(
    List<int> bodyBytes,
    BoardCatalogSource source,
  ) {
    String text;
    try {
      text = utf8.decode(bodyBytes);
    } catch (_) {
      text = decodeSjis(bodyBytes);
    }
    final categories = <BoardCatalogCategory>[];
    final seen = <String>{};
    var categoryName = source.label;
    var entries = <BoardCatalogEntry>[];

    void flush() {
      if (entries.isEmpty) return;
      categories.add(
        BoardCatalogCategory(name: categoryName, entries: entries),
      );
      entries = <BoardCatalogEntry>[];
    }

    for (final m in _menuTokenPattern.allMatches(text)) {
      final bold = m.group(1);
      if (bold != null) {
        // 次のカテゴリへ。見出しだけで中身が無いブロックは捨てる。
        flush();
        final name = _stripHtml(bold);
        if (name.isNotEmpty) categoryName = name;
        continue;
      }
      // href はクォート有無で捕捉位置が変わる（2:"" / 3:'' / 4:裸）。
      final href = m.group(2) ?? m.group(3) ?? m.group(4);
      final label = _stripHtml(m.group(5) ?? '');
      if (href == null || label.isEmpty) continue;
      final url = Uri.tryParse(href.trim());
      if (url == null) continue;
      final ref = parseBoardUrl(url);
      if (ref == null) continue;
      if (!seen.add('${ref.host}/${ref.boardKey}')) continue;
      entries.add(
        BoardCatalogEntry(name: label, boardKey: ref.boardKey, url: url),
      );
    }
    flush();
    return BoardCatalog(sourceName: source.label, categories: categories);
  }

  /// `<B>見出し</B>` と `<A HREF=…>板名</A>` を出現順に拾うパターン。順序が
  /// 要るので 1 本の正規表現で走査する。href はクォート無しの記法も実在する。
  static final _menuTokenPattern = RegExp(
    r'''<b\b[^>]*>(.*?)</b>|<a\s[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s">]+))[^>]*>(.*?)</a>''',
    caseSensitive: false,
    dotAll: true,
  );

  static String _stripHtml(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .trim();

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
