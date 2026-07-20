import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../net/auth_launcher.dart';
import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
import '../net/ng_store.dart';
import '../net/read_history.dart';
import 'ng_screen.dart';
import 'post_item.dart';
import 'write_auth.dart';

/// スレッド画面。dat を差分ポーリングし、レスを番号順に並べる。
///
/// 末尾を見ているときだけ自動追従し、遡って読んでいるときは位置を維持する。
/// 遡り中に来た新着は「新着ライン」で区切って示す。
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.threadKey,
    required this.threadTitle,
    this.fetcher,
    this.endpoints = const EdgeEndpoints(),
    this.pollInterval = const Duration(seconds: 5),
    this.authStore,
    this.authLauncher = const SystemBrowserLauncher(),
    this.readHistory,
    this.ngStore,
    this.initialStatusLabel,
    this.initialResCount = 0,
    this.creatorMetadent,
  });

  final String threadKey;
  final String threadTitle;
  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;
  final Duration pollInterval;
  final int initialResCount;

  /// スレ立て人の metadent（`subject-metadent.txt` 由来）。一覧から開いた場合に
  /// 渡され、スレタイのメニューから「このスレ主を NG」できるようにする。
  /// 直接キーで開いた等で不明なら null。
  final String? creatorMetadent;

  /// NG（あぼーん）設定。既定はアプリ共有インスタンス（テストで差し替え可能）。
  final NgStore? ngStore;

  /// 既読履歴。離脱時に「見たレス数」を記録する。
  final ReadHistory? readHistory;

  /// 一覧側で dat落ち/完走など停止扱いと分かっている場合の表示ラベル。
  ///
  /// dat 本文だけでは「subject.txt から消えた」ことは判定できないため、一覧から
  /// 開いた場合はその判定を引き継ぐ。
  final String? initialStatusLabel;

  /// トークン保管。既定はアプリ共有インスタンス（テストで差し替え可能）。
  final AuthStore? authStore;

  /// 認証ページの開き方。既定はシステムブラウザ。
  final AuthLauncher authLauncher;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen>
    with WidgetsBindingObserver {
  late final HttpFetcher _fetcher;
  late final bool _ownsFetcher;
  late final DatFetcher _dat;
  late final AuthStore _authStore;
  late final ReadHistory _history;
  late final NgStore _ng;

  /// NG 判定されたが、タップで一時的に表示したレス番号。
  final _revealedNg = <int>{};
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _composerKey = GlobalKey();

  /// 一覧の各行。Res（レス）か [_NewArrivalLine]（新着境界）のどちらか。
  List<Object> _items = const [];

  /// 初回表示で合わせるインデックス（前回位置 / 末尾 / 先頭）。
  int _initialIndex = 0;

  /// 末尾（最新レス）が画面に見えているか。追従・「最新へ」ボタンに使う。
  bool _atBottomNow = false;

  DatState _state = DatState.empty;
  Object? _error;
  bool _loading = true;
  bool _polling = false;

  /// スクロールで実際に見えた最大レス番号（＝どこまで読んだか）。可視性で
  /// 追跡する。これより後ろのレスが「未読」で、「最新へ」の件数の基準になる。
  int _furthestRead = 0;

  /// スレを開いた時点のレス数。これを超える番号が「新着（今回開いてから増えた
  /// 分）」で、新着ラインの境界になる。スクロールでは動かない。
  int _openCount = 0;

  Timer? _timer;
  Timer? _postRefreshTimer;
  Timer? _topSnackTimer;
  OverlayEntry? _topSnackEntry;
  bool _fetching = false;
  int _pendingOwnPosts = 0;
  double _horizontalDragDistance = 0;
  double _verticalDragDistance = 0;
  bool _trackingSwipe = false;
  final _selectedBodyResNumbers = <int>{};
  Timer? _swipeStartTimer;
  static const double _swipeDistanceThreshold = 96;
  static const Duration _swipeStartTimeout = Duration(milliseconds: 450);
  static const int _postRefreshAttempts = 4;
  static const Duration _postRefreshRetryDelay = Duration(milliseconds: 700);

  Uri get _url => widget.endpoints.dat(widget.threadKey);

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _dat = DatFetcher(_fetcher);
    _authStore = widget.authStore ?? AuthStore.shared;
    _history = widget.readHistory ?? ReadHistory.shared;
    _ng = widget.ngStore ?? NgStore.shared;
    _ng.addListener(_onNgChanged);
    _positions.itemPositions.addListener(_onPositions);
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _history.markOpenedThread(
        ThreadSummary(
          key: widget.threadKey,
          title: widget.threadTitle,
          resCount: widget.initialResCount,
          capName: null,
        ),
      ),
    );
    _initialLoad();
    _startPolling();
  }

  @override
  void dispose() {
    // 離脱時に「どこまで読んだか（スクロールで見た最大レス番号）」を記録する。
    // 次に開いたときの再開位置と、一覧の新着判定に使う。markRead は下げない。
    if (_furthestRead > 0) {
      unawaited(_history.markRead(widget.threadKey, _furthestRead));
    }
    _ng.removeListener(_onNgChanged);
    _positions.itemPositions.removeListener(_onPositions);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _postRefreshTimer?.cancel();
    _swipeStartTimer?.cancel();
    _topSnackTimer?.cancel();
    _topSnackEntry?.remove();
    _composer.dispose();
    _composerFocus.dispose();
    final fetcher = _fetcher;
    if (_ownsFetcher && fetcher is HttpClientFetcher) fetcher.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _startPolling();
        _poll();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _timer?.cancel();
        _persistReadPosition();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  /// 末尾（最新レス）が見えているか。追従・「最新へ」ボタンに使う。
  bool get _atBottom => _state.res.isEmpty || _atBottomNow;

  String? get _statusLabel {
    final inherited = widget.initialStatusLabel;
    if (inherited != null) return inherited;
    if (_state.res.length >= 1000 ||
        _state.res.any((r) => r.kind == ResKind.over1000)) {
      return '完走';
    }
    return null;
  }

  bool get _isStopped => _statusLabel != null;

  Future<void> _initialLoad() async {
    try {
      final r = await _dat.fetch(_url);
      if (!mounted) return;
      final total = r.state.res.length;
      await _history.markLastViewedThread(
        ThreadSummary(
          key: widget.threadKey,
          title: widget.threadTitle,
          resCount: total,
          capName: null,
        ),
      );
      if (!mounted) return;
      final lastSeen = _history.lastSeen(widget.threadKey);
      // 新着境界と初回スクロール位置を決める。
      // - 未読（初回）: 先頭から（インデックス 0）。新着ライン無し。
      // - 既読＆新着あり: 前回位置に新着ラインを置き、そこへ合わせる。
      // - 既読＆新着なし: 末尾（続き）へ。
      // 新着ラインの少し手前に着地させて、直前の流れを思い出せるようにする。
      const overlap = 3;
      final int openCount;
      final int initialIndex;
      if (lastSeen == null) {
        openCount = total;
        initialIndex = 0;
      } else if (lastSeen < total) {
        openCount = lastSeen; // ここから下が新着
        // 新着ラインの行位置は items 上で openCount。数レス手前に寄せる。
        initialIndex = (lastSeen - overlap) < 0 ? 0 : lastSeen - overlap;
      } else {
        openCount = total;
        initialIndex = total > 0 ? total - 1 : 0;
      }
      setState(() {
        _state = r.state;
        _openCount = openCount;
        _furthestRead = lastSeen ?? 0;
        _initialIndex = initialIndex;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _poll({bool force = false}) async {
    if (_fetching || !mounted) return;
    _fetching = true;
    setState(() => _polling = true);
    try {
      final wasAtBottom = _atBottom;
      final wasShortContent = _contentFitsViewport();
      final previousResCount = _state.res.length;
      final r = await _dat.fetch(_url, prev: force ? DatState.empty : _state);
      if (!mounted) return;
      final newRes = _newResSince(r.state, previousResCount);
      if (newRes.isNotEmpty) {
        await _markPendingOwnPosts(newRes);
        if (!mounted) return;
        setState(() => _state = r.state);
        // 末尾に居たなら追従する。
        if (wasShortContent) {
          _scrollToTopSoon();
        } else if (wasAtBottom) {
          _scrollToBottomSoon();
        }
      }
    } catch (_) {
      // ポーリング失敗は無視。次周期で回復を試みる。
    } finally {
      _fetching = false;
      if (mounted) setState(() => _polling = false);
    }
  }

  List<Res> _newResSince(DatState state, int previousResCount) {
    if (state.res.length <= previousResCount) return const [];
    return state.res.skip(previousResCount).toList();
  }

  /// 可視レスから既読位置（最大レス番号）と末尾到達を更新する。
  void _onPositions() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty || _items.isEmpty) return;
    final lastIndex = _items.length - 1;
    var maxRes = _furthestRead;
    var atBottom = false;
    for (final p in positions) {
      // 一部でも見えている行か。
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) continue;
      final item = _items[p.index];
      if (item is Res && item.number > maxRes) maxRes = item.number;
      if (p.index == lastIndex && p.itemTrailingEdge <= 1.0001) atBottom = true;
    }
    final readAdvanced = maxRes > _furthestRead;
    if (maxRes != _furthestRead || atBottom != _atBottomNow) {
      setState(() {
        _furthestRead = maxRes;
        _atBottomNow = atBottom;
      });
    }
    if (readAdvanced) _persistReadPosition(maxRes);
  }

  void _persistReadPosition([int? resCount]) {
    final count = resCount ?? _furthestRead;
    if (count <= 0) return;
    unawaited(_history.markRead(widget.threadKey, count));
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToTopSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTop());
  }

  void _scrollToTop() {
    if (!_itemScroll.isAttached || _items.isEmpty) return;
    _itemScroll.jumpTo(index: 0, alignment: 0);
  }

  /// ファストスクロールのつまみから任意の行へ即ジャンプする。
  void _jumpToIndex(int index) {
    if (!_itemScroll.isAttached || _items.isEmpty) return;
    final clamped = index.clamp(0, _items.length - 1);
    _itemScroll.jumpTo(index: clamped, alignment: 0);
  }

  /// つまみの吹き出しに出すレス番号。境界行に当たったら近くのレスを拾う。
  String _resLabelForIndex(int index) {
    if (index < 0 || index >= _items.length) return '';
    for (var i = index; i >= 0; i--) {
      final item = _items[i];
      if (item is Res) return '${item.number}';
    }
    for (var i = index + 1; i < _items.length; i++) {
      final item = _items[i];
      if (item is Res) return '${item.number}';
    }
    return '';
  }

  /// 「最新へ」ボタン・追従で末尾へスクロールする。
  void _scrollToBottom() {
    if (!_itemScroll.isAttached || _items.isEmpty) return;
    if (_contentFitsViewport()) {
      _scrollToTop();
      return;
    }
    _itemScroll.scrollTo(
      index: _items.length - 1,
      alignment: 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  bool _contentFitsViewport() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty || _items.isEmpty) return false;
    ItemPosition? first;
    ItemPosition? last;
    for (final p in positions) {
      if (p.index == 0) first = p;
      if (p.index == _items.length - 1) last = p;
    }
    if (first == null || last == null) return false;
    return first.itemLeadingEdge >= -0.0001 && last.itemTrailingEdge <= 1.0001;
  }

  Future<void> _refresh() async {
    try {
      final previousResCount = _state.res.length;
      final r = await _dat.fetch(_url, prev: _state);
      if (!mounted) return;
      final newRes = _newResSince(r.state, previousResCount);
      if (newRes.isNotEmpty) {
        await _markPendingOwnPosts(newRes);
        if (!mounted) return;
      }
      setState(() {
        _state = r.state;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_state.isEmpty) setState(() => _error = e);
    }
  }

  Map<String, int> _idCounts(List<Res> res) {
    final counts = <String, int>{};
    for (final r in res) {
      final id = r.id;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  Map<int, int> _idOrdinals(List<Res> res) {
    final seenById = <String, int>{};
    final ordinals = <int, int>{};
    for (final r in res) {
      final id = r.id;
      if (id == null) continue;
      final ordinal = (seenById[id] ?? 0) + 1;
      seenById[id] = ordinal;
      ordinals[r.number] = ordinal;
    }
    return ordinals;
  }

  Future<void> _markPendingOwnPosts(List<Res> newRes) async {
    if (_pendingOwnPosts <= 0 || newRes.isEmpty) return;
    final count = _pendingOwnPosts < newRes.length
        ? _pendingOwnPosts
        : newRes.length;
    for (final res in newRes.skip(newRes.length - count)) {
      await _history.markOwnPost(widget.threadKey, res.number);
    }
    _pendingOwnPosts -= count;
  }

  void _showIdPosts(String id) {
    final posts = _state.res.where((r) => r.id == id).toList();
    _showPostsSheet('ID:$id  ${posts.length}レス', posts, id: id);
  }

  /// NG 設定が変わったら再描画する。以前タップで表示したレスの一時表示は解除して、
  /// 新しいルールで判定し直す。
  void _onNgChanged() {
    if (!mounted) return;
    setState(_revealedNg.clear);
  }

  /// NG ワード追加ダイアログを出し、追加されたら反映する。
  Future<void> _addNgWord() async {
    final word = await showAddNgWordDialog(context);
    if (word == null) return;
    await _ng.addWord(word);
    if (mounted) _showSnack('NGワードを追加しました');
  }

  /// テキストをクリップボードへコピーし、上部通知で知らせる。
  Future<void> _copyText(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showSnack(message);
  }

  /// このレスの全体（番号・名前・日時・ID・本文）を貼り付け向けに整形する。
  String _rawResText(Res res) {
    final name = htmlToText(res.name).trim();
    final body = htmlToText(res.body).trimRight();
    final header = StringBuffer('${res.number}: ')
      ..write(name.isEmpty ? '名無し' : name);
    final date = res.dateText.trim();
    if (date.isNotEmpty) header.write(' $date');
    if (res.id != null) header.write(' ID:${res.id}');
    return body.isEmpty ? header.toString() : '$header\n$body';
  }

  /// 必死チェッカー（kyodemo）でこの ID の投稿経路を開く。
  void _openHissi(String id) {
    _openUrl(widget.endpoints.hissi(id));
  }

  /// レスの長押しで出すアクション。対象レスの内容を上部に出し、その下に
  /// 全体コピー・本文コピー・ID コピー・必死の操作を並べる。
  void _showResActions(Res res) {
    final id = res.id;
    final idCount = _idCounts(_state.res)[id] ?? 1;
    final idOrdinal = _idOrdinals(_state.res)[res.number] ?? 1;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 対象レスの内容。長い本文はここだけスクロールする。
              Flexible(
                child: SingleChildScrollView(
                  child: PostItem(
                    res: res,
                    idCount: idCount,
                    idOrdinal: idOrdinal,
                    onTapId: null,
                    onTapUrl: _openUrl,
                    isOwn: _history.isOwnPost(widget.threadKey, res.number),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.copy_all),
                title: const Text('レス全体をコピー'),
                subtitle: const Text('番号・名前・ID・日時・本文'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copyText(_rawResText(res), 'レスをコピーしました');
                },
              ),
              ListTile(
                leading: const Icon(Icons.notes),
                title: const Text('本文をコピー'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copyText(htmlToText(res.body).trim(), '本文をコピーしました');
                },
              ),
              if (id != null) ...[
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: Text('ID:$id をコピー'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _copyText(id, 'IDをコピーしました');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.travel_explore),
                  title: const Text('必死チェッカーで開く'),
                  subtitle: const Text('kyodemo でこの ID の今日の他の書き込みを見る'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openHissi(id);
                  },
                ),
                if (_ng.isNgId(id))
                  ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text('ID:$id のNGを解除'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _ng.removeId(id);
                      _showSnack('IDのNGを解除しました');
                    },
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.block),
                    title: Text('ID:$id をNGにする'),
                    subtitle: const Text('この ID の書き込みを非表示にする'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _ng.addId(id);
                      _showSnack('IDをNGにしました');
                    },
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('NGワードを追加…'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addNgWord();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// レス番号 [number] を中心に、親レス・対象レス・返信ツリーをまとめて出す。
  void _showReplies(int number) {
    _showConversation(number);
  }

  /// このレスに返信する。コンポーザのカーソル位置に `>>N` を挿入して集中する。
  void _reply(int number) {
    if (_isStopped) return;
    final anchor = '>>$number\n';
    final sel = _composer.selection;
    final text = _composer.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, anchor);
    _composer.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + anchor.length),
    );
    _composerFocus.requestFocus();
  }

  /// レス群をボトムシートで一覧表示する（同一 ID・返信一覧で共用）。
  /// [id] を渡すと、必死チェッカー導線と ID コピーの操作行を上部に出す。
  void _showPostsSheet(String title, List<Res> posts, {String? id}) {
    final idCounts = _idCounts(_state.res);
    final idOrdinals = _idOrdinals(_state.res);
    final replyCountByNumber = replyCounts(_state.res);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => StatefulBuilder(
          builder: (context, setSheetState) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              if (id != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => _openHissi(id),
                        icon: const Icon(Icons.travel_explore, size: 18),
                        label: const Text('必死チェッカー'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyText(id, 'IDをコピーしました'),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('IDをコピー'),
                      ),
                      if (_ng.isNgId(id))
                        TextButton.icon(
                          onPressed: () {
                            _ng.removeId(id);
                            setSheetState(() {});
                            _showSnack('IDのNGを解除しました');
                          },
                          icon: const Icon(
                            Icons.check_circle_outline,
                            size: 18,
                          ),
                          label: const Text('NG解除'),
                        )
                      else
                        TextButton.icon(
                          onPressed: () {
                            _ng.addId(id);
                            setSheetState(() {});
                            _showSnack('IDをNGにしました');
                          },
                          icon: const Icon(Icons.block, size: 18),
                          label: const Text('IDをNG'),
                        ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  itemCount: posts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final post = posts[i];
                    if (_ng.matches(post) &&
                        !_revealedNg.contains(post.number)) {
                      return _NgPlaceholder(
                        number: post.number,
                        onReveal: () =>
                            setSheetState(() => _revealedNg.add(post.number)),
                        onLongPress: () => _showResActions(post),
                      );
                    }
                    return PostItem(
                      res: post,
                      idCount: idCounts[post.id] ?? 1,
                      idOrdinal: idOrdinals[post.number] ?? 1,
                      onTapId: null,
                      onTapRes: (n) {
                        Navigator.pop(context);
                        _showConversation(n);
                      },
                      onTapResRange: (numbers) {
                        Navigator.pop(context);
                        _showConversationRange(numbers);
                      },
                      onTapUrl: _openUrl,
                      replyCount: replyCountByNumber[post.number] ?? 0,
                      onTapReplies: (n) {
                        Navigator.pop(context);
                        _showConversation(n);
                      },
                      onReply: _reply,
                      onLongPress: () => _showResActions(post),
                      isOwn: _history.isOwnPost(widget.threadKey, post.number),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `>>N` タップ。参照先レスをポップアップ表示する（スクロールはしない）。
  void _showResPopup(int number) {
    _showConversation(number);
  }

  void _showConversation(int number, {int? focusNumber}) {
    _showConversationRange([number], focusNumber: focusNumber);
  }

  void _showConversationRange(List<int> numbers, {int? focusNumber}) {
    final res = _state.res;
    final centers =
        numbers.where((n) => n >= 1 && n <= res.length).toSet().toList()
          ..sort();
    if (centers.isEmpty) {
      _showSnack('レス ${numbers.first} は見つかりません');
      return;
    }
    final entries = _conversationEntries(centers);
    final idCounts = _idCounts(res);
    final idOrdinals = _idOrdinals(res);
    final replyCountByNumber = replyCounts(res);
    final title = centers.length == 1
        ? '会話 #${centers.single}'
        : '会話 #${centers.first}-${centers.last}';
    final effectiveFocusNumber =
        focusNumber != null && centers.contains(focusNumber)
        ? focusNumber
        : centers.first;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        builder: (context, controller) => _ConversationSheet(
          title: '$title  ${entries.length}件',
          entries: entries,
          scrollController: controller,
          focusNumber: effectiveFocusNumber,
          idCounts: idCounts,
          idOrdinals: idOrdinals,
          replyCountByNumber: replyCountByNumber,
          onTapId: _showIdPosts,
          onTapRes: (_, target) {
            Navigator.pop(context);
            _showConversation(target, focusNumber: target);
          },
          onTapResRange: (_, targets) {
            Navigator.pop(context);
            _showConversationRange(targets);
          },
          onTapReplies: (n) {
            Navigator.pop(context);
            _showConversation(n);
          },
          onTapUrl: _openUrl,
          onSend: _submit,
          onShowActions: _showResActions,
          isOwnPost: (n) => _history.isOwnPost(widget.threadKey, n),
          ng: _ng,
          revealedNg: _revealedNg,
          enabled: !_isStopped,
        ),
      ),
    );
  }

  List<_ConversationEntry> _conversationEntries(List<int> centerNumbers) {
    final res = _state.res;
    final byNumber = {for (final r in res) r.number: r};
    final centers = centerNumbers.toSet();
    final entries = <_ConversationEntry>[];
    final seen = <int>{};

    void add(int n, int depth) {
      final post = byNumber[n];
      if (post != null && seen.add(n)) {
        entries.add(
          _ConversationEntry(
            res: post,
            depth: depth,
            refs: _referencedNumbers(
              post,
            ).where((ref) => byNumber.containsKey(ref)).toList(),
            highlighted: centers.contains(n),
          ),
        );
      }
    }

    final centerPosts =
        centerNumbers.where((n) => byNumber.containsKey(n)).toList()..sort();
    if (centerPosts.isEmpty) return const [];

    final parents = <int>{};
    for (final n in centerPosts) {
      parents.addAll(_referencedNumbers(byNumber[n]!));
    }
    final parentNumbers =
        parents
            .where((n) => byNumber.containsKey(n) && !centers.contains(n))
            .toList()
          ..sort();
    for (final n in parentNumbers) {
      add(n, 0);
    }

    final centerDepth = parentNumbers.isEmpty ? 0 : 1;
    for (final n in centerPosts) {
      add(n, centerDepth);
    }

    void addReplies(int n, int depth) {
      for (final r in repliesTo(res, n)) {
        if (seen.add(r.number)) {
          entries.add(
            _ConversationEntry(
              res: r,
              depth: depth,
              refs: _referencedNumbers(
                r,
              ).where((ref) => byNumber.containsKey(ref)).toList(),
              highlighted: centers.contains(r.number),
            ),
          );
          addReplies(r.number, depth + 1);
        }
      }
    }

    for (final n in centerPosts) {
      addReplies(n, centerDepth + 1);
    }
    return entries;
  }

  List<int> _referencedNumbers(Res res) {
    return referencedResNumbers(res.body);
  }

  /// スレタイトルの全文を折り返して表示する（AppBar では省略されるため）。
  void _showFullTitle() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final isFavorite = _history.isFavorite(widget.threadKey);
        final metadent = widget.creatorMetadent;
        final isNgCreator = metadent != null && _ng.creators.contains(metadent);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  decodeEntities(widget.threadTitle),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isFavorite ? Icons.star : Icons.star_border,
                    color: isFavorite
                        ? Theme.of(context).colorScheme.tertiary
                        : null,
                  ),
                  title: Text(isFavorite ? 'お気に入りを解除' : 'お気に入りに追加'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _toggleFavorite();
                  },
                ),
                if (metadent != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      isNgCreator
                          ? Icons.person_outline
                          : Icons.person_off_outlined,
                    ),
                    title: Text(isNgCreator ? 'このスレ主のNGを解除' : 'このスレ主をNG'),
                    subtitle: Text(
                      isNgCreator
                          ? 'スレ主 [$metadent★] のスレを再び表示します'
                          : 'スレ主 [$metadent★] のスレを一覧から隠します',
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _toggleNgCreator(metadent);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleNgCreator(String metadent) async {
    final wasNg = _ng.creators.contains(metadent);
    if (wasNg) {
      await _ng.removeCreator(metadent);
    } else {
      await _ng.addCreator(metadent);
    }
    if (mounted) {
      _showSnack(wasNg ? 'スレ主のNGを解除しました' : 'このスレ主をNGにしました');
    }
  }

  Future<void> _toggleFavorite() async {
    await _history.rememberThread(
      ThreadSummary(
        key: widget.threadKey,
        title: widget.threadTitle,
        resCount: _state.res.length,
        capName: null,
      ),
    );
    await _history.toggleFavorite(widget.threadKey);
    if (mounted) {
      setState(() {});
      _showSnack(
        _history.isFavorite(widget.threadKey) ? 'お気に入りに追加しました' : 'お気に入りを解除しました',
      );
    }
  }

  Future<void> _openUrl(Uri url) async {
    final ok = await widget.authLauncher.open(url);
    if (!ok && mounted) _showSnack('リンクを開けませんでした');
  }

  void _handlePointerDown(PointerDownEvent event) {
    _horizontalDragDistance = 0;
    _verticalDragDistance = 0;
    // 入力欄の上で始まったドラッグはカーソル移動・文字選択なので戻る操作にしない。
    // 一覧側で始まったスワイプは入力中（キーボード表示中）でも戻れるようにする。
    _trackingSwipe = !_bodySelectionActive && !_isOnComposer(event.position);
    _swipeStartTimer?.cancel();
    if (!_trackingSwipe) return;
    _swipeStartTimer = Timer(_swipeStartTimeout, () {
      _trackingSwipe = false;
    });
  }

  /// グローバル座標 [globalPosition] が入力欄の矩形内か。
  bool _isOnComposer(Offset globalPosition) {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.contains(globalPosition);
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
    if (_bodySelectionActive) return;
    if (_horizontalDragDistance < _swipeDistanceThreshold) return;
    if (_horizontalDragDistance < _verticalDragDistance * 1.2) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _swipeStartTimer?.cancel();
    _trackingSwipe = false;
  }

  bool get _bodySelectionActive => _selectedBodyResNumbers.isNotEmpty;

  void _handleBodySelectionActiveChanged(int resNumber, bool active) {
    final changed = active
        ? _selectedBodyResNumbers.add(resNumber)
        : _selectedBodyResNumbers.remove(resNumber);
    if (!changed) return;
    setState(() {
      if (active) _trackingSwipe = false;
    });
  }

  /// スレ画面の通知は入力欄や末尾レスに重ならないよう、上部へ出す。
  void _showSnack(String message) {
    _showTopSnack(message);
  }

  void _showTopSnack(String message) {
    _topSnackTimer?.cancel();
    _topSnackEntry?.remove();
    final overlay = Overlay.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    _topSnackEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 12,
        left: 12,
        right: 12,
        child: IgnorePointer(
          child: Material(
            color: scheme.inverseSurface,
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onInverseSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_topSnackEntry!);
    _topSnackTimer = Timer(const Duration(seconds: 2), () {
      _topSnackEntry?.remove();
      _topSnackEntry = null;
    });
  }

  // ---- 書き込み ----

  /// 1 回だけ POST し、トークンを更新して結果を返す（UI 副作用なし）。
  Future<BbsCgiResult> _postOnce(String text) async {
    final fetcher = _fetcher;
    if (fetcher is! HttpPoster) {
      return const PostRejected(
        errorCode: 'Unsupported',
        message: 'この環境では書き込みに未対応です',
      );
    }
    // HttpPoster は HttpFetcher の部分型ではないので明示キャストが要る。
    final result = await BbsWriter(fetcher as HttpPoster).post(
      bbsCgi: widget.endpoints.bbsCgi,
      board: widget.endpoints.boardKey,
      threadKey: widget.threadKey,
      message: text,
      tokens: _authStore.tokens,
    );
    await _authStore.setTokens(result.tokens); // edge/tinker を持ち回して永続化
    return result.outcome;
  }

  /// コンポーザから呼ばれる送信。受理されたら true（コンポーザが入力を消す）。
  Future<bool> _submit(String text) async {
    final accepted = await submitWithAuth(
      context: context,
      launcher: widget.authLauncher,
      postOnce: () => _postOnce(text),
      onRejected: _showSnack,
    );
    if (accepted && mounted) {
      _pendingOwnPosts++;
      _showSnack('書き込みました');
      _pollAfterPost(); // 自分の書き込みをすぐ反映
    }
    return accepted;
  }

  void _pollAfterPost() {
    _postRefreshTimer?.cancel();
    unawaited(_runPostRefreshAttempt(0));
  }

  Future<void> _runPostRefreshAttempt(int attempt) async {
    if (!mounted || _pendingOwnPosts <= 0 || attempt >= _postRefreshAttempts) {
      return;
    }
    await _poll(force: true);
    if (!mounted ||
        _pendingOwnPosts <= 0 ||
        attempt + 1 >= _postRefreshAttempts) {
      return;
    }
    _postRefreshTimer = Timer(
      _postRefreshRetryDelay,
      () => unawaited(_runPostRefreshAttempt(attempt + 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 80,
        // タイトルは重要なので AppBar 内でできるだけ読ませる。極端に長い場合は
        // これまで通りタップで全文を出す。
        title: InkWell(
          onTap: _showFullTitle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  decodeEntities(widget.threadTitle),
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.22,
                  ),
                ),
                if (!_loading && _error == null)
                  Text(
                    _statusLabel == null
                        ? '${_state.res.length}レス'
                        : '${_state.res.length}レス ・ $_statusLabel',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        bottom: _polling
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Column(
          children: [
            Expanded(child: _body()),
            _Composer(
              key: _composerKey,
              controller: _composer,
              focusNode: _composerFocus,
              onSend: _submit,
              enabled: !_isStopped,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_state.isEmpty && _error != null) {
      return _ErrorView(error: _error!, onRetry: _refresh);
    }

    final res = _state.res;
    final idCounts = _idCounts(res);
    final idOrdinals = _idOrdinals(res);
    final replies = replyCounts(res);
    // 「新着」の境界（前回位置）。0 か総数以上なら新着ライン無し。
    final hasNewArrival = _openCount > 0 && _openCount < res.length;

    // 行データを組む（Res か 新着ライン）。インデックス指定スクロールのため
    // Widget ではなくデータで持ち、[_items] に保存する。
    final items = <Object>[];
    for (var i = 0; i < res.length; i++) {
      if (hasNewArrival && i == _openCount) {
        items.add(const _NewArrivalMarker());
      }
      items.add(res[i]);
    }
    _items = items;

    // 未読（まだスクロールで到達していない）レス数。スクロールで減る。
    final unread = res.length - _furthestRead;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _refresh,
          child: ScrollablePositionedList.builder(
            itemScrollController: _itemScroll,
            itemPositionsListener: _positions,
            initialScrollIndex: _initialIndex,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item is! Res) return const _NewArrivalLine();
              final ngHidden =
                  _ng.matches(item) && !_revealedNg.contains(item.number);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (ngHidden)
                    _NgPlaceholder(
                      number: item.number,
                      onReveal: () =>
                          setState(() => _revealedNg.add(item.number)),
                      onLongPress: () => _showResActions(item),
                    )
                  else
                    PostItem(
                      res: item,
                      idCount: idCounts[item.id] ?? 1,
                      idOrdinal: idOrdinals[item.number] ?? 1,
                      onTapId: _showIdPosts,
                      onTapRes: _showResPopup,
                      onTapResRange: _showConversationRange,
                      onTapUrl: _openUrl,
                      replyCount: replies[item.number] ?? 0,
                      onTapReplies: _showReplies,
                      onReply: _reply,
                      onBodySelectionActiveChanged: (active) =>
                          _handleBodySelectionActiveChanged(
                            item.number,
                            active,
                          ),
                      onLongPress: () => _showResActions(item),
                      isOwn: _history.isOwnPost(widget.threadKey, item.number),
                    ),
                  const Divider(height: 1),
                ],
              );
            },
          ),
        ),
        // 長いスレでは右端のつまみで一気に移動できるようにする。
        if (items.length > 30)
          Positioned(
            top: 8,
            right: 0,
            bottom: 8,
            child: _FastScroller(
              positions: _positions,
              itemCount: items.length,
              onJump: _jumpToIndex,
              labelForIndex: _resLabelForIndex,
            ),
          ),
        if (!_atBottom)
          Positioned(
            right: 12,
            bottom: 12,
            child: _JumpToLatestButton(
              unread: unread > 0 ? unread : 0,
              onTap: _scrollToBottom,
            ),
          ),
      ],
    );
  }
}

/// 右端のファストスクロール用つまみ。長いスレで一気に距離を移動できる。
///
/// [ScrollablePositionedList] はピクセル位置を持たないため、つまみの縦位置を
/// 「見えている先頭行のインデックス / 全行数」に対応させ、ドラッグ量に応じて
/// 目的の行へ [ItemScrollController.jumpTo] する。
class _FastScroller extends StatefulWidget {
  const _FastScroller({
    required this.positions,
    required this.itemCount,
    required this.onJump,
    required this.labelForIndex,
  });

  final ItemPositionsListener positions;
  final int itemCount;
  final void Function(int index) onJump;
  final String Function(int index) labelForIndex;

  @override
  State<_FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<_FastScroller> {
  static const double _handleHeight = 52;
  static const double _handleWidth = 30;
  bool _dragging = false;
  double _fraction = 0;

  /// 見えている先頭行から現在位置（0〜1）を求める。
  double _currentFraction() {
    final positions = widget.positions.itemPositions.value;
    if (positions.isEmpty || widget.itemCount <= 1) return 0;
    var topIndex = widget.itemCount;
    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && p.index < topIndex) topIndex = p.index;
    }
    if (topIndex >= widget.itemCount) return 0;
    return (topIndex / (widget.itemCount - 1)).clamp(0.0, 1.0);
  }

  int _indexFor(double fraction) =>
      (fraction * (widget.itemCount - 1)).round();

  /// トラック内のローカル Y から位置を決め、その行へジャンプする。つまみ中心が
  /// 指の位置に来るよう `_handleHeight / 2` を引く。
  void _applyLocalY(double localY, double travel) {
    final fraction = travel <= 0
        ? 0.0
        : ((localY - _handleHeight / 2) / travel).clamp(0.0, 1.0);
    setState(() => _fraction = fraction);
    widget.onJump(_indexFor(fraction));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _handleWidth,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final travel = constraints.maxHeight - _handleHeight;
          // ジェスチャ領域はトラック全体で固定。つまみが動いても指の下から
          // 外れないので、最初の押下からそのままドラッグできる。
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragDown: (d) {
              setState(() => _dragging = true);
              _applyLocalY(d.localPosition.dy, travel);
            },
            onVerticalDragUpdate: (d) =>
                _applyLocalY(d.localPosition.dy, travel),
            onVerticalDragEnd: (_) => setState(() => _dragging = false),
            onVerticalDragCancel: () => setState(() => _dragging = false),
            child: ValueListenableBuilder<Iterable<ItemPosition>>(
              valueListenable: widget.positions.itemPositions,
              builder: (context, _, _) {
                final fraction = _dragging ? _fraction : _currentFraction();
                final top = travel <= 0 ? 0.0 : fraction * travel;
                return Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    // ドラッグ中はつまみの左にレス番号の吹き出しを出す。
                    if (_dragging)
                      Positioned(
                        right: _handleWidth + 8,
                        top: top + (_handleHeight - 32) / 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.inverseSurface,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            widget.labelForIndex(_indexFor(_fraction)),
                            style: TextStyle(
                              color: scheme.onInverseSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 0,
                      top: top,
                      child: IgnorePointer(
                        child: Container(
                          width: _handleWidth,
                          height: _handleHeight,
                          decoration: BoxDecoration(
                            color: _dragging
                                ? scheme.primary
                                : scheme.secondaryContainer.withValues(
                                    alpha: 0.92,
                                  ),
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(15),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.unfold_more,
                            size: 20,
                            color: _dragging
                                ? scheme.onPrimary
                                : scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// 末尾を見ていないときに出す「最新へ」ボタン。未読件数（スクロールで未到達
/// のレス数）を出す。
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.unread, required this.onTap});
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 16, color: scheme.onPrimary),
              const SizedBox(width: 6),
              Text(
                unread > 0 ? '未読 $unread' : '最新へ',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// NG 判定されたレスの代わりに出す薄い行。タップで一時表示、長押しでメニュー
/// （ID の NG 解除など）を出す。
class _NgPlaceholder extends StatelessWidget {
  const _NgPlaceholder({
    required this.number,
    required this.onReveal,
    required this.onLongPress,
  });
  final int number;
  final VoidCallback onReveal;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onReveal,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text(
              '$number',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.block, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'NG（タップで表示）',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新着レスの直前に入る区切り。
/// 行データ用の新着境界マーカー（[Res] と区別するためのセンチネル）。
class _NewArrivalMarker {
  const _NewArrivalMarker();
}

class _NewArrivalLine extends StatelessWidget {
  const _NewArrivalLine();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: color, thickness: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'ここから新着',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Divider(color: color, thickness: 1)),
        ],
      ),
    );
  }
}

class _ConversationEntry {
  const _ConversationEntry({
    required this.res,
    required this.depth,
    required this.refs,
    required this.highlighted,
  });
  final Res res;
  final int depth;
  final List<int> refs;
  final bool highlighted;
}

class _ConversationSheet extends StatefulWidget {
  const _ConversationSheet({
    required this.title,
    required this.entries,
    required this.scrollController,
    required this.focusNumber,
    required this.idCounts,
    required this.idOrdinals,
    required this.replyCountByNumber,
    required this.onTapId,
    required this.onTapRes,
    required this.onTapResRange,
    required this.onTapReplies,
    required this.onTapUrl,
    required this.onSend,
    required this.onShowActions,
    required this.isOwnPost,
    required this.ng,
    required this.revealedNg,
    required this.enabled,
  });

  final String title;
  final List<_ConversationEntry> entries;
  final ScrollController scrollController;
  final int? focusNumber;
  final Map<String, int> idCounts;
  final Map<int, int> idOrdinals;
  final Map<int, int> replyCountByNumber;
  final ValueChanged<String> onTapId;
  final void Function(int source, int target) onTapRes;
  final void Function(int source, List<int> targets) onTapResRange;
  final ValueChanged<int> onTapReplies;
  final ValueChanged<Uri> onTapUrl;

  /// 会話シート内の入力欄から直接送信する投稿関数（受理で true）。
  final Future<bool> Function(String) onSend;

  /// レス長押しでアクションメニューを出す。
  final ValueChanged<Res> onShowActions;
  final bool Function(int number) isOwnPost;

  /// NG 判定に使う設定と、タップで一時表示にしたレス番号の集合（画面と共有）。
  final NgStore ng;
  final Set<int> revealedNg;

  /// 入力欄を有効にするか（停止スレでは false）。
  final bool enabled;

  @override
  State<_ConversationSheet> createState() => _ConversationSheetState();
}

class _ConversationSheetState extends State<_ConversationSheet> {
  late final Map<int, GlobalKey> _keys;
  // 会話シート専用の入力欄（main の入力欄はシートに覆われて見えないため）。
  // 返信アイコンを押したときだけ出す（常時表示だと「会話全体への返信」と誤解
  // されうるため）。
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _replying = false;

  @override
  void initState() {
    super.initState();
    _keys = {for (final entry in widget.entries) entry.res.number: GlobalKey()};
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// レスの返信ボタンで呼ばれる。入力欄を出して `>>N` を挿入・フォーカスする。
  void _replyLocal(int number) {
    final anchor = '>>$number\n';
    final sel = _controller.selection;
    final text = _controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _controller.value = TextEditingValue(
      text: text.replaceRange(start, end, anchor),
      selection: TextSelection.collapsed(offset: start + anchor.length),
    );
    setState(() => _replying = true);
    _focus.requestFocus();
  }

  /// 送信。受理されたら入力欄を閉じる。
  Future<bool> _handleSend(String text) async {
    final accepted = await widget.onSend(text);
    if (accepted && mounted) setState(() => _replying = false);
    return accepted;
  }

  /// 入力欄を閉じ、下書きを破棄する。
  void _cancelReply() {
    _controller.clear();
    _focus.unfocus();
    setState(() => _replying = false);
  }

  void _scrollToFocus() {
    if (!mounted) return;
    final focusNumber = widget.focusNumber;
    if (focusNumber == null) return;
    final context = _keys[focusNumber]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, alignment: 0.18, duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            children: [
              for (var i = 0; i < widget.entries.length; i++)
                Builder(
                  builder: (context) {
                    final entry = widget.entries[i];
                    final ngHidden =
                        widget.ng.matches(entry.res) &&
                        !widget.revealedNg.contains(entry.res.number);
                    return KeyedSubtree(
                      key: _keys[entry.res.number],
                      child: _ConversationPost(
                        highlighted: entry.highlighted,
                        depth: entry.depth,
                        refs: entry.refs,
                        showDivider: i < widget.entries.length - 1,
                        child: ngHidden
                            ? _NgPlaceholder(
                                number: entry.res.number,
                                onReveal: () => setState(
                                  () => widget.revealedNg.add(entry.res.number),
                                ),
                                onLongPress: () =>
                                    widget.onShowActions(entry.res),
                              )
                            : PostItem(
                                res: entry.res,
                                idCount: widget.idCounts[entry.res.id] ?? 1,
                                idOrdinal:
                                    widget.idOrdinals[entry.res.number] ?? 1,
                                onTapId: widget.onTapId,
                                onTapRes: (n) =>
                                    widget.onTapRes(entry.res.number, n),
                                onTapResRange: (numbers) => widget
                                    .onTapResRange(entry.res.number, numbers),
                                onTapUrl: widget.onTapUrl,
                                replyCount:
                                    widget.replyCountByNumber[entry
                                        .res
                                        .number] ??
                                    0,
                                onTapReplies: widget.onTapReplies,
                                onReply: _replyLocal,
                                onLongPress: () =>
                                    widget.onShowActions(entry.res),
                                isOwn: widget.isOwnPost(entry.res.number),
                              ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        // 返信アイコンを押したときだけ入力欄を出す（対象は本文の >>N で明示）。
        // キーボード分だけ持ち上げる。
        if (_replying)
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(height: 1),
                _ReplyBar(onClose: _cancelReply),
                _Composer(
                  controller: _controller,
                  focusNode: _focus,
                  onSend: _handleSend,
                  enabled: widget.enabled,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ConversationPost extends StatelessWidget {
  const _ConversationPost({
    required this.child,
    required this.depth,
    required this.refs,
    required this.highlighted,
    required this.showDivider,
  });
  final Widget child;
  final int depth;
  final List<int> refs;
  final bool highlighted;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indent = depth * 18.0;
    return Container(
      decoration: BoxDecoration(
        color: highlighted
            ? scheme.primaryContainer.withValues(alpha: 0.18)
            : Colors.transparent,
        border: highlighted
            ? Border(left: BorderSide(color: scheme.primary, width: 4))
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.only(left: indent),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: depth > 0
                ? Border(
                    left: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.8),
                      width: 2,
                    ),
                  )
                : null,
          ),
          child: Padding(
            padding: EdgeInsets.only(left: depth > 0 ? 8 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (refs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '返信先 ${refs.map((n) => '>>$n').join(' ')}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                child,
                if (showDivider)
                  Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.65),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 会話シートの返信入力欄の上に出す見出し。返信対象は本文の `>>N` で示す。
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 0),
      child: Row(
        children: [
          Icon(Icons.reply, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '返信（>>で対象を指定）',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: '閉じる',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.enabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 送信。受理されたら true を返す（入力欄をクリアする）。
  final Future<bool> Function(String) onSend;
  final bool enabled;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _sending = false;

  Future<void> _send() async {
    final text = widget.controller.text;
    if (!widget.enabled || text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final accepted = await widget.onSend(text);
      if (accepted) widget.controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                enabled: widget.enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: widget.enabled ? 'レスを書く' : '書き込み停止中',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  // isDense で余分な最小高さを外し、1 行時の高さを送信ボタン
                  // （44）に合わせる。
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 送信ボタンは 1 行時の入力欄と同じ高さ（44）に固定。複数行に伸びた
            // ら crossAxisAlignment.end で下端に留まる。
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton.filled(
                padding: EdgeInsets.zero,
                onPressed: !widget.enabled || _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 20),
              ),
            ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('読み込みに失敗しました'),
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
      ),
    );
  }
}
