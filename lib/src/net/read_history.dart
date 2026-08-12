import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:path_provider/path_provider.dart';

import 'board.dart';

/// 既読履歴とお気に入りの保存先の抽象。
abstract interface class ReadHistoryStorage {
  Future<ReadHistorySnapshot> load();
  Future<void> save(ReadHistorySnapshot snapshot);
}

class ReadHistorySnapshot {
  const ReadHistorySnapshot({
    this.seen = const {},
    this.seenAt = const {},
    this.positions = const {},
    this.listed = const {},
    this.favorites = const {},
    this.threads = const {},
    this.ownThreads = const {},
    this.ownPosts = const {},
    this.lastViewedThreadKey,
  });

  final Map<String, int> seen;

  /// 一覧で目に入ったことがあるスレのキー。開いたかどうかとは別で、「前に一覧で
  /// 見かけた」＝新しく立ったスレではない、を表す。
  final Set<String> listed;

  /// スレを最後に開いた時刻（エポックミリ秒）。履歴の「最後に見た順」に使う。
  final Map<String, int> seenAt;

  /// 最後に画面のいちばん上に見えていたレス番号。開き直したときの着地に使う。
  /// **[seen] とは別物**——あちらは「どこまで読んだか」で、下がらない数字。
  final Map<String, int> positions;
  final Set<String> favorites;
  final Map<String, StoredThread> threads;
  final Set<String> ownThreads;
  final Map<String, Set<int>> ownPosts;
  final String? lastViewedThreadKey;
}

class StoredThread {
  const StoredThread({
    required this.key,
    required this.title,
    required this.resCount,
    this.capName,
  });

  final String key;
  final String title;
  final int resCount;
  final String? capName;

  ThreadSummary toSummary() => ThreadSummary(
    key: key,
    title: title,
    resCount: resCount,
    capName: capName,
  );

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'resCount': resCount,
    'capName': capName,
  };

  static StoredThread? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final key = value['key'];
    final title = value['title'];
    final resCount = value['resCount'];
    if (key is! String || title is! String || resCount is! num) return null;
    return StoredThread(
      key: key,
      title: title,
      resCount: resCount.toInt(),
      capName: value['capName'] is String ? value['capName'] as String : null,
    );
  }
}

class FileReadHistoryStorage implements ReadHistoryStorage {
  FileReadHistoryStorage({Directory? directory, String? fileName})
    : _override = directory,
      _fileName = fileName ?? _defaultFileName;
  final Directory? _override;

