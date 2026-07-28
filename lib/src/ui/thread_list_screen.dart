import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/auth_store.dart';
import '../net/board.dart';
import '../net/board_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
import '../net/ng_store.dart';
import '../net/read_history.dart';
import 'board_catalog_screen.dart';
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

/// スレッド一覧に出す対象。下部バーのチップ列で直接切り替える。
enum ThreadFilter {
  /// 現在一覧（subject.txt）にあるスレ。
  current('現行', Icons.forum_outlined),

  /// 開いたことがあるスレのうち、未読レスが残っているもの。
  unreadNew('新着あり', Icons.mark_chat_unread_outlined),

  /// 開いたことがあるスレ（dat 落ちも含む）。
  history('履歴', Icons.history),

  /// お気に入りに登録したスレ（dat 落ちも含む）。
  favorites('お気に入り', Icons.star_border);

  const ThreadFilter(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ThreadListScreen extends StatefulWidget {
  const ThreadListScreen({
    super.key,
    this.board = Board.eddibb,
    this.fetcher,
    this.endpoints = const EdgeEndpoints(),
    this.pollInterval = const Duration(seconds: 5),
    this.readHistory,
    this.authStore,
  });

  /// 表示中の板。タイトル・機能ゲート・ドロワーの現在選択に使う。
  final Board board;

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
  /// ドロワーをスワイプ（左→右）から開くために Scaffold を参照する。
  final _scaffoldKey = GlobalKey<ScaffoldState>();
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
  NewThreadDraft _newThreadDraft = const NewThreadDraft();

  /// 表示ごとの既定の並び。現行は掲示板の定番＝最近レス順、履歴は最後に見た順。
  static const Map<ThreadFilter, ThreadSort> _defaultSort = {
    ThreadFilter.current: ThreadSort.bump,
    ThreadFilter.unreadNew: ThreadSort.bump,
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
  static const double _swipeDistanceThreshold = 25;
  static const Duration _swipeStartTimeout = Duration(milliseconds: 450);

  /// 横に並べた 2 面（0: スレ一覧、1: スレ）の位置。
  final _pages = PageController();

  /// 隣に控えているスレ。ここが null なら 1 面だけ（スレ面は無い）。
  ///
  /// 控えは常に 1 スレ。開いたスレを閉じずに残しておき、左へ引けば取得済みの
  /// 本文とスクロール位置のまま戻れるようにする。別のスレを開いたら差し替わる。
  ThreadSummary? _parked;

  /// スレ面が表に出ているか。[ThreadScreen.active] に渡す。
  bool _threadShown = false;

  /// 表示中の並び順（スレキー列）の固定スナップショット。実況板では最近レス順
  /// が高頻度で入れ替わり一覧を追えないため、自動更新では並べ替えず、レス数・
  /// 新着バッジだけをその場で更新する。並べ替え直しは手動更新・ソート変更・
  /// 表示の切り替えなど、こちらが動かしたときだけ行う（スレを見て戻ったときも
  /// 並べ替えない。行が動くと元居た場所を見失うため）。初回成功まで null。
  List<String>? _order;

  /// 固定順に載っているスレの最後の姿。自動更新で subject.txt から落ちても行を
  /// 残せるようにする（[_orderedThreads]）。行が消えると下が繰り上がって、読んで
  /// いた場所を見失うため。落ちたことは「dat落ち」チップで示し、行そのものは
  /// 次の並べ替え直しまで置いておく。[_reorder] で固定順に無いものを捨てる。
  final Map<String, ThreadSummary> _lastKnown = {};

  Timer? _timer;
  bool _fetching = false; // 多重取得の抑止

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _subject = SubjectFetcher(
      _fetcher,
      encoding: widget.endpoints.textEncoding,
    );
    _history = widget.readHistory ?? ReadHistory.shared;
    // 前回見ていたスレを控えに置く。表に出るまで取得もポーリングもしないので、
    // 置くだけならただの待機（[ThreadScreen.active] 参照）。
    _parked = _history.lastViewedThread?.toSummary();
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
    _pages.dispose();
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
        widget.endpoints.subjectListUrl,
        metadent: widget.endpoints.supportsMetadent,
      );
      if (!mounted) return;
      await _rememberThreads(r.state.threads);
      setState(() {
        _adoptState(r.state);
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
        widget.endpoints.subjectListUrl,
        prev: _state,
        metadent: widget.endpoints.supportsMetadent,
      );
      if (!mounted) return;
      if (!r.notModified) {
        await _rememberThreads(r.state.threads);
        // データだけ差し替え、並び順（_order）はあえて触らない。レス数・新着
        // バッジはその場で更新されるが、行が飛び回らないので一覧を追える。
        setState(() {
          _adoptState(r.state);
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
        widget.endpoints.subjectListUrl,
        prev: force ? null : _state,
        metadent: widget.endpoints.supportsMetadent,
      );
      if (!mounted) return;
      if (!r.notModified) await _rememberThreads(r.state.threads);
      setState(() {
        if (!r.notModified) _adoptState(r.state);
        _error = null;
        _loading = false;
        _reorder(); // 手動更新なので並び順を貼り直す
      });
    } catch (e) {
      if (!mounted) return;
      if (_state == null) setState(() => _error = e);
    }
  }

  /// 取得結果を採用する。行を残せるよう各スレの最後の姿を控え、初めて見たスレは
  /// 固定順の末尾に積む。
  ///
  /// 積んだ時点で場所が決まるので、あとはそこから動かない。固定順に入れずに毎回
  /// 「今のサーバ順で末尾へ」としていたときは、末尾の新スレ同士が更新のたびに
  /// 入れ替わってしまっていた。
  void _adoptState(SubjectState state) {
    _state = state;
    for (final thread in state.threads) {
      _lastKnown[thread.key] = thread;
    }
    final order = _order;
    if (order == null) return; // 初回。この直後に _reorder が全体を敷き直す。
    final known = order.toSet();
    for (final thread in state.threads) {
      if (known.add(thread.key)) order.add(thread.key);
    }
  }

  /// 現在のデータと選択中ソートで並び順を確定し、固定スナップショットを更新する。
  void _reorder() {
    final state = _state;
    if (state != null) {
      final order = _sorted(state.threads).map((t) => t.key).toList();
      _order = order;
      // 並べ替え直しは落ちたスレを一覧から外す機会でもある。ここで控えも捨てる。
      final keys = order.toSet();
      _lastKnown.removeWhere((key, _) => !keys.contains(key));
    }
  }

  /// 表示する並び。固定スナップショット [_order] の順に現在のデータを当てる。
  /// [_order] 未設定なら都度ソート。
  ///
  /// 新しく現れたスレは [_adoptState] が末尾に積んであるので、ここでは何もしない
  /// （末尾の新スレ同士も動かない）。
  ///
  /// subject.txt から落ちたスレは最後の姿（[_lastKnown]）のまま同じ場所に残す。
  /// 消して詰めると下の行が繰り上がり、見ていた位置がズレるため。
  List<ThreadSummary> _orderedThreads() {
    final threads = _state!.threads;
    final order = _order;
    if (order == null) return _sorted(threads);
    final byKey = {for (final t in threads) t.key: t};
    final result = <ThreadSummary>[];
    final placed = <String>{};
    for (final key in order) {
      final t = byKey[key] ?? _lastKnown[key];
      if (t != null) {
        result.add(t);
        placed.add(key);
      }
    }
    // 念のための取りこぼし避け（通常は [_adoptState] が積んでいるので空回り）。
    for (final t in threads) {
      if (!placed.contains(t.key)) result.add(t);
    }
    return result;
  }

  List<ThreadSummary> _filteredThreads(List<ThreadSummary> threads) {
    final filtered = switch (_filter) {
      ThreadFilter.current => threads,
      // 新着ありは履歴と同じ母集団（dat 落ちの保存分も含む）から、未読レスが
      // 残っているスレだけを残す。_newCount は未読（未オープン）スレでは 0 な
      // ので、開いたことがある条件はこれだけで満たせる。
      ThreadFilter.unreadNew => _withStoredThreads(
        threads,
        (key) => _history.isRead(key),
      ).where((t) => _newCount(t) > 0).toList(),
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

  void _selectFilter(ThreadFilter picked) {
    if (picked == _filter) return;
    setState(() {
      _filter = picked;
      _reorder(); // 表示ごとに既定の並びが変わるので貼り直す
    });
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

  Future<void> _copyThreadUrl(ThreadSummary thread) async {
    await Clipboard.setData(
      ClipboardData(text: widget.endpoints.thread(thread.key).toString()),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('スレURLをコピーしました')));
    }
  }

  Future<void> _openThreadFromUrl() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final initial = clipboard?.text?.trim() ?? '';
    final controller = TextEditingController(
      text: _threadRefFromText(initial) == null ? '' : initial,
    );
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('URLからスレを開く'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'https://bbs.eddibb.cc/liveedge/...',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('開く'),
          ),
        ],
      ),
    );
    controller.dispose();
    final ref = _threadRefFromText(url);
    if (ref == null) {
      if (url != null && url.trim().isNotEmpty && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('この板のスレURLではありません')));
      }
      return;
    }
    _openThreadRef(ref);
  }

  ThreadRef? _threadRefFromText(String? text) {
    final raw = text?.trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host != widget.endpoints.host) return null;
    final ref = parseThreadUrl(uri);
    if (ref == null || ref.board != widget.endpoints.boardKey) return null;
    return ref;
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
                leading: const Icon(Icons.link),
                title: const Text('スレURLをコピー'),
                onTap: () => Navigator.pop(sheetContext, 'copyUrl'),
              ),
              ListTile(
                leading: Icon(
                  isFavorite ? Icons.star : Icons.star_border,
                  color: isFavorite ? scheme.tertiary : null,
                ),
                title: Text(isFavorite ? 'お気に入りを解除' : 'お気に入りに追加'),
                onTap: () => Navigator.pop(sheetContext, 'fav'),
              ),
              // スレ主 NG（metadent）はエッヂ (eddist) だけの機能。5ch では出さない。
              if (widget.endpoints.supportsMetadent)
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
    if (action == 'copyUrl') {
      await _copyThreadUrl(thread);
    } else if (action == 'fav') {
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

  /// スレを開く。控えを差し替えて、スレ面へ移る。
  void _openThread(ThreadSummary thread) {
    // 取得を待たずに履歴へ入れる（一覧の既読表示は開いた時点で変わる）。
    unawaited(_history.markOpenedThread(thread));
    final replacing = _parked?.key != thread.key;
    setState(() {
      if (replacing) _parked = thread;
      // 移動を待たずに表扱いにする。着いてから読み始めると、その間だけ
      // 空の画面が見えてしまうため。
      _threadShown = true;
    });
    // 差し替えた直後はスレ面がまだ組み立てられていないので、次のフレームで動く。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.animateToPage(
        1,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// スレ面から一覧へ戻る。スレは控えに残す。
  void _showList() {
    if (!_pages.hasClients) return;
    _pages.animateToPage(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInCubic,
    );
  }

  void _onPageChanged(int page) {
    final shown = page == 1;
    if (shown == _threadShown) return;
    // 一覧へ戻ってきても並べ替えない。行き来のたびに行が動くと、さっきまで
    // 見ていた場所を見失うため（既読・新着バッジはその場で更新される）。
    setState(() => _threadShown = shown);
  }

  void _openThreadRef(ThreadRef ref) {
    final thread = _threadByKey(ref.threadKey);
    _openThread(
      thread ??
          ThreadSummary(
            key: ref.threadKey,
            title: '',
            resCount: 0,
            capName: null,
          ),
    );
  }

  ThreadSummary? _threadByKey(String key) {
    final state = _state;
    if (state != null) {
      for (final thread in state.threads) {
        if (thread.key == key) return thread;
      }
    }
    for (final thread in _history.storedThreads) {
      if (thread.key == key) return thread.toSummary();
    }
    return null;
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
    // 縦が優勢ならスクロール操作なので無視。右→左（スレ面へ移る）は横並びの
    // ページ送りが指に追従して受け持つので、ここでは見ない。
    if (_horizontalDragDistance < _swipeDistanceThreshold) return;
    if (_horizontalDragDistance < _verticalDragDistance * 1.2) return;
    // 左→右: 板一覧（ドロワー）を開く。
    _scaffoldKey.currentState?.openDrawer();
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
          maxTitle: widget.board.subjectMax,
          maxBody: widget.board.messageMax,
          initialTitle: _newThreadDraft.title,
          initialBody: _newThreadDraft.body,
          onDraftChanged: (draft) => _newThreadDraft = draft,
          onDraftCleared: () => _newThreadDraft = const NewThreadDraft(),
        ),
      ),
    );
    // 立てたら一覧を更新して新スレを見えるようにする。
    if (createdTitle != null && mounted) {
      await _refresh(force: true);
      final created = await _markOwnCreatedThread(createdTitle, beforeKeys);
      // 自分で立てたスレはそのまま開いて、書き込み結果を確認しやすくする。
      if (created != null && mounted) {
        _openThread(created);
      }
    }
  }

  Future<ThreadSummary?> _markOwnCreatedThread(
    String title,
    Set<String> beforeKeys,
  ) async {
    final state = _state;
    if (state == null) return null;
    // subject 上のタイトルは HTML エンティティ化されている（`&`→`&amp;`、絵文字は
    // `&#…;` 等）。入力タイトルは生なので、デコードしてから突き合わせる。
    final candidates = state.threads.where(
      (t) =>
          !beforeKeys.contains(t.key) &&
          decodeEntities(t.title).trim() == title,
    );
    if (candidates.isEmpty) return null;
    final created = candidates.reduce(
      (a, b) => a.keyAsInt >= b.keyAsInt ? a : b,
    );
    await _history.rememberThread(created);
    await _history.markOwnThread(created.key);
    if (mounted) setState(_reorder);
    return created;
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
    final parked = _parked;
    // 一覧とスレを横に並べ、指に追従して行き来できるようにする。両面ともページの
    // 外へ出ても生かしたまま（[_KeepAlive]・[ThreadScreen.active]）なので、行き来
    // しても一覧のスクロール位置も、スレの取得済みの本文と位置も残る。
    //
    // 控えが無くても 1 面だけの PageView にする。控えの有無で木の形が変わると
    // 一覧が作り直され、初めてスレを開いた瞬間だけスクロール位置が飛ぶため。
    return PopScope(
      // スレ面ではシステムの戻るを一覧へ戻す操作にする。
      canPop: !_threadShown,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showList();
      },
      child: PageView(
        controller: _pages,
        // 一覧のさらに左・スレ面のさらに右へ引いたとき、存在しない面の背景が
        // 覗くと黒くちらつく。端では弾ませず、実在する隣ページへの移動だけにする。
        physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
        onPageChanged: _onPageChanged,
        children: [
          _KeepAlive(child: _list()),
          if (parked != null)
            _KeepAlive(
              child: ThreadScreen(
                key: ValueKey(parked.key),
                threadKey: parked.key,
                threadTitle: parked.title,
                fetcher: _fetcher,
                endpoints: widget.endpoints,
                pollInterval: widget.pollInterval,
                authStore: widget.authStore,
                readHistory: _history,
                ngStore: _ng,
                initialStatusLabel: _statusLabel(parked),
                initialResCount: parked.resCount,
                creatorMetadent: parked.metadent,
                defaultName: widget.board.defaultName,
                active: _threadShown,
                onClose: _showList,
              ),
            ),
        ],
      ),
    );
  }

  Widget _list() {
    return Scaffold(
      key: _scaffoldKey,
      // 左ドロワーから板を切り替え・追加する。左端スワイプ（既定）に加え、一覧上を
      // 左→右にスワイプしても開けるようにする（_handlePointerUp）。
      drawer: _BoardDrawer(currentBoardId: widget.board.id),
      // 下部バーはすりガラスにして、その背後をリストが流れる。extendBody で本文を
      // バーの下まで広げ、BackdropFilter が背後を拾えるようにする。
      extendBody: true,
      // 「スレを立てる」は独立して浮かせる。通常 FAB（56）は下部バーに対して
      // 大きく、小型 FAB（40）は埋もれ気味なので、中間の 48 にする。
      floatingActionButton: widget.endpoints.supportsWrite
          ? _NewThreadFab(onPressed: _openNewThread)
          : null,
      // よく使う検索・絞り込みは、片手で届く下部のバーにチップでまとめる。
      // 並べ替えは頻度が低いうえ、値のラベルが長い組み合わせ（例「最後に見た順」
      // ＋「お気に入り」）で下部バーからはみ出すので上の AppBar に置く。設定・
      // URL で開くはさらに低頻度なので上の ⋮ に集約する。
      bottomNavigationBar: _BottomActionBar(
        searchOpen: _searchOpen,
        search: _search,
        onToggleSearch: _toggleSearch,
        onSearchChanged: (_) => setState(() {}),
        onSearchClear: () => setState(_search.clear),
        filter: _filter,
        onSelectFilter: _selectFilter,
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
              SliverAppBar.medium(
                title: Text(widget.board.title),
                actions: [
                  _PollingIndicator(active: _polling),
                  _SortButton(sort: _sort, onPressed: _pickSort),
                  _OverflowMenu(
                    onOpenUrl: _openThreadFromUrl,
                    onOpenSettings: _openSettings,
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
    // 行間のハイライン（継ぎ目）は外し、余白と未読ドットだけで区切る。末尾は
    // 浮遊ガラスバーの下へ隠れないよう、その高さ分の余白を確保する。
    return SliverPadding(
      padding: EdgeInsets.only(
        bottom: 96 + MediaQuery.paddingOf(context).bottom,
      ),
      sliver: SliverList.builder(
        itemCount: threads.length,
        itemBuilder: (context, i) => ThreadTile(
          thread: threads[i],
          isRead: _history.isRead(threads[i].key),
          newCount: _newCount(threads[i]),
          statusLabel: _statusLabel(threads[i]),
          isOwn: _history.isOwnThread(threads[i].key),
          onTap: () => _openThread(threads[i]),
          onLongPress: () => _showThreadActions(threads[i]),
        ),
      ),
    );
  }
}

class _NewThreadFab extends StatelessWidget {
  const _NewThreadFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'スレを立てる',
      child: Material(
        color: scheme.primary,
        elevation: 6,
        shadowColor: scheme.shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(Icons.add, size: 22, color: scheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

/// 下部バーの操作要素（チップ・検索欄）の高さ。チップと検索欄で同じ値を使い、
/// 検索の開閉でバー内の見た目の高さが揃うようにする。M3 チップ本来のピル高さに
/// 合わせた 32。
const double _kBarControlHeight = 32;

/// バーの操作要素（チップ・検索欄）でアイコンの左右に取る余白。
///
/// チップと検索欄で同じ値を使い、下部バーの左パディングも開閉で揃えることで、
/// 検索を開いても虫めがねが同じ位置のまま動かない。アイコンだけのチップでは
/// 左右同値＝ピルのちょうど中心にアイコンが来る。
const double _kSearchIconInset = 7;

/// 検索アイコンとラベル/入力文字の間隔。
const double _kSearchLabelGap = 6;

/// TextField は prefixIcon と入力文字の間に内部余白が入るため、その分だけ詰める。
const double _kSearchFieldIconTrailingInset = 2;

/// 画面下部の操作バー。検索と表示の切り替えを、片手で届く位置にまとめる。
///
/// 表示はシートを挟まず、チップ列を 1 タップで切り替える。選択中だけラベルを出し、
/// 残りはアイコンだけにして、狭い画面でも 4 つ並ぶようにする。検索中は同じ場所を
/// 検索欄に差し替え、操作を下部で完結させる。並べ替えは頻度が低くラベルも長いので
/// AppBar 側のアイコンに逃がしてある。
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.searchOpen,
    required this.search,
    required this.onToggleSearch,
    required this.onSearchChanged,
    required this.onSearchClear,
    required this.filter,
    required this.onSelectFilter,
  });

  final bool searchOpen;
  final TextEditingController search;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;
  final ThreadFilter filter;
  final ValueChanged<ThreadFilter> onSelectFilter;

  @override
  Widget build(BuildContext context) {
    if (searchOpen) {
      // 検索欄はキーボードのすぐ上（下部）に出す。Scaffold は bottomNavigationBar
      // をキーボードの上へは押し上げない（持ち上がるのは body と FAB だけ）ため、
      // このままではキーボードに隠れてしまう。キーボードの高さ分だけ下に余白を
      // 足して、検索欄をその上へ押し上げ、片手でそのまま入力できるようにする。
      return AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _GlassBar(
          // チップ表示時と同じ高さにして、検索の開閉でバーが上下しないようにする。
          // 左パディングもチップ表示時と同じにして、虫めがねの位置を合わせる。
          height: 58,
          padding: const EdgeInsets.only(left: 10, right: 4),
          child: Row(
            children: [
              Expanded(
                child: _ThreadSearchField(
                  controller: search,
                  onChanged: onSearchChanged,
                  onClear: onSearchClear,
                ),
              ),
              const SizedBox(width: 4),
              SizedBox.square(
                dimension: _kBarControlHeight,
                child: IconButton(
                  tooltip: '検索を閉じる',
                  icon: const Icon(Icons.search_off),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: _kBarControlHeight,
                    height: _kBarControlHeight,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: onToggleSearch,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // 検索は「動作」、表示は「現在の状態」。役割が違うので左端の検索と細い仕切り
    // で分け、状態側は親指の届く右側にまとめる。
    return _GlassBar(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          // 検索は中身が変わらないのでラベル付き。余った幅はここで全部使い、
          // 開いたときに出る検索欄とほぼ同じ左端・同じ幅にして、チップがその場で
          // 伸びたように見せる（押しやすさも稼げる）。
          Expanded(
            child: _GlassChip(
              icon: Icons.search,
              label: '検索',
              tooltip: 'スレ検索',
              onPressed: onToggleSearch,
            ),
          ),
          // 表示のチップ群は仕切りごと右（親指側）に。アイコンだけの一定幅なので、
          // 文字を大きくする設定でも幅は変わらず、あふれるのは検索側だけ。
          const SizedBox(width: 10),
          const _BarDivider(),
          const SizedBox(width: 10),
          for (final f in ThreadFilter.values) ...[
            if (f != ThreadFilter.values.first) const SizedBox(width: 6),
            _GlassChip(
              icon: f.icon,
              // アイコンだけなので、長押しで名前が出るようにする。
              tooltip: f.label,
              selected: f == filter,
              onPressed: () => onSelectFilter(f),
            ),
          ],
        ],
      ),
    );
  }
}

/// 浮遊するすりガラスの下部バー。縁から浮かせた角丸パネルにし、境界線や面差では
/// なく BackdropFilter のぼかし・弱いティント・上辺の淡いハイライト・影で分離する。
/// 背後をリストが流れるので（[Scaffold.extendBody]）ガラス質感が出る。
class _GlassBar extends StatelessWidget {
  const _GlassBar({
    required this.height,
    required this.padding,
    required this.child,
  });

  final double height;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // ガラスの縁で光が当たったような、淡いハイライト。
    final rim = Colors.white.withValues(alpha: dark ? 0.14 : 0.55);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: DecoratedBox(
          // 影は切り抜きの外側に置いてぼかしを保つ。
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.36 : 0.16),
                blurRadius: 24,
                spreadRadius: -8,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Container(
                height: height,
                padding: padding,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: dark ? 0.52 : 0.60),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: rim, width: 1),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ガラスバーに乗る小片（チップ・検索欄）に重ねる膜の濃さ。
///
/// 枠線やグラデーションは足さない。バーが [BackdropFilter] で背後を溶かして
/// いること自体がガラスの表現で、その上の小片は「ほぼ同じ色だが背後の見え方が
/// 違う」だけで存在を示す。
const double _kGlassFilmAlpha = 0.06;

/// 選択中のチップに焼き込むティントの濃さ。押す前の膜（[_kGlassFilmAlpha]）より
/// 濃いが、これも canvas 色に焼き込むので、別色のボタンが現れるのではなく同じ
/// ガラスの濃さが変わったように見える。現在地は主に文字色（primary）で示す。
const double _kGlassSelectedTintAlpha = 0.16;

/// ガラス上のホバー・押下の反応色。灰色の板が乗ったように見えないよう、明るい側
/// （暗いテーマでは白）に寄せた薄い膜にする。
Color _glassOverlay(ColorScheme scheme, Brightness brightness, double alpha) =>
    (brightness == Brightness.dark ? Colors.white : scheme.onSurface)
        .withValues(alpha: alpha);

/// ガラスバー上のチップ。枠は付けず、弱いソフト塗りだけで「操作」と分かるように
/// する。
///
/// [label] は中身が変わらないチップ（検索）にだけ付ける。状態で文字が出たり
/// 消えたりすると、タップのたびにチップの幅＝隣の位置がズレて、続けて押すときに
/// 狙いが外れる。表示の切り替えチップはアイコンだけの一定幅にして、今どれを
/// 選んでいるかは幅ではなく塗りの濃さで示す。
class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final String? label;

  /// 「今この状態」を表すチップ（表示の切り替え）。塗りと色を強める。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = label;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    // ActionChip は空ラベルでもラベル枠の余白が残り、アイコンがピルの中心から
    // ずれる・高さが検索欄と揃わない。バーの操作要素は高さを
    // [_kBarControlHeight] で統一したいので、素の Material で組む。
    final brightness = theme.brightness;
    return Tooltip(
      message: tooltip,
      child: Material(
        // 押す前のチップは「不透明な surface ＋ 6% の膜」。色はバーの地とほぼ
        // 同じだが、そこだけ背後のぼかしを遮るので、色ではなく透け感の差で
        // ボタンだと分かる。半透明の膜だけにすると色差が出て輪郭が立つので、
        // 必ず canvas 色に焼き込んでから置く。
        color: Color.alphaBlend(
          selected
              ? scheme.primary.withValues(alpha: _kGlassSelectedTintAlpha)
              : scheme.onSurface.withValues(alpha: _kGlassFilmAlpha),
          theme.canvasColor,
        ),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          // 押した跡が灰色の板に見えないよう、ガラスが濡れる程度の薄い膜。
          hoverColor: _glassOverlay(scheme, brightness, 0.08),
          highlightColor: _glassOverlay(scheme, brightness, 0.06),
          splashColor: _glassOverlay(scheme, brightness, 0.12),
          child: SizedBox(
            height: _kBarControlHeight,
            child: Padding(
              // アイコンだけのときは左右同じ余白＝ピルの中心にアイコンが来る。
              padding: const EdgeInsets.symmetric(
                horizontal: _kSearchIconInset,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: foreground),
                  if (text != null) ...[
                    const SizedBox(width: _kSearchLabelGap),
                    Text(
                      text,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 下部バーの中で「動作（検索）」と「状態（表示）」を分ける細い仕切り。
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 20,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: scheme.onSurface.withValues(alpha: 0.12),
      ),
    );
  }
}

/// AppBar の並べ替えボタン。
///
/// 「並べ替え」そのものを表す上下矢印を主役にして何のボタンか分かるようにし、
/// 現在選んでいる並びのアイコン（シートの各項目と同じもの）を右下に小さく重ねて
/// 「今どの並びか」も一目で分かるようにする。並びのアイコン単体では何のボタンか
/// 読み取れないため、必ずこの組み合わせで出す。
class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onPressed});

  final ThreadSort sort;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: '並べ替え',
      onPressed: onPressed,
      icon: SizedBox.square(
        dimension: 24,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Positioned(top: 0, left: 0, child: Icon(Icons.swap_vert)),
            // 主役の矢印と重なっても潰れないよう、AppBar と同じ色（theme.dart で
            // surfaceTint 無しの surface）で背後を抜いてから小アイコンを載せる。
            Positioned(
              right: -3,
              bottom: -3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1.5),
                  child: Icon(sort.icon, size: 13, color: scheme.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 上部の ⋮ メニュー。低頻度な「URL からスレを開く」「設定」をまとめる。
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.onOpenUrl, required this.onOpenSettings});
  final VoidCallback onOpenUrl;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'メニュー',
      onSelected: (value) => value == 0 ? onOpenUrl() : onOpenSettings(),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 0,
          child: ListTile(
            leading: Icon(Icons.link),
            title: Text('URLからスレを開く'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 1,
          child: ListTile(
            leading: Icon(Icons.settings),
            title: Text('設定'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// 左ドロワー。追加済みの板を切り替え、URL や板リストから新しい板を足す。
///
/// 起動＝現在板のスレ一覧、という体験は保ったまま、板の切替・追加をここに集約
/// する。エッヂ（既定板）は削除できない。
class _BoardDrawer extends StatelessWidget {
  const _BoardDrawer({required this.currentBoardId});
  final String currentBoardId;

  Future<void> _addBoard(BuildContext context) async {
    final store = BoardStore.shared;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final controller = TextEditingController(
      text: clipboard?.text?.trim() ?? '',
    );
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('URLで板を追加'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'https://mi.5ch.net/news4vip/',
            helperText: '掲示板（板）の URL を貼り付けてください',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.trim().isEmpty) return;
    // 追加は通信を伴うので待つ間の目印を出す。
    messenger.showSnackBar(const SnackBar(content: Text('板を確認しています…')));
    try {
      final board = await store.addFromUrl(input);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('「${board.title}」を追加しました')),
      );
      navigator.pop(); // ドロワーを閉じる（切替は BoardStore の通知で反映）。
    } on BoardAddException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('板を追加できませんでした（通信エラー）')),
      );
    }
  }

  /// 板リスト（5ch の BBSMENU・同じサーバの板リスト）から選んで追加する。
  /// 追加は画面側でまとめて行うので、ここは結果の通知とドロワーを閉じるだけ。
  Future<void> _addBoardFromCatalog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await navigator.push<BoardCatalogResult>(
      MaterialPageRoute<BoardCatalogResult>(
        builder: (_) => const BoardCatalogScreen(),
      ),
    );
    if (result == null) return;
    final added = result.added;
    final failed = result.failed;
    if (added.isEmpty && failed.isEmpty) return;
    final message = switch ((added.length, failed.length)) {
      (0, _) => '板を追加できませんでした（${failed.join('・')}）',
      (1, 0) => '「${added.single.title}」を追加しました',
      (final n, 0) => '$n 板を追加しました',
      (final n, final f) => '$n 板を追加しました（$f 板は追加できませんでした）',
    };
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (added.isNotEmpty) {
      navigator.pop(); // ドロワーを閉じる（切替は BoardStore の通知で反映）。
    }
  }

  Future<void> _confirmRemove(BuildContext context, Board board) async {
    final store = BoardStore.shared;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('「${board.title}」を削除しますか？'),
        content: const Text('板を一覧から外します。既読履歴は残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.remove(board.id);
      messenger.showSnackBar(
        SnackBar(content: Text('「${board.title}」を削除しました')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: ListenableBuilder(
        listenable: BoardStore.shared,
        builder: (context, _) {
          final boards = BoardStore.shared.boards;
          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '板',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final board in boards)
                        ListTile(
                          leading: Icon(
                            board.id == currentBoardId
                                ? Icons.check_circle
                                : Icons.forum_outlined,
                            color: board.id == currentBoardId
                                ? scheme.primary
                                : null,
                          ),
                          title: Text(board.title),
                          subtitle: Text(
                            board.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected: board.id == currentBoardId,
                          trailing: board.id == Board.eddibb.id
                              ? null
                              : IconButton(
                                  tooltip: '板を削除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () =>
                                      _confirmRemove(context, board),
                                ),
                          onTap: () async {
                            Navigator.of(context).pop(); // ドロワーを閉じる
                            await BoardStore.shared.select(board.id);
                          },
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.format_list_bulleted),
                  title: const Text('板リストから追加'),
                  onTap: () => _addBoardFromCatalog(context),
                ),
                ListTile(
                  leading: const Icon(Icons.add_link),
                  title: const Text('URLで板を追加'),
                  onTap: () => _addBoard(context),
                ),
              ],
            ),
          );
        },
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // ガラスバーに馴染むよう、チップと同じ弱いソフト塗り・角丸・枠なしに揃える。
    // 枠線ではなくティントで「入力できる場所」と分かるようにし、下部バーの中で
    // 浮かないようにする。高さはバー内で縦中央に収まるようにパディングで調整。
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    // 入力・ヒントの文字はチップのラベル（labelLarge）と同じサイズに揃える。
    // 既定の bodyLarge（16）だと隣のチップより一回り大きく見えてしまう。
    final textStyle = theme.textTheme.labelLarge;
    return TextField(
      controller: controller,
      autofocus: true,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: textStyle,
      decoration: InputDecoration(
        hintText: 'スレタイ検索',
        hintStyle: textStyle?.copyWith(color: scheme.onSurfaceVariant),
        // 閉じているときの検索チップのアイコンと、大きさも位置もぴったり重なる
        // ようにする（開いた瞬間に虫めがねが動かず、チップがそのまま入力欄に
        // 伸びたように見える）。左の余白 [_kSearchIconInset] はチップのアイコン
        // 位置に合わせた値で、バー側の左パディングと対で効く。
        prefixIcon: Padding(
          padding: const EdgeInsets.only(
            left: _kSearchIconInset,
            right: _kSearchFieldIconTrailingInset,
          ),
          child: Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
        ),
        // チップと同じ高さ（_kBarControlHeight）に固定する。
        prefixIconConstraints: const BoxConstraints(
          minHeight: _kBarControlHeight,
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '検索語を消す',
                onPressed: onClear,
                icon: const Icon(Icons.clear),
                iconSize: 20,
                padding: EdgeInsets.zero,
                // クリアボタンで欄が 40 より高くならないよう高さを固定。
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: _kBarControlHeight,
                ),
              ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: _kBarControlHeight,
        ),
        filled: true,
        fillColor: scheme.onSurface.withValues(alpha: _kGlassFilmAlpha),
        isDense: true,
        // 高さを _kBarControlHeight（32）に収めるため上下パディングを詰める。
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
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
            ThreadFilter.unreadNew => '新着はありません',
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

/// 横のページから外れても中身を生かしておくラッパ。
///
/// [PageView] は見えなくなった面を木から外してしまい、置いておいたスレ画面の
/// 状態（取得済みの本文・スクロール位置）が消えるため、明示的に残す。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
