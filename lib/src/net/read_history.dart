import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:path_provider/path_provider.dart';

/// 既読履歴とお気に入りの保存先の抽象。
abstract interface class ReadHistoryStorage {
  Future<ReadHistorySnapshot> load();
  Future<void> save(ReadHistorySnapshot snapshot);
}

class ReadHistorySnapshot {
  const ReadHistorySnapshot({
    this.seen = const {},
    this.favorites = const {},
    this.threads = const {},
    this.ownThreads = const {},
    this.ownPosts = const {},
    this.lastViewedThreadKey,
  });

  final Map<String, int> seen;
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
  FileReadHistoryStorage({Directory? directory}) : _override = directory;
  final Directory? _override;
  static const _fileName = 'elec_read_history.json';

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
        final favoritesJson = json['favorites'];
        final threadsJson = json['threads'];
        final ownThreadsJson = json['ownThreads'];
        final ownPostsJson = json['ownPosts'];
        return ReadHistorySnapshot(
          seen: seenJson.map((k, v) => MapEntry(k, (v as num).toInt())),
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
  ]) : _seen = seen ?? {},
       _favorites = favorites ?? {},
       _threads = threads ?? {},
       _ownThreads = ownThreads ?? {},
       _ownPosts = ownPosts ?? {},
       _lastViewedThreadKey = lastViewedThreadKey;

  @override
  Future<ReadHistorySnapshot> load() async => ReadHistorySnapshot(
    seen: Map.of(_seen),
    favorites: Set.of(_favorites),
    threads: Map.of(_threads),
    ownThreads: Set.of(_ownThreads),
    ownPosts: _ownPosts.map((k, v) => MapEntry(k, Set.of(v))),
    lastViewedThreadKey: _lastViewedThreadKey,
  );

  @override
  Future<void> save(ReadHistorySnapshot snapshot) async {
    _seen = Map.of(snapshot.seen);
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
  ReadHistory(this._storage);

  static final ReadHistory shared = ReadHistory(FileReadHistoryStorage());

  final ReadHistoryStorage _storage;
  Map<String, int> _seen = {};
  Set<String> _favorites = {};
  Map<String, StoredThread> _threads = {};
  Set<String> _ownThreads = {};
  Map<String, Set<int>> _ownPosts = {};
  String? _lastViewedThreadKey;
  Future<void> _pendingSave = Future.value();

  Future<void> load() async {
    final snapshot = await _storage.load();
    _seen = Map.of(snapshot.seen);
    _favorites = Set.of(snapshot.favorites);
    _threads = Map.of(snapshot.threads);
    _ownThreads = Set.of(snapshot.ownThreads);
    _ownPosts = snapshot.ownPosts.map((k, v) => MapEntry(k, Set.of(v)));
    _lastViewedThreadKey = snapshot.lastViewedThreadKey;
  }

  bool isRead(String threadKey) => _seen.containsKey(threadKey);

  /// 前回見たレス数。未読なら null。
  int? lastSeen(String threadKey) => _seen[threadKey];

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
    final changedThread = _rememberThreadInMemory(thread);
    final changedLastViewed = _lastViewedThreadKey != thread.key;
    if (changedLastViewed) _lastViewedThreadKey = thread.key;
    if (changedThread || changedLastViewed) await _save();
  }

  /// スレを開いた事実をすぐ保存する。本文取得や画面離脱を待たず、履歴一覧と
  /// 「直近に見たスレ」に反映する。既読位置はまだ見えていないので 0 にする。
  Future<void> markOpenedThread(ThreadSummary thread) async {
    var changed = _rememberThreadInMemory(thread);
    if (_lastViewedThreadKey != thread.key) {
      _lastViewedThreadKey = thread.key;
      changed = true;
    }
    if (!_seen.containsKey(thread.key)) {
      _seen[thread.key] = 0;
      changed = true;
    }
    if (!changed) return;
    await _save();
  }

  /// [resCount] までを既読にする。前回より小さい値では下げない。
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
    await _save();
  }

  bool isFavorite(String threadKey) => _favorites.contains(threadKey);

  bool isOwnThread(String threadKey) => _ownThreads.contains(threadKey);

  bool isOwnPost(String threadKey, int number) =>
      _ownPosts[threadKey]?.contains(number) ?? false;

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
    if (!_favorites.contains(threadKey)) {
      if (_threads.remove(threadKey) != null) changed = true;
    }
    if (_lastViewedThreadKey == threadKey) {
      _lastViewedThreadKey = null;
      changed = true;
    }
    if (changed) await _save();
  }

  Future<void> _save() async {
    final snapshot = ReadHistorySnapshot(
      seen: Map.of(_seen),
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