  /// 既定板（エッヂ）のファイル名。移行不要でこのまま使い続ける。
  static const _defaultFileName = 'elec_read_history.json';
  final String _fileName;

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<ReadHistorySnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const ReadHistorySnapshot();
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final seenJson = json['seen'];
      if (seenJson is Map<String, dynamic>) {
        final seenAtJson = json['seenAt'];
        final positionsJson = json['positions'];
        final listedJson = json['listed'];
        final favoritesJson = json['favorites'];
        final threadsJson = json['threads'];
        final ownThreadsJson = json['ownThreads'];
        final ownPostsJson = json['ownPosts'];
        return ReadHistorySnapshot(
          seen: seenJson.map((k, v) => MapEntry(k, (v as num).toInt())),
          seenAt: seenAtJson is Map<String, dynamic>
              ? seenAtJson.map((k, v) => MapEntry(k, (v as num).toInt()))
              : const {},
          positions: positionsJson is Map<String, dynamic>
              ? positionsJson.map((k, v) => MapEntry(k, (v as num).toInt()))
              : const {},
          listed: listedJson is List
              ? listedJson.whereType<String>().toSet()
              : const {},
          favorites: favoritesJson is List
              ? favoritesJson.whereType<String>().toSet()
              : const {},
          threads: threadsJson is Map<String, dynamic>
              ? _decodeThreads(threadsJson)
              : const {},
          ownThreads: ownThreadsJson is List
              ? ownThreadsJson.whereType<String>().toSet()
              : const {},
          ownPosts: ownPostsJson is Map<String, dynamic>
              ? _decodeOwnPosts(ownPostsJson)
              : const {},
          lastViewedThreadKey: json['lastViewedThreadKey'] is String
              ? json['lastViewedThreadKey'] as String
              : null,
        );
      }
      // 旧形式（スレッドキー → 最後に見たレス数）もそのまま読めるようにする。
      return ReadHistorySnapshot(
        seen: json.map((k, v) => MapEntry(k, (v as num).toInt())),
      );
    } catch (_) {
      return const ReadHistorySnapshot();
    }
  }

  @override
  Future<void> save(ReadHistorySnapshot snapshot) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({
        'seen': snapshot.seen,
        'seenAt': snapshot.seenAt,
        'positions': snapshot.positions,
        'listed': snapshot.listed.toList()..sort(),
        'favorites': snapshot.favorites.toList()..sort(),
        'threads': snapshot.threads.map((k, v) => MapEntry(k, v.toJson())),
        'ownThreads': snapshot.ownThreads.toList()..sort(),
        'ownPosts': snapshot.ownPosts.map(
          (k, v) => MapEntry(k, v.toList()..sort()),
        ),
        'lastViewedThreadKey': snapshot.lastViewedThreadKey,
      }),
    );
  }

  Map<String, StoredThread> _decodeThreads(Map<String, dynamic> json) {
    final result = <String, StoredThread>{};
    for (final entry in json.entries) {
      final thread = StoredThread.fromJson(entry.value);
      if (thread != null) result[entry.key] = thread;
    }
    return result;
  }

  Map<String, Set<int>> _decodeOwnPosts(Map<String, dynamic> json) {
    final result = <String, Set<int>>{};
    for (final entry in json.entries) {
      final posts = entry.value;
      if (posts is List) {
        result[entry.key] = posts
            .whereType<num>()
            .map((n) => n.toInt())
            .toSet();
      }
    }
    return result;
  }
}

class MemoryReadHistoryStorage implements ReadHistoryStorage {
  Map<String, int> _seen;
  Map<String, int> _seenAt;
  Map<String, int> _positions = {};
  Set<String> _listed = {};
  Set<String> _favorites;
  Map<String, StoredThread> _threads;
  Set<String> _ownThreads;
  Map<String, Set<int>> _ownPosts;
  String? _lastViewedThreadKey;
  MemoryReadHistoryStorage([
    Map<String, int>? seen,
    Set<String>? favorites,
    Map<String, StoredThread>? threads,
    Set<String>? ownThreads,
    Map<String, Set<int>>? ownPosts,
    String? lastViewedThreadKey,
    Map<String, int>? seenAt,
  ]) : _seen = seen ?? {},
       _seenAt = seenAt ?? {},
       _favorites = favorites ?? {},
       _threads = threads ?? {},
       _ownThreads = ownThreads ?? {},
       _ownPosts = ownPosts ?? {},
       _lastViewedThreadKey = lastViewedThreadKey;

  @override
  Future<ReadHistorySnapshot> load() async => ReadHistorySnapshot(
    seen: Map.of(_seen),
    seenAt: Map.of(_seenAt),
    positions: Map.of(_positions),
    listed: Set.of(_listed),
    favorites: Set.of(_favorites),
    threads: Map.of(_threads),
    ownThreads: Set.of(_ownThreads),
    ownPosts: _ownPosts.map((k, v) => MapEntry(k, Set.of(v))),
    lastViewedThreadKey: _lastViewedThreadKey,
  );

  @override
  Future<void> save(ReadHistorySnapshot snapshot) async {
    _seen = Map.of(snapshot.seen);
    _seenAt = Map.of(snapshot.seenAt);
    _positions = Map.of(snapshot.positions);
    _listed = Set.of(snapshot.listed);
    _favorites = Set.of(snapshot.favorites);
    _threads = Map.of(snapshot.threads);
    _ownThreads = Set.of(snapshot.ownThreads);
    _ownPosts = snapshot.ownPosts.map((k, v) => MapEntry(k, Set.of(v)));
    _lastViewedThreadKey = snapshot.lastViewedThreadKey;
  }
}

