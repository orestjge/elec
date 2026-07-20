import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
import '../net/ng_store.dart';
import '../net/read_history.dart';
import 'new_thread_screen.dart';
import 'settings_screen.dart';
import 'thread_screen.dart';
import 'thread_tile.dart';

/// スレッド一覧の並べ替え方法。
enum ThreadSort {
  bump('最近レス順', 'レスが新しいスレ順（掲示板の定番）', Icons.sort),
  readPriority('既読優先', '既読スレを上に（新着ありを最優先）', Icons.mark_chat_read_outlined),
  momentum('勢い', '1日あたりのレス数が多い順', Icons.bolt),
  resCount('レス数', 'レスの多い順', Icons.forum_outlined),
  newest('新着', '新しく立った順', Icons.schedule),
  lastSeen('最後に見た順', '最後に開いたスレ順', Icons.history);

  const ThreadSort(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;
}

enum ThreadFilter {
  current('現行', '現在一覧にあるスレを表示', Icons.forum_outlined),
  history('履歴', '開いたことがあるスレ（dat落ちも含む）', Icons.history),
  favorites('お気に入り', 'お気に入りに登録したスレ（dat落ちも含む）', Icons.star_border);

  const ThreadFilter(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;
}

class ThreadListScreen extends StatefulWidget {
  const ThreadListScreen({
    super.key,
    this.fetcher,
    this.endpoints = const EdgeEndpoints(),
    this.pollInterval = const Duration(seconds: 5),
    this.readHistory,
    this.authStore,
  });

  /// 通信の実装。テストでフェイクを差せるよう注入可能。既定は本番実装。
  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;

  /// 既読履歴。既定はアプリ共有インスタンス（テストで差し替え可能）。
  final ReadHistory? readHistory;

  /// 書き込み認証情報。既定はアプリ共有インスタンス（テストで差し替え可能）。
  final AuthStore? authStore;

  /// 自動更新の間隔（フォアグラウンド時）。
  ///
  /// サーバは subject.txt を CDN で 1 秒キャッシュする（`s-maxage=1`）ため、
  /// 1 秒より短くしても同じキャッシュが返るだけで無意味。正常な読み取りに
  /// レート制限は無い（404 の連打のみ制限対象）ので 5 秒は余裕で安全。
  /// `If-Modified-Since` 付きなので変化なしなら 304 で数百バイト。
  final Duration pollInterval;

  @override
  State<ThreadListScreen> createState() => _ThreadListScreenState();
}

class _ThreadListScreenState extends State<ThreadListScreen>
    with WidgetsBindingObserver {
  late final HttpFetcher _fetcher;
  late final bool _ownsFetcher;
  late final SubjectFetcher _subject;
  late final ReadHistory _history;
  final NgStore _ng = NgStore.shared;

  SubjectState? _state; // 初回成功まで null
  Object? _error; // 初回失敗時のみ全画面エラーに使う
  bool _loading = true;
  bool _polling = false; // 背景ポーリング中の控えめなインジケータ用
  ThreadFilter _filter = ThreadFilter.current;

  /// 表示ごとの既定の並び。現行は掲示板の定番＝最近レス順、履歴は最後に見た順。
  static const Map<ThreadFilter, ThreadSort> _defaultSort = {
    ThreadFilter.current: ThreadSort.bump,
    ThreadFilter.history: ThreadSort.lastSeen,
    ThreadFilter.favorites: ThreadSort.lastSeen,
  };

  /// ユーザーが表示ごとに選んだ並び。未選択なら [_defaultSort] に従う。
  final Map<ThreadFilter, ThreadSort> _sortByFilter = {};

  /// 現在の表示に適用する並び。
  ThreadSort get _sort => _sortByFilter[_filter] ?? _defaultSort[_filter]!;
  final _search = TextEditingController();
  bool _searchOpen = false;
  double _horizontalDragDistance = 0;
  double _verticalDragDistance = 0;
  bool _trackingSwipe = false;
  Timer? _swipeStartTimer;
  static const double _swipeDistanceThreshold = 50;
  static const Duration _swipeStartTimeout = Duration(milliseconds: 450);

  /// 表示中の並び順（スレキー列）の固定スナップショット。実況板では最近レス順
  /// が高頻度で入れ替わり一覧を追えないため、自動更新では並べ替えず、レス数・
  /// 新着バッジだけをその場で更新する。並べ替え直しは手動更新・ソート変更・
  /// スレを開いて戻ったときだけ行う。初回成功まで null。
  List<String>? _order;

  Timer? _timer;
  bool _fetching = false; // 多重取得の抑止

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _subject = SubjectFetcher(_fetcher);
    _history = widget.readHistory ?? ReadHistory.shared;
    _ng.addListener(_onNgChanged);
    WidgetsBinding.instance.addObserver(this);
    _initialLoad();
    _startPolling();
  }