/// スレッドの既読状態とお気に入り状態。
///
/// スレ一覧の表示切り替え・並べ替え・新着バッジに使う。
class ReadHistory {
  ReadHistory(this._storage, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 既定板（エッヂ）の共有インスタンス。`main` で [load] 済み。
  static final ReadHistory shared = ReadHistory(FileReadHistoryStorage());

  /// エッヂ以外の板の履歴インスタンス（board id → 履歴）。
  static final Map<String, ReadHistory> _byBoard = {};

  /// 板ごとの既読履歴を読み込み済みで返す。
  ///
  /// スレキー（UNIX 秒）は板をまたぐと衝突し得るので、板ごとにファイルを分ける。
  /// **既定板（エッヂ）は共有インスタンス＝既存ファイルのまま**で移行不要。他板は
  /// `elec_read_history_{host}_{boardKey}.json` に保存する。
  /// 既に読み込み済みの板履歴を返す（無ければ null）。同期的に使える経路
  /// （既定板・切替済みの板）で FutureBuilder を挟まず即描画するための入口。
  static ReadHistory? cachedFor(Board board) {
    if (board.id == Board.eddibb.id) return shared;
    return _byBoard[board.id];
  }

  static Future<ReadHistory> forBoard(Board board) async {
    if (board.id == Board.eddibb.id) return shared;
    final cached = _byBoard[board.id];
    if (cached != null) return cached;
    final safe = board.id.replaceAll(RegExp(r'[^0-9a-zA-Z_]+'), '_');
    final history = ReadHistory(
      FileReadHistoryStorage(fileName: 'elec_read_history_$safe.json'),
    );
    _byBoard[board.id] = history;
    await history.load();
    return history;
  }

  final ReadHistoryStorage _storage;
  final DateTime Function() _now;
  Map<String, int> _seen = {};
  Map<String, int> _seenAt = {};
  Map<String, int> _positions = {};
  Set<String> _listed = {};
  Set<String> _favorites = {};
  Map<String, StoredThread> _threads = {};
  Set<String> _ownThreads = {};
  Map<String, Set<int>> _ownPosts = {};
  String? _lastViewedThreadKey;
  Future<void> _pendingSave = Future.value();

  /// まとめ書きの間隔。[_saveSoon] はこれより細かくは書かない。
  static const _saveInterval = Duration(milliseconds: 500);

  /// 前回書き出してからの経過。間隔を測るだけのものなので、記録する時刻に使う
  /// 時計（[_now]。テストで差し替わる）とは別に持つ。
  final _sinceWrite = Stopwatch();

  /// 見送った書き残しがあるか（[_saveSoon] が間隔待ちで送らなかったぶん）。
  bool _unsaved = false;

  Future<void> load() async {
    final snapshot = await _storage.load();
    _seen = Map.of(snapshot.seen);
    _seenAt = Map.of(snapshot.seenAt);
    _positions = Map.of(snapshot.positions);
    _listed = Set.of(snapshot.listed);
    _favorites = Set.of(snapshot.favorites);
    _threads = Map.of(snapshot.threads);
    _ownThreads = Set.of(snapshot.ownThreads);
    _ownPosts = snapshot.ownPosts.map((k, v) => MapEntry(k, Set.of(v)));
    _lastViewedThreadKey = snapshot.lastViewedThreadKey;
  }

  bool isRead(String threadKey) => _seen.containsKey(threadKey);

  /// 一覧で目に入ったことがあるか。開いたスレは当然見ている。
  bool isListed(String threadKey) =>
      _listed.contains(threadKey) || _seen.containsKey(threadKey);

  /// いま一覧に出ているキーの控え。次に開いたときに「新しく立ったスレ」だけを
  /// 見分けるために使う（[isListed]）。
  Set<String> get listedThreads => Set.unmodifiable(_listed);

  /// 一覧で目に入ったスレとして覚える。スクロールのたびに呼ばれるので、増えた
  /// ものが無ければ何もしない。
  Future<void> markListed(Iterable<String> threadKeys) async {
    var changed = false;
    for (final key in threadKeys) {
      if (_listed.add(key)) changed = true;
    }
    if (!changed) return;
    _pruneListed();
    await _save();
  }

  /// 覚えるのは新しいほうから [_maxListed] 件まで。スレキーは立った時刻（UNIX
  /// 秒）なので、大きいほうが新しい。落ちて久しいスレは覚えていても意味が無い。
  static const _maxListed = 3000;

  void _pruneListed() {
    if (_listed.length <= _maxListed) return;
    final keys = _listed.toList()
      ..sort((a, b) => _keyOrder(b).compareTo(_keyOrder(a)));
    _listed = keys.take(_maxListed).toSet();
  }

  static int _keyOrder(String key) => int.tryParse(key) ?? 0;

  /// 前回見たレス数。未読なら null。
  int? lastSeen(String threadKey) => _seen[threadKey];

  /// スレを最後に開いた時刻（エポックミリ秒）。開いた記録が無ければ null。
  int? lastSeenAt(String threadKey) => _seenAt[threadKey];

  /// 最後に画面のいちばん上に見えていたレス番号。記録が無ければ null。
  int? lastPosition(String threadKey) => _positions[threadKey];

  /// 読んでいた場所を覚える。
  ///
  /// **[markRead] と違って下がる。** あちらは「どこまで読んだか」（一覧の未読
  /// 件数のもと）なので進むだけだが、こちらは「最後にどこを見ていたか」なので、
  /// 読み返して上へ戻ったならその場所が正しい。
  Future<void> markPosition(String threadKey, int resNumber) async {
    if (resNumber <= 0 || _positions[threadKey] == resNumber) return;
    _positions[threadKey] = resNumber;
    await _save();
  }

  Iterable<StoredThread> get storedThreads => _threads.values;

  StoredThread? get lastViewedThread {
    final key = _lastViewedThreadKey;
    if (key == null) return null;
    return _threads[key];
  }

  Future<void> rememberThread(ThreadSummary thread) async {
    if (_rememberThreadInMemory(thread)) await _save();
  }

  bool _rememberThreadInMemory(ThreadSummary thread) {
    final prev = _threads[thread.key];
    if (prev != null &&
        prev.title == thread.title &&
        prev.resCount >= thread.resCount &&
        prev.capName == thread.capName) {
      return false;
    }
    _threads[thread.key] = StoredThread(
      key: thread.key,
      title: thread.title,
      resCount: thread.resCount,
      capName: thread.capName,
    );
    return true;
  }

  Future<void> markLastViewedThread(ThreadSummary thread) async {
    _rememberThreadInMemory(thread);
    _lastViewedThreadKey = thread.key;
    _seenAt[thread.key] = _now().millisecondsSinceEpoch;
    await _save();
  }

  /// スレを開いた事実をすぐ保存する。本文取得や画面離脱を待たず、履歴一覧と
  /// 「直近に見たスレ」に反映する。既読位置はまだ見えていないので 0 にする。
  Future<void> markOpenedThread(ThreadSummary thread) async {
    _rememberThreadInMemory(thread);
    _lastViewedThreadKey = thread.key;
    _seen.putIfAbsent(thread.key, () => 0);
    _seenAt[thread.key] = _now().millisecondsSinceEpoch;
    await _save();
  }

  /// [resCount] までを既読にする。前回より小さい値では下げない。
  ///
  /// **スレを送っている間ほぼ毎フレーム呼ばれる**（見えている最大レス番号が進む
  /// たび）。覚えるのはその場、書き出しは [_saveSoon] に任せる。
  Future<void> markRead(String threadKey, int resCount) async {
    final prev = _seen[threadKey];
    if (prev != null && prev >= resCount) return;
    _seen[threadKey] = resCount;
    final thread = _threads[threadKey];
    if (thread != null && thread.resCount < resCount) {
      _threads[threadKey] = StoredThread(
        key: thread.key,
        title: thread.title,
        resCount: resCount,
        capName: thread.capName,
      );
    }
    await _saveSoon();
  }

  bool isFavorite(String threadKey) => _favorites.contains(threadKey);

  bool isOwnThread(String threadKey) => _ownThreads.contains(threadKey);

  bool isOwnPost(String threadKey, int number) =>
      _ownPosts[threadKey]?.contains(number) ?? false;

  /// このスレで自分のレスとして記録した件数。0 なら「自分宛」の判定（本文の
  /// `>>N` 解析）自体を省ける。
  int ownPostCount(String threadKey) => _ownPosts[threadKey]?.length ?? 0;

  Future<void> markOwnThread(String threadKey) async {
    final changed = _ownThreads.add(threadKey);
    final posts = _ownPosts.putIfAbsent(threadKey, () => <int>{});
    final postChanged = posts.add(1);
    if (changed || postChanged) await _save();
  }

  Future<void> markOwnPost(String threadKey, int number) async {
    final posts = _ownPosts.putIfAbsent(threadKey, () => <int>{});
    if (posts.add(number)) await _save();
  }

  Future<void> setFavorite(String threadKey, bool favorite) async {
    final changed = favorite
        ? _favorites.add(threadKey)
        : _favorites.remove(threadKey);
    if (changed) await _save();
  }

  Future<void> toggleFavorite(String threadKey) =>
      setFavorite(threadKey, !isFavorite(threadKey));

  /// スレを既読履歴から消す。既読状態を落として未読に戻し、保存済みスレ情報も
  /// 除く。ただしお気に入りの場合は一覧に残すため保存情報は消さない。
  Future<void> forgetThread(String threadKey) async {
    var changed = _seen.remove(threadKey) != null;
    if (_seenAt.remove(threadKey) != null) changed = true;
    if (_positions.remove(threadKey) != null) changed = true;
    if (!_favorites.contains(threadKey)) {
      if (_threads.remove(threadKey) != null) changed = true;
    }
    if (_lastViewedThreadKey == threadKey) {
      _lastViewedThreadKey = null;
      changed = true;
    }
    if (changed) await _save();
  }

  /// 間隔を空けて保存する。**何度も続けて動く記録用**（[markRead]）。
  ///
  /// 1 回ぶんの支度——控えの複製と JSON への変換——はメインアイソレートで走り、
  /// 覚えている量（「一覧で見た」だけで最大 [_maxListed] 件）に比例して重くなる。
  /// スクロールのたびに書いていると、そのぶんがまるごとコマ落ちになる。
  ///
  /// 間隔が明けていればその場で書く。明けていなければ**印を付けるだけ**にして、
  /// 時計は仕掛けない。仕掛けると、書くものが無くても起きて回るうえ、消し忘れれば
  /// 画面が閉じた後まで残る。見送ったぶんは次の [_saveSoon]、他の記録の保存
  /// （[_save] はいつも全部を書き出す）、画面を離れるときの [flush] が拾う。
  Future<void> _saveSoon() {
    if (_sinceWrite.isRunning && _sinceWrite.elapsed < _saveInterval) {
      _unsaved = true;
      return _pendingSave;
    }
    return _save();
  }

  /// 見送った書き残しをいま書き出す。書き残しが無ければ、走っている書き込みの
  /// 終わりを返すだけ。
  ///
  /// **画面を離れるとき・裏に回るときに呼ぶ。** [_saveSoon] は時計を持たないので、
  /// 最後に見送ったぶんを書き出す機会はここだけになる。
  Future<void> flush() => _unsaved ? _save() : _pendingSave;

  Future<void> _save() async {
    _unsaved = false;
    _sinceWrite
      ..reset()
      ..start();
    final snapshot = ReadHistorySnapshot(
      seen: Map.of(_seen),
      seenAt: Map.of(_seenAt),
      positions: Map.of(_positions),
      listed: Set.of(_listed),
      favorites: Set.of(_favorites),
      threads: Map.of(_threads),
      ownThreads: Set.of(_ownThreads),
      ownPosts: _ownPosts.map((k, v) => MapEntry(k, Set.of(v))),
      lastViewedThreadKey: _lastViewedThreadKey,
    );
    _pendingSave = _pendingSave.then((_) => _storage.save(snapshot));
    await _pendingSave;
  }
}