  void _onNgChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ng.removeListener(_onNgChanged);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _swipeStartTimer?.cancel();
    _search.dispose();
    final fetcher = _fetcher;
    if (_ownsFetcher && fetcher is HttpClientFetcher) {
      fetcher.close();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 完全に背面（最小化/バックグラウンド）のときだけ止める。デスクトップで
    // 頻発する inactive（フォーカス喪失）では止めない。
    switch (state) {
      case AppLifecycleState.resumed:
        _startPolling();
        _poll(); // 復帰時は即座に一度取りに行く
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _stopPolling();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  void _stopPolling() => _timer?.cancel();

  Future<void> _initialLoad() async {
    try {
      final r = await _subject.fetch(
        widget.endpoints.subjectMetadentTxt,
        metadent: true,
      );
      if (!mounted) return;
      await _rememberThreads(r.state.threads);
      setState(() {
        _state = r.state;
        _loading = false;
        _error = null;
        _reorder();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 定期・復帰時の更新。失敗しても既存の一覧は保持する（黙って握る）。
  Future<void> _poll() async {
    if (_fetching || !mounted) return;
    _fetching = true;
    setState(() => _polling = true);
    try {
      final r = await _subject.fetch(
        widget.endpoints.subjectMetadentTxt,
        prev: _state,
        metadent: true,
      );
      if (!mounted) return;
      if (!r.notModified) {
        await _rememberThreads(r.state.threads);
        // データだけ差し替え、並び順（_order）はあえて触らない。レス数・新着
        // バッジはその場で更新されるが、行が飛び回らないので一覧を追える。
        setState(() {
          _state = r.state;
          _error = null;
        });
      }
    } catch (_) {
      // ポーリングの失敗は無視。次の周期で回復を試みる。
    } finally {
      _fetching = false;
      if (mounted) setState(() => _polling = false);
    }
  }

  /// 引っ張って更新。初回失敗からの復帰にも使う。
  Future<void> _refresh({bool force = false}) async {
    try {
      final r = await _subject.fetch(
        widget.endpoints.subjectMetadentTxt,
        prev: force ? null : _state,
        metadent: true,
      );
      if (!mounted) return;
      if (!r.notModified) await _rememberThreads(r.state.threads);
      setState(() {
        if (!r.notModified) _state = r.state;
        _error = null;
        _loading = false;
        _reorder(); // 手動更新なので並び順を貼り直す
      });
    } catch (e) {
      if (!mounted) return;
      if (_state == null) setState(() => _error = e);
    }
  }

  /// 現在のデータと選択中ソートで並び順を確定し、固定スナップショットを更新する。
  void _reorder() {
    final state = _state;
    if (state != null) {
      _order = _sorted(state.threads).map((t) => t.key).toList();
    }
  }

  /// 表示する並び。固定スナップショット [_order] の順に現在のデータを当て、
  /// 固定順に無い（新しく現れた）スレは末尾へ回す。[_order] 未設定なら都度ソート。
  List<ThreadSummary> _orderedThreads() {
    final threads = _state!.threads;
    final order = _order;
    if (order == null) return _sorted(threads);
    final byKey = {for (final t in threads) t.key: t};
    final result = <ThreadSummary>[];
    final placed = <String>{};
    for (final key in order) {
      final t = byKey[key];
      if (t != null) {
        result.add(t);
        placed.add(key);
      }
    }
    // 固定順に無い新スレは末尾へ。次の手動更新で正規の位置に収まる。
    for (final t in threads) {
      if (!placed.contains(t.key)) result.add(t);
    }
    return result;
  }

  List<ThreadSummary> _filteredThreads(List<ThreadSummary> threads) {
    final filtered = switch (_filter) {
      ThreadFilter.current => threads,
      ThreadFilter.history => _withStoredThreads(
        threads.where((t) => _history.isRead(t.key)).toList(),
        (key) => _history.isRead(key),
      ),
      ThreadFilter.favorites => _withStoredThreads(
        threads.where((t) => _history.isFavorite(t.key)).toList(),
        (key) => _history.isFavorite(key),
      ),
    };
    // スレ主 NG は全表示で効かせる（履歴・お気に入りの保存分は metadent を
    // 持たないので対象外＝そのまま残る）。
    final visible = filtered
        .where((t) => !_ng.isNgCreator(t.metadent))
        .toList();
    final query = _search.text.trim().toLowerCase();
    final matched = query.isEmpty
        ? visible
        : visible.where((t) => t.title.toLowerCase().contains(query)).toList();
    // 最後に見た順は dat 落ち（stored）も混ぜて時刻で並べたいので、固定順
    // スナップショットに頼らずここで一覧全体を並べ直す。
    if (_sort == ThreadSort.lastSeen) matched.sort(_compareLastSeen);
    return matched;
  }

  List<ThreadSummary> _withStoredThreads(
    List<ThreadSummary> current,
    bool Function(String key) include,
  ) {
    final keys = current.map((t) => t.key).toSet();
    final stored =
        _history.storedThreads
            .where((t) => include(t.key) && !keys.contains(t.key))
            .map((t) => t.toSummary())
            .toList()
          ..sort((a, b) => b.keyAsInt.compareTo(a.keyAsInt));
    return [...current, ...stored];
  }

  /// このスレの新着レス数（既読なら「現在 − 前回見た数」、未読なら 0）。
  int _newCount(ThreadSummary t) {
    final seen = _history.lastSeen(t.key);
    if (seen == null) return 0;
    final diff = t.resCount - seen;
    return diff > 0 ? diff : 0;
  }

  String? _statusLabel(ThreadSummary t) {
    if (_isStoppedThread(t)) {
      final current =
          _state?.threads.any((thread) => thread.key == t.key) ?? false;
      if (!current) return t.resCount >= 1000 ? '完走' : 'dat落ち';
      return '完走';
    }
    return null;
  }

  bool _isStoppedThread(ThreadSummary t) {
    final current =
        _state?.threads.any((thread) => thread.key == t.key) ?? false;
    return !current || t.resCount >= 1000;
  }

  List<ThreadSummary> _sorted(List<ThreadSummary> threads) {
    switch (_sort) {
      case ThreadSort.bump:
        // subject.txt は既にサーバの bump 順（最終書き込み順）。そのまま。
        return threads;
      case ThreadSort.readPriority:
        // 既読&新着あり → 既読 → 未読。各群は bump 順（入力順）を保つ。
        final readNew = <ThreadSummary>[];
        final read = <ThreadSummary>[];
        final unread = <ThreadSummary>[];
        for (final t in threads) {
          if (!_history.isRead(t.key)) {
            unread.add(t);
          } else if (_newCount(t) > 0) {
            readNew.add(t);
          } else {
            read.add(t);
          }
        }
        return [...readNew, ...read, ...unread];
      case ThreadSort.momentum:
        return [...threads]
          ..sort((a, b) => momentumPerDay(b).compareTo(momentumPerDay(a)));
      case ThreadSort.resCount:
        return [...threads]..sort((a, b) => b.resCount.compareTo(a.resCount));
      case ThreadSort.newest:
        return [...threads]..sort((a, b) => b.keyAsInt.compareTo(a.keyAsInt));
      case ThreadSort.lastSeen:
        return [...threads]..sort(_compareLastSeen);
    }
  }

  /// 最後に開いた順（新しいほど上）。開いた記録が無ければ末尾へ、同着はスレの
  /// 新しい順。dat 落ちを含む履歴全体に効かせるため [_filteredThreads] でも使う。
  int _compareLastSeen(ThreadSummary a, ThreadSummary b) {
    final sa = _history.lastSeenAt(a.key);
    final sb = _history.lastSeenAt(b.key);
    if (sa != sb) {
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sb.compareTo(sa);
    }
    return b.keyAsInt.compareTo(a.keyAsInt);
  }

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<ThreadSort>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    '並べ替え',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final s in ThreadSort.values)
                  ListTile(
                    leading: Icon(
                      s.icon,
                      color: s == _sort ? scheme.primary : null,
                    ),
                    title: Text(s.label),
                    subtitle: Text(s.description),
                    trailing: s == _sort
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    selected: s == _sort,
                    onTap: () => Navigator.pop(context, s),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && picked != _sort) {
      setState(() {
        _sortByFilter[_filter] = picked;
        _reorder(); // ソート変更は明示操作なので並び順を貼り直す
      });
    }
  }

  Future<void> _pickFilter() async {
    final picked = await showModalBottomSheet<ThreadFilter>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    '表示',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final f in ThreadFilter.values)
                  ListTile(
                    leading: Icon(
                      f.icon,
                      color: f == _filter ? scheme.primary : null,
                    ),
                    title: Text(f.label),
                    subtitle: Text(f.description),
                    trailing: f == _filter
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    selected: f == _filter,
                    onTap: () => Navigator.pop(context, f),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && picked != _filter) {
      setState(() {
        _filter = picked;
        _reorder(); // 表示ごとに既定の並びが変わるので貼り直す
      });
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _search.clear();
    });
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  /// スレを長押ししたときの操作シート。スレ主 NG・お気に入り・履歴削除。
  Future<void> _showThreadActions(ThreadSummary thread) async {
    final metadent = thread.metadent;
    final isRead = _history.isRead(thread.key);
    final isFavorite = _history.isFavorite(thread.key);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  thread.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleSmall,
                ),
              ),
              ListTile(
                leading: Icon(
                  isFavorite ? Icons.star : Icons.star_border,
                  color: isFavorite ? scheme.tertiary : null,
                ),
                title: Text(isFavorite ? 'お気に入りを解除' : 'お気に入りに追加'),
                onTap: () => Navigator.pop(sheetContext, 'fav'),
              ),
              if (metadent == null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('このスレはスレ主情報を取得できませんでした'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title: const Text('このスレ主を NG'),
                  subtitle: Text('スレ主 [$metadent★] のスレを一覧から隠します'),
                  onTap: () => Navigator.pop(sheetContext, 'ng'),
                ),
              if (isRead)
                ListTile(
                  leading: const Icon(Icons.history_toggle_off),
                  title: const Text('履歴から消す'),
                  subtitle: const Text('既読の記録を消して未読に戻します'),
                  onTap: () => Navigator.pop(sheetContext, 'forget'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == 'fav') {
      await _history.toggleFavorite(thread.key);
      if (!mounted) return;
      setState(_reorder);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _history.isFavorite(thread.key) ? 'お気に入りに追加しました' : 'お気に入りを解除しました',
          ),
        ),
      );
    } else if (action == 'ng' && metadent != null) {
      await _ng.addCreator(metadent);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('スレ主 [$metadent★] を NG にしました'),
          action: SnackBarAction(
            label: '取り消す',
            onPressed: () => _ng.removeCreator(metadent),
          ),
        ),
      );
    } else if (action == 'forget') {
      await _history.forgetThread(thread.key);
      if (!mounted) return;
      setState(_reorder);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('履歴から消しました')));
    }
  }

  Future<void> _openThread(ThreadSummary thread) async {
    await _history.markOpenedThread(thread);
    if (!mounted) return;
    await Navigator.of(context).push(_threadRoute(thread));
    // 戻ってきたら既読状態が変わっているので再描画し、並び順も貼り直す
    // （既読優先ソートなどに反映）。
    if (mounted) setState(_reorder);
  }

  PageRoute<void> _threadRoute(ThreadSummary thread) {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) => ThreadScreen(
        threadKey: thread.key,
        threadTitle: thread.title,
        fetcher: _fetcher,
        endpoints: widget.endpoints,
        readHistory: _history,
        initialStatusLabel: _statusLabel(thread),
        initialResCount: thread.resCount,
        creatorMetadent: thread.metadent,
      ),
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  Future<void> _openLastViewedThread() async {
    if (_searchOpen) return;
    final stored = _history.lastViewedThread;
    if (stored == null) return;
    await _openThread(stored.toSummary());
  }

  void _handlePointerDown(PointerDownEvent event) {
    _horizontalDragDistance = 0;
    _verticalDragDistance = 0;
    _trackingSwipe = true;
    _swipeStartTimer?.cancel();
    _swipeStartTimer = Timer(_swipeStartTimeout, () {
      _trackingSwipe = false;
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_trackingSwipe) return;
    _horizontalDragDistance += event.delta.dx;
    _verticalDragDistance += event.delta.dy.abs();
  }

  void _handlePointerUp(PointerUpEvent event) {
    _swipeStartTimer?.cancel();
    if (!_trackingSwipe) return;
    _trackingSwipe = false;
    final leftwardDistance = -_horizontalDragDistance;
    if (leftwardDistance < _swipeDistanceThreshold) return;
    if (leftwardDistance < _verticalDragDistance * 1.2) return;
    _openLastViewedThread();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _swipeStartTimer?.cancel();
    _trackingSwipe = false;
  }

  Future<void> _openNewThread() async {
    final beforeKeys = _state?.threads.map((t) => t.key).toSet() ?? const {};
    final createdTitle = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => NewThreadScreen(
          fetcher: _fetcher,
          endpoints: widget.endpoints,
          authStore: widget.authStore,
        ),
      ),
    );
    // 立てたら一覧を更新して新スレを見えるようにする。
    if (createdTitle != null && mounted) {
      await _refresh(force: true);
      await _markOwnCreatedThread(createdTitle, beforeKeys);
    }
  }

  Future<void> _markOwnCreatedThread(
    String title,
    Set<String> beforeKeys,
  ) async {
    final state = _state;
    if (state == null) return;
    // subject 上のタイトルは HTML エンティティ化されている（`&`→`&amp;`、絵文字は
    // `&#…;` 等）。入力タイトルは生なので、デコードしてから突き合わせる。
    final candidates = state.threads.where(
      (t) =>
          !beforeKeys.contains(t.key) && decodeEntities(t.title).trim() == title,
    );
    if (candidates.isEmpty) return;
    final created = candidates.reduce(
      (a, b) => a.keyAsInt >= b.keyAsInt ? a : b,
    );
    await _history.rememberThread(created);
    await _history.markOwnThread(created.key);
    if (mounted) setState(_reorder);
  }

  Future<void> _rememberThreads(List<ThreadSummary> threads) async {
    final important = threads.where(
      (t) => _history.isRead(t.key) || _history.isFavorite(t.key),
    );
    for (final thread in important) {
      await _history.rememberThread(thread);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNewThread,
        icon: const Icon(Icons.add),
        label: const Text('スレを立てる'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: CustomScrollView(
            slivers: [
              SliverAppBar.large(
                title: const Text('エッヂ'),
                bottom: _searchOpen
                    ? PreferredSize(
                        preferredSize: const Size.fromHeight(64),
                        child: _ThreadSearchField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          onClear: () => setState(_search.clear),
                        ),
                      )
                    : null,
                actions: [
                  _PollingIndicator(active: _polling),
                  _SearchButton(active: _searchOpen, onPressed: _toggleSearch),
                  _FilterButton(filter: _filter, onPressed: _pickFilter),
                  _SortButton(sort: _sort, onPressed: _pickSort),
                  IconButton(
                    icon: const Icon(Icons.settings),
                    tooltip: '設定',
                    onPressed: _openSettings,
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              _body(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_state == null && _error != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _ErrorView(error: _error!, onRetry: _refresh),
      );
    }
    final threads = _filteredThreads(_orderedThreads());
    if (threads.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _EmptyFilterView(filter: _filter, query: _search.text.trim()),
      );
    }
    return SliverList.separated(
      itemCount: threads.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) => ThreadTile(
        thread: threads[i],
        isRead: _history.isRead(threads[i].key),
        newCount: _newCount(threads[i]),
        statusLabel: _statusLabel(threads[i]),
        isOwn: _history.isOwnThread(threads[i].key),
        onTap: () => _openThread(threads[i]),
        onLongPress: () => _showThreadActions(threads[i]),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.filter, required this.onPressed});
  final ThreadFilter filter;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final active = filter != ThreadFilter.current;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '表示',
      child: TextButton(
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filter.icon, size: 18, color: active ? scheme.primary : null),
            const SizedBox(width: 4),
            Text(filter.label),
          ],
        ),
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: active ? '検索を閉じる' : 'スレ検索',
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(
          active ? Icons.search_off : Icons.search,
          color: active ? scheme.primary : null,
        ),
      ),
    );
  }
}

class _ThreadSearchField extends StatelessWidget {
  const _ThreadSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: controller,
        autofocus: true,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'スレタイ検索',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '検索語を消す',
                  onPressed: onClear,
                  icon: const Icon(Icons.clear),
                ),
          filled: true,
          fillColor: scheme.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          isDense: true,
        ),
      ),
    );
  }
}

class _EmptyFilterView extends StatelessWidget {
  const _EmptyFilterView({required this.filter, required this.query});
  final ThreadFilter filter;
  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final searching = query.isNotEmpty;
    final message = searching
        ? '該当するスレはありません'
        : switch (filter) {
            ThreadFilter.current => 'スレがありません',
            ThreadFilter.history => '履歴はありません',
            ThreadFilter.favorites => 'お気に入りはありません',
          };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off : filter.icon,
            size: 44,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// 自動更新中を示す控えめなスピナー。停止中は場所だけ確保する。
///
/// 非アクティブ時にスピナーをツリーへ残さないこと（[CircularProgressIndicator]
/// は常時アニメーションするため、残すと `pumpAndSettle` が終わらない）。
class _PollingIndicator extends StatelessWidget {
  const _PollingIndicator({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      child: Center(
        child: active
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// 並べ替えボタン。ソートマーク（⇅）＋現在の項目＋▾ で「これは並べ替えで、
/// 今は◯◯、タップで変えられる」ことを一目で伝える。
class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onPressed});
  final ThreadSort sort;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '並べ替え',
      child: TextButton(
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.swap_vert, size: 18),
            const SizedBox(width: 4),
            Text(sort.label),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('読み込みに失敗しました', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '$error',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.tonal(onPressed: onRetry, child: const Text('再試行')),
        ],
      ),
    );
  }
}
