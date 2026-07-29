import 'dart:async';
import 'dart:math' as math;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../net/auth_launcher.dart';
import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/file_upload_settings.dart';
import '../net/image_upload_settings.dart';
import '../net/http_fetcher.dart';
import '../net/imgur_uploader.dart';
import '../net/ng_store.dart';
import '../net/read_history.dart';
import 'attachment_uploader.dart';
import 'compose_style.dart';
import 'back_swipe.dart';
import 'embed_urls.dart';
import 'image_urls.dart';
import 'ng_screen.dart';
import 'post_images.dart';
import 'post_item.dart';
import 'reply_tier.dart';
import 'thread_map.dart';
import 'video_player_screen.dart';
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
    this.imagePicker,
    this.imgurUploader,
    this.imageUploadSettings,
    this.fileUploadSettings,
    this.pickAndUploadImage,
    this.pickAndUploadFile,
    this.initialStatusLabel,
    this.initialResCount = 0,
    this.creatorMetadent,
    this.defaultName,
    this.active = true,
    this.onClose,
  });

  final String threadKey;
  final String threadTitle;

  /// この画面が今表示されているか。
  ///
  /// スレ画面は、閉じずに表示だけ外れることがある（一覧の裏に控えて、また開く
  /// ときに取得済みの本文とスクロール位置をそのまま使うため）。控えている間は
  /// 更新を止めて既読位置を保存し、表に戻ったら開き直したときと同じ状態
  /// （新着ラインと再開位置）を作り直す。
  ///
  /// 画面ごと閉じる（unmount する）場合はここを触る必要はない。
  final bool active;

  /// 「戻る」の受け取り先。
  ///
  /// 一覧の中に置かれているとき（ルートとして開かれていないとき）に、AppBar の
  /// 戻るボタンをここへ回す。null ならルートを閉じる既定の動きになる。
  final VoidCallback? onClose;
  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;
  final Duration pollInterval;
  final int initialResCount;

  /// スレ立て人の metadent（`subject-metadent.txt` 由来）。一覧から開いた場合に
  /// 渡され、スレタイのメニューから「このスレ主を NG」できるようにする。
  /// 直接キーで開いた等で不明なら null。
  final String? creatorMetadent;

  /// 板の既定の名前（`BBS_NONAME_NAME`）。名無しのレスから名前を省くのに使う。
  /// 詳細は [PostItem.defaultName]。板の設定が未取得なら null。
  final String? defaultName;

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

  /// 端末画像の選択。テストでは差し替え可能。
  final ImagePicker? imagePicker;

  /// Imgur アップロード実装。未指定なら `IMGUR_CLIENT_ID` から作る。
  final ImgurUploader? imgurUploader;

  /// 画像アップロード先の利用者設定。
  final ImageUploadSettings? imageUploadSettings;

  /// 任意ファイルのアップロード先の利用者設定。
  final FileUploadSettings? fileUploadSettings;

  /// 画像選択からアップロードまでを丸ごと差し替えるためのフック。
  final Future<Uri?> Function()? pickAndUploadImage;

  /// ファイル選択からアップロードまでを丸ごと差し替えるためのフック。
  final Future<Uri?> Function()? pickAndUploadFile;

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
  late final ImagePicker _imagePicker;
  late final ImgurUploader _imgurUploader;
  late final ImageUploadSettings _imageUploadSettings;
  late final FileUploadSettings _fileUploadSettings;
  late final AttachmentUploader _uploader;

  /// NG 判定されたが、タップで一時的に表示したレス番号。
  final _revealedNg = <int>{};
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _composerKey = GlobalKey();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

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
  bool _searching = false;
  int _currentSearchIndex = 0;

  /// dat も過去ログも見つからなかった（完全に消えた）スレか。
  bool _notFound = false;

  /// 書き込み中に止まったことを知らせ済みか。一度止まったスレは戻らないので、
  /// 知らせるのも一度きりにする。
  bool _stoppedNoticeShown = false;

  /// スクロールで実際に見えた最大レス番号（＝どこまで読んだか）。可視性で
  /// 追跡する。これより後ろのレスが「未読」で、「最新へ」の件数の基準になる。
  int _furthestRead = 0;

  /// 一度でも取得を始めたか。控えのまま一度も表に出ていない画面は false。
  bool _loadStarted = false;

  /// スレを開いた時点のレス数。これを超える番号が「新着（今回開いてから増えた
  /// 分）」で、新着ラインの境界になる。スクロールでは動かない。
  int _openCount = 0;

  Timer? _timer;
  Timer? _postRefreshTimer;
  Timer? _topSnackTimer;
  OverlayEntry? _topSnackEntry;
  bool _fetching = false;
  int _pendingOwnPosts = 0;

  /// 書き込み直後、自分のレスが一覧に現れるのを待って再取得を回している間 true。
  /// 番号が取れる場合（[PostAccepted.resNum]）は [_pendingOwnPosts] を使わないので、
  /// 再取得ループの継続はこのフラグで判断する。
  bool _awaitingOwnPost = false;
  final _selectedBodyResNumbers = <int>{};
  static const int _postRefreshAttempts = 4;
  static const Duration _postRefreshRetryDelay = Duration(milliseconds: 700);

  Uri get _url => widget.endpoints.dat(widget.threadKey);

  /// 表示・履歴に使うスレタイトル。呼び出し側からタイトルを渡されていればそれを、
  /// （スレリンクからの遷移など）空なら開いた dat の 1 レス目から補完する。
  String get _effectiveTitle => widget.threadTitle.isNotEmpty
      ? widget.threadTitle
      : (_state.threadTitle ?? '');

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _dat = DatFetcher(
      _fetcher,
      encoding: widget.endpoints.textEncoding,
      format: widget.endpoints.datFormat,
    );
    _authStore = widget.authStore ?? AuthStore.shared;
    _history = widget.readHistory ?? ReadHistory.shared;
    _ng = widget.ngStore ?? NgStore.shared;
    _imagePicker = widget.imagePicker ?? ImagePicker();
    _imgurUploader =
        widget.imgurUploader ??
        const ImgurUploader(
          clientId: String.fromEnvironment('IMGUR_CLIENT_ID'),
        );
    _imageUploadSettings =
        widget.imageUploadSettings ?? ImageUploadSettings.shared;
    _fileUploadSettings =
        widget.fileUploadSettings ?? FileUploadSettings.shared;
    _uploader = AttachmentUploader(
      imagePicker: _imagePicker,
      imgurUploader: _imgurUploader,
      imageUploadSettings: _imageUploadSettings,
      fileUploadSettings: _fileUploadSettings,
    );
    _ng.addListener(_onNgChanged);
    _positions.itemPositions.addListener(_onPositions);
    WidgetsBinding.instance.addObserver(this);
    // 控えとして置かれただけ（まだ表に出ていない）なら、表に出るまで何もしない。
    // 一覧の裏で無駄に取得・更新しないため。
    if (widget.active) _open();
  }

  /// 初めて表に出たとき。履歴に残し、本文を取ってポーリングを始める。
  void _open() {
    _loadStarted = true;
    _markOpened();
    _initialLoad();
    _startPolling();
  }

  @override
  void didUpdateWidget(ThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 一覧のポーリングが「subject.txt から消えた」と気づいた＝ dat落ち。dat 本体は
    // しばらく 200 を返し続けるので（eddist は archive まで現行 URL のまま）、
    // この経路でしか分からない止まり方がある。
    if (widget.initialStatusLabel != oldWidget.initialStatusLabel) {
      _notifyStoppedWhileComposing(_canWriteWith(oldWidget.initialStatusLabel));
    }
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _enter();
    } else {
      _leave();
    }
  }

  /// 表に戻ったとき。開き直したときと同じ状態にする。
  ///
  /// 本文は控えている間のものが残っているので、読み込み中は出さずにそのまま
  /// 見せ、裏で取り直してから新着ラインと再開位置を貼り直す。
  void _enter() {
    // 控えのまま一度も表に出ていなければ、ここが初回。
    if (!_loadStarted) {
      _open();
      return;
    }
    _markOpened();
    _startPolling();
    unawaited(_reload());
  }

  /// 表示から外れたとき。閉じたときと同じだけの後始末をする。
  void _leave() {
    _timer?.cancel();
    _persistReadPosition();
    // 見えていない画面が入力を持ったままだとキーボードが残るので手放す。
    if (_composerFocus.hasFocus) _composerFocus.unfocus();
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
  }

  void _markOpened() {
    unawaited(
      _history.markOpenedThread(
        ThreadSummary(
          key: widget.threadKey,
          title: _effectiveTitle,
          resCount: _state.res.isNotEmpty
              ? _state.res.length
              : widget.initialResCount,
          capName: null,
        ),
      ),
    );
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
    _topSnackTimer?.cancel();
    _topSnackEntry?.remove();
    _composer.dispose();
    _composerFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
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

  String? get _statusLabel => _statusLabelWith(widget.initialStatusLabel);

  /// 一覧から引き継いだラベルを [inherited] としたときの表示ラベル。
  /// 一覧のポーリングでラベルが変わる前後を比べるため、引数で受ける。
  String? _statusLabelWith(String? inherited) {
    // 過去ログ（dat落ち）は取得して初めて分かる。完走判定より優先して示す。
    if (_state.pastLog) return 'dat落ち';
    if (inherited != null) return inherited;
    if (_state.res.length >= 1000 ||
        _state.res.any((r) => r.kind == ResKind.over1000)) {
      return '完走';
    }
    return null;
  }

  bool get _isStopped => _statusLabel != null;

  /// 書き込み可能か。停止スレ（dat落ち・完走）でなく、かつ板が書き込みに対応
  /// している（現状 eddist のみ。5ch 書き込みは Phase 2）こと。
  bool get _canWrite => _canWriteWith(widget.initialStatusLabel);

  bool _canWriteWith(String? inherited) =>
      _statusLabelWith(inherited) == null && widget.endpoints.supportsWrite;

  Future<void> _initialLoad() async {
    try {
      final r = await _dat.fetch(_url);
      if (!mounted) return;
      if (r.status == DatFetchStatus.notFound && r.state.res.isEmpty) {
        // dat も過去ログ（kako）も無い。スレが完全に消えている。
        setState(() {
          _notFound = true;
          _loading = false;
          _error = null;
        });
        return;
      }
      final total = r.state.res.length;
      // タイトルを呼び出し側指定 or dat の 1 レス目から確定させる。スレリンクから
      // 開いた場合はここで初めてタイトルが分かるので、履歴にも入れ直す。
      final title = widget.threadTitle.isNotEmpty
          ? widget.threadTitle
          : (r.state.threadTitle ?? '');
      if (widget.threadTitle.isEmpty && title.isNotEmpty) {
        await _history.markOpenedThread(
          ThreadSummary(
            key: widget.threadKey,
            title: title,
            resCount: total,
            capName: null,
          ),
        );
        if (!mounted) return;
      }
      await _history.markLastViewedThread(
        ThreadSummary(
          key: widget.threadKey,
          title: title,
          resCount: total,
          capName: null,
        ),
      );
      if (!mounted) return;
      final lastSeen = _history.lastSeen(widget.threadKey);
      final entry = _entryPositions(total, lastSeen);
      setState(() {
        _state = r.state;
        _openCount = entry.openCount;
        _furthestRead = lastSeen ?? 0;
        _initialIndex = entry.initialIndex;
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

  /// 全 [total] レスのスレを開いたときの、新着境界（ここから下が新着）と
  /// 着地位置。[lastSeen] は前回どこまで見たか（未読なら null）。
  ///
  /// - 未読（初回）: 先頭から（インデックス 0）。新着ライン無し。
  /// - 既読＆新着あり: 前回位置に新着ラインを置き、そこへ合わせる。
  /// - 既読＆新着なし: 末尾（続き）へ。
  ///
  /// 新着ラインの少し手前に着地させて、直前の流れを思い出せるようにする。
  ({int openCount, int initialIndex}) _entryPositions(
    int total,
    int? lastSeen,
  ) {
    const overlap = 3;
    if (lastSeen == null) return (openCount: total, initialIndex: 0);
    if (lastSeen < total) {
      // 新着ラインの行位置は items 上で lastSeen。数レス手前に寄せる。
      return (
        openCount: lastSeen,
        initialIndex: lastSeen - overlap < 0 ? 0 : lastSeen - overlap,
      );
    }
    return (openCount: total, initialIndex: total > 0 ? total - 1 : 0);
  }

  /// 控えていた画面が表に戻ったときの取り直し。
  ///
  /// 本文は残っているので読み込み表示は出さず、取り直せた時点で新着ラインだけ
  /// 貼り直す。
  ///
  /// **読んでいた位置は動かさない**。控えに回すのは「閉じた」ではなく「離れた」
  /// なので、戻ったときは離れた場所がそのまま見えているのが自然なため。控えて
  /// いる間に増えたレスは、その下に新着ラインを挟んで続く。
  Future<void> _reload() async {
    if (_loading) return; // 初回取得の途中ならそちらに任せる
    await _poll(force: true);
    if (!mounted) return;
    final lastSeen = _history.lastSeen(widget.threadKey);
    setState(() {
      _openCount = _entryPositions(_state.res.length, lastSeen).openCount;
      _furthestRead = lastSeen ?? _furthestRead;
    });
  }

  Future<void> _poll({bool force = false}) async {
    // dat落ち（過去ログ）は伸びないのでポーリングしない。
    if (_state.pastLog || _notFound) return;
    if (_fetching || !mounted) return;
    _fetching = true;
    setState(() => _polling = true);
    try {
      final wasAtBottom = _atBottom;
      final wasShortContent = _contentFitsViewport();
      final previousResCount = _state.res.length;
      final wasWritable = _canWrite;
      final r = await _dat.fetch(_url, prev: force ? DatState.empty : _state);
      if (!mounted) return;
      // 閲覧中に dat落ちした（過去ログへ飛ばされた）。停止扱いへ切り替える。
      if (r.state.pastLog && !_state.pastLog) {
        setState(() => _state = r.state);
        _notifyStoppedWhileComposing(wasWritable);
        return;
      }
      final newRes = _newResSince(r.state, previousResCount);
      if (newRes.isNotEmpty) {
        await _markPendingOwnPosts(newRes);
        _awaitingOwnPost = false; // 自分のレスが現れたので再取得ループを止める
        if (!mounted) return;
        setState(() => _state = r.state);
        // 1000 に達して完走した場合も、dat落ちと同じく書けなくなる。
        _notifyStoppedWhileComposing(wasWritable);
        if (_searching) return;
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

  /// 書いている最中にスレが止まった（dat落ち・完走）ことを知らせる。
  ///
  /// [wasWritable] は変化前の書き込み可否。可 → 不可へ変わったときだけ出す。
  /// 入力欄は黙って無効になるだけなので、書きかけを抱えたまま送れなくなった
  /// 理由が分からない。書いている人にだけモーダルで割り込み、本文を手元に
  /// 残せるようにする。空欄のまま眺めているだけなら題名の脇のラベルで足りる
  /// ので邪魔をしない。
  void _notifyStoppedWhileComposing(bool wasWritable) {
    if (!wasWritable || _canWrite || _stoppedNoticeShown) return;
    final draft = _composer.text;
    if (draft.trim().isEmpty && !_composerFocus.hasFocus) return;
    _stoppedNoticeShown = true;
    final label = _statusLabel ?? 'dat落ち';
    // 一覧の更新から来たときは build の途中なので、フレームを跨いでから出す。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 送れない欄にキーボードを出したままにしない。
      if (_composerFocus.hasFocus) _composerFocus.unfocus();
      unawaited(
        showThreadStoppedDialog(context, statusLabel: label, draft: draft),
      );
    });
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
      final keepSearchFocus = _searching && _searchFocus.hasFocus;
      final previousResCount = _state.res.length;
      final r = await _dat.fetch(_url, prev: _state);
      if (!mounted) return;
      final newRes = _newResSince(r.state, previousResCount);
      if (newRes.isNotEmpty) {
        await _markPendingOwnPosts(newRes);
        _awaitingOwnPost = false;
        if (!mounted) return;
      }
      setState(() {
        _state = r.state;
        _loading = false;
        _error = null;
      });
      _restoreSearchFocusSoon(keepSearchFocus);
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

  List<Res> get _searchMatches {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return _state.res.where((res) => _searchText(res).contains(query)).toList();
  }

  // レス番号ごとの検索用テキスト（小文字化済み）。dat は追記のみで既存レスは
  // 不変なので番号でキャッシュしてよい。毎打鍵・毎ポーリングで htmlToText を
  // 全レスに掛け直すと長いスレでカクついて入力が落ちるため。
  final _searchTextCache = <int, String>{};

  String _searchText(Res res) {
    return _searchTextCache.putIfAbsent(
      res.number,
      () => [
        '${res.number}',
        htmlToText(res.name),
        res.dateText,
        if (res.id != null) 'ID:${res.id}',
        htmlToText(res.body),
      ].join('\n').toLowerCase(),
    );
  }

  void _startSearch() {
    setState(() {
      _searching = true;
      _currentSearchIndex = 0;
    });
    _restoreSearchFocusSoon(true);
  }

  void _restoreSearchFocusSoon(bool shouldRestore) {
    if (!shouldRestore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searching || _searchFocus.hasFocus) return;
      // IME 変換中に requestFocus すると入力連携が張り直され、変換中の文字が
      // 消える。確定前は触らない。
      if (_searchController.value.composing.isValid) return;
      _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _currentSearchIndex = 0;
      _searchController.clear();
    });
    _searchFocus.unfocus();
  }

  void _onSearchChanged(String value) {
    setState(() => _currentSearchIndex = 0);
    // IME 変換確定前はスクロールを走らせない。変換中に list を scrollTo すると
    // 入力の妨げになり、確定前の文字が落ちることがある。
    if (_searchController.value.composing.isValid) return;
    if (value.trim().isNotEmpty) _jumpToCurrentSearchMatch();
  }

  void _moveSearchResult(int delta) {
    final matches = _searchMatches;
    if (matches.isEmpty) return;
    setState(() {
      _currentSearchIndex =
          (_currentSearchIndex + delta + matches.length) % matches.length;
    });
    _jumpToCurrentSearchMatch();
  }

  void _jumpToCurrentSearchMatch() {
    final matches = _searchMatches;
    if (matches.isEmpty) return;
    final matchIndex = math.min(_currentSearchIndex, matches.length - 1);
    final index = _indexForResNumber(matches[matchIndex].number);
    if (index == null || !_itemScroll.isAttached) return;
    _itemScroll.scrollTo(
      index: index,
      alignment: 0.12,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  int? _indexForResNumber(int number) {
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item is Res && item.number == number) return i;
    }
    return null;
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
    _markerKindCache.clear(); // あぼーん判定が変わるのでスレマップも組み直す
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

  Uri get _threadUrl => widget.endpoints.thread(widget.threadKey);

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
    final replyCount = replyCounts(_state.res)[res.number] ?? 0;
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
                    onTapRes: (n) {
                      Navigator.pop(sheetContext);
                      _showConversation(n, focusNumber: n);
                    },
                    onTapResRange: (numbers) {
                      Navigator.pop(sheetContext);
                      _showConversationRange(numbers);
                    },
                    onTapUrl: _openUrl,
                    isOwn: _history.isOwnPost(widget.threadKey, res.number),
                    isReplyToOwn: _isReplyToOwnPost(res),
                    blurImages: guroMaskedResNumbers(
                      _state.res,
                    ).contains(res.number),
                    defaultName: widget.defaultName,
                  ),
                ),
              ),
              const Divider(height: 1),
              // 番号横の吹き出しは小さいので、押し外してこのメニューが開いた
              // ときでも同じ返信一覧へ入れるようにしておく。
              if (replyCount > 0)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text('返信 $replyCount 件を見る'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showReplies(res.number);
                  },
                ),
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
                // 必死チェッカーはエッヂ（kyodemo に対応板がある）だけ。
                if (widget.endpoints.supportsHissi)
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
    final guroMasked = guroMaskedResNumbers(_state.res);
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
                      if (widget.endpoints.supportsHissi)
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
                child: ListView.builder(
                  controller: controller,
                  itemCount: posts.length,
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
                      isReplyToOwn: _isReplyToOwnPost(post),
                      blurImages: guroMasked.contains(post.number),
                      defaultName: widget.defaultName,
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
    final guroMasked = guroMaskedResNumbers(res);
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
          guroMasked: guroMasked,
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
          onPickAndUploadImage: _pickAndUploadImage,
          onPickAndUploadFile: _pickAndUploadFile,
          onShowActions: _showResActions,
          isOwnPost: (n) => _history.isOwnPost(widget.threadKey, n),
          isReplyToOwn: _isReplyToOwnPost,
          defaultName: widget.defaultName,
          ng: _ng,
          revealedNg: _revealedNg,
          enabled: _canWrite,
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

  // スレマップの目印はレス単位でキャッシュする。dat は追記のみで既存レスの本文は
  // 変わらないので、スクロールのたびに全レスへ正規表現（メディア URL 抽出・NG
  // 判定・`>>N` 解析）を掛け直さずに済む。設定が変わるとき（NG・自分のレス）
  // だけ捨てる。
  final _markerKindCache = <int, List<ThreadMapMarkerKind>?>{};
  int _markerCacheOwnCount = 0;

  /// ファストスクロールのトラックに出す目印を行インデックスで組む。つまみの
  /// 縦位置と同じ index 基準なので、目印の高さへつまみを運べばその行に着く。
  List<ThreadMapMarker> _mapMarkers(
    List<Object> items,
    List<Res> searchMatches,
    Map<int, int> replyCounts,
  ) {
    final ownCount = _history.ownPostCount(widget.threadKey);
    if (ownCount != _markerCacheOwnCount) {
      _markerCacheOwnCount = ownCount;
      _markerKindCache.clear();
    }
    final matched = searchMatches.map((r) => r.number).toSet();
    final markers = <ThreadMapMarker>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Res) {
        markers.add(ThreadMapMarker(i, ThreadMapMarkerKind.newArrival));
        continue;
      }
      final kinds = _markerKindsFor(item, hasOwnPosts: ownCount > 0);
      // あぼーんは中身が見えないので目印も出さない（飛んでも読めない）。
      if (kinds == null) continue;
      for (final kind in kinds) {
        markers.add(ThreadMapMarker(i, kind));
      }
      // 返信数と検索一致は後から変わる（伸びる・打ち直す）ので、レス単位の
      // キャッシュには入れずここで見る。どちらも Map 参照だけで済む。
      switch (replyTierOf(replyCounts[item.number] ?? 0)) {
        case ReplyTier.veryMany:
          markers.add(ThreadMapMarker(i, ThreadMapMarkerKind.veryManyReplies));
        case ReplyTier.many:
          markers.add(ThreadMapMarker(i, ThreadMapMarkerKind.manyReplies));
        case ReplyTier.none:
          break;
      }
      if (matched.contains(item.number)) {
        markers.add(ThreadMapMarker(i, ThreadMapMarkerKind.searchMatch));
      }
    }
    return markers;
  }

  /// レス自体から決まる目印（自分のレス・自分宛）。あぼーんなら null＝目印を
  /// 出さない。返信数と検索一致はレスの中身では決まらないので [_mapMarkers] 側。
  List<ThreadMapMarkerKind>? _markerKindsFor(
    Res res, {
    required bool hasOwnPosts,
  }) {
    return _markerKindCache.putIfAbsent(res.number, () {
      if (_ng.matches(res)) return null;
      final kinds = <ThreadMapMarkerKind>[];
      if (hasOwnPosts) {
        if (_history.isOwnPost(widget.threadKey, res.number)) {
          kinds.add(ThreadMapMarkerKind.own);
        } else if (_isReplyToOwnPost(res)) {
          kinds.add(ThreadMapMarkerKind.replyToOwn);
        }
      }
      return kinds;
    });
  }

  /// このレスが自分のレスへ `>>N` で返信しているか（自分宛のレス）。自分自身の
  /// レスは対象外にして、自分宛チップは他者からの返信だけに付ける。
  bool _isReplyToOwnPost(Res res) {
    if (_history.isOwnPost(widget.threadKey, res.number)) return false;
    for (final n in _referencedNumbers(res)) {
      if (_history.isOwnPost(widget.threadKey, n)) return true;
    }
    return false;
  }

  /// スレタイトルの全文を折り返して表示する（AppBar では省略されるため）。
  Future<void> _showFullTitle() async {
    final action = await showModalBottomSheet<_ThreadTitleAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final isFavorite = _history.isFavorite(widget.threadKey);
        final metadent = widget.creatorMetadent;
        final isNgCreator = metadent != null && _ng.creators.contains(metadent);
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    decodeEntities(_effectiveTitle),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link),
                    title: const Text('スレURLをコピー'),
                    subtitle: Text(_threadUrl.toString()),
                    onTap: () {
                      Navigator.pop(context);
                      _copyText(_threadUrl.toString(), 'スレURLをコピーしました');
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.search),
                    title: const Text('スレ内検索'),
                    enabled: _state.res.isNotEmpty,
                    onTap: _state.res.isEmpty
                        ? null
                        : () {
                            Navigator.pop(context, _ThreadTitleAction.search);
                          },
                  ),
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
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case _ThreadTitleAction.search:
        _startSearch();
      case null:
        break;
    }
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
        title: _effectiveTitle,
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
    // 同じ板の別スレへのリンクはアプリ内で開く。それ以外（他板・他サイト）は
    // これまで通りブラウザへ。
    if (_openThreadLink(url)) return;
    // mp4 等の直リンクは本文タップでもアプリ内プレーヤーで再生する
    // （サムネイルのタップと同じ着地点）。
    if (isVideoUrl(url)) {
      openVideoPlayer(context, url, onOpenExternally: _openInBrowser);
      return;
    }
    await _openInBrowser(url);
  }

  Future<void> _openInBrowser(Uri url) async {
    final ok = await widget.authLauncher.open(url);
    if (!ok && mounted) _showSnack('リンクを開けませんでした');
  }

  /// [url] が自ホスト・自板のスレリンクなら、そのスレをアプリ内で開いて true。
  /// 対象外なら false（呼び出し側でブラウザへ回す）。
  bool _openThreadLink(Uri url) {
    if (url.host != widget.endpoints.host) return false;
    final ref = parseThreadUrl(url);
    if (ref == null || ref.board != widget.endpoints.boardKey) return false;
    if (ref.threadKey == widget.threadKey) {
      // 今開いているスレ自身へのリンク。開き直さず、あれば先頭へ戻す程度に留める。
      _showSnack('このスレです');
      return true;
    }
    Navigator.of(context).push(_threadLinkRoute(ref.threadKey));
    return true;
  }

  PageRoute<void> _threadLinkRoute(String threadKey) {
    return SwipeBackPageRoute<void>(
      pageBuilder: (context, animation, secondaryAnimation) => ThreadScreen(
        threadKey: threadKey,
        // タイトルは開くまで不明。dat の 1 レス目から補完する。
        threadTitle: '',
        fetcher: _fetcher,
        endpoints: widget.endpoints,
        pollInterval: widget.pollInterval,
        authStore: _authStore,
        authLauncher: widget.authLauncher,
        readHistory: _history,
        ngStore: _ng,
        imagePicker: _imagePicker,
        imgurUploader: _imgurUploader,
        imageUploadSettings: _imageUploadSettings,
        pickAndUploadImage: widget.pickAndUploadImage,
        defaultName: widget.defaultName,
      ),
    );
  }

  // 本文以外（名前欄・ヘッダー・余白など）をタップしたとき、選択中なら解除する。
  // onTap は本文・リンク・ボタン等が拾ったタップには発火しないので、
  // 誰も拾わなかったタップだけを対象にできる。
  void _handleBackgroundTap() {
    if (_bodySelectionActive) FocusManager.instance.primaryFocus?.unfocus();
  }

  bool get _bodySelectionActive => _selectedBodyResNumbers.isNotEmpty;

  void _handleBodySelectionActiveChanged(int resNumber, bool active) {
    final changed = active
        ? _selectedBodyResNumbers.add(resNumber)
        : _selectedBodyResNumbers.remove(resNumber);
    if (!changed) return;
    // 選択中は戻るスワイプを止める（横に引く操作が選択範囲の変更になるため）。
    setState(() {});
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

  Future<Uri?> _pickAndUploadImage() async {
    final injected = widget.pickAndUploadImage;
    if (injected != null) return injected();
    return _uploader.pickAndUploadImage(_showSnackIfMounted);
  }

  Future<Uri?> _pickAndUploadFile() async {
    final injected = widget.pickAndUploadFile;
    if (injected != null) return injected();
    return _uploader.pickAndUploadFile(_showSnackIfMounted);
  }

  void _showSnackIfMounted(String message) {
    if (mounted) _showSnack(message);
  }

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
      tokens: _authStore.tokensFor(widget.endpoints.host),
      referer: widget.endpoints.writeReferer(threadKey: widget.threadKey),
      time: widget.endpoints.isFivech
          ? '${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
          : null,
      userAgent: widget.endpoints.writeUserAgent,
    );
    // ホスト単位で Cookie（edge/tinker・MonaTicket）を持ち回して永続化。
    await _authStore.setTokensFor(widget.endpoints.host, result.tokens);
    return result.outcome;
  }

  /// コンポーザから呼ばれる送信。受理されたら true（コンポーザが入力を消す）。
  Future<bool> _submit(String text) async {
    final accepted = await submitWithAuth(
      context: context,
      launcher: widget.authLauncher,
      postOnce: () => _postOnce(text),
    );
    if (accepted != null && mounted) {
      final resNum = accepted.resNum;
      if (resNum != null) {
        // サーバが番号を返したら、その番号を直接自分のレスにする（正確）。
        unawaited(_history.markOwnPost(widget.threadKey, resNum));
      } else {
        // 番号が取れないサーバ向けのフォールバック（増えた末尾を自分とみなす）。
        _pendingOwnPosts++;
      }
      _awaitingOwnPost = true;
      _showSnack('書き込みました');
      _pollAfterPost(); // 自分の書き込みをすぐ反映
    }
    return accepted != null;
  }

  void _pollAfterPost() {
    _postRefreshTimer?.cancel();
    unawaited(_runPostRefreshAttempt(0));
  }

  Future<void> _runPostRefreshAttempt(int attempt) async {
    if (!mounted || !_awaitingOwnPost || attempt >= _postRefreshAttempts) {
      return;
    }
    await _poll(force: true);
    if (!mounted || !_awaitingOwnPost || attempt + 1 >= _postRefreshAttempts) {
      return;
    }
    _postRefreshTimer = Timer(
      _postRefreshRetryDelay,
      () => unawaited(_runPostRefreshAttempt(attempt + 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = _searchMatches;
    final searchIndex = matches.isEmpty
        ? 0
        : math.min(_currentSearchIndex, matches.length - 1);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 80,
        // ルートとして開かれていないときは自前で戻るを出す（既定の実装は
        // ルートが積まれているかどうかで判断するため、ここでは出てこない）。
        leading: widget.onClose == null
            ? null
            : BackButton(onPressed: widget.onClose),
        // タイトルは重要なので AppBar 内でできるだけ読ませる。極端に長い場合は
        // これまで通りタップで全文を出す。
        title: _searching
            ? _ThreadSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                matchLabel: _searchController.text.trim().isEmpty
                    ? ''
                    : matches.isEmpty
                    ? '0件'
                    : '${searchIndex + 1}/${matches.length}',
                onChanged: _onSearchChanged,
                onPrevious: matches.isEmpty
                    ? null
                    : () => _moveSearchResult(-1),
                onNext: matches.isEmpty ? null : () => _moveSearchResult(1),
                onClose: _closeSearch,
              )
            : InkWell(
                onTap: _showFullTitle,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _effectiveTitle.isEmpty
                            ? 'スレッド'
                            : decodeEntities(_effectiveTitle),
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.22,
                        ),
                      ),
                      if (!_loading && _error == null && !_notFound)
                        Text(
                          _statusLabel == null
                              ? '${_state.res.length}レス'
                              : '${_state.res.length}レス ・ $_statusLabel',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
              ),
        // 検索中はポーリングのインジケータで AppBar の高さ・構造を毎回変えない。
        // 5秒ごとの再構築で検索欄がちらつく・IME を妨げるのを避ける。
        bottom: _polling && !_searching
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _handleBackgroundTap,
        child: Column(
          children: [
            // 戻るスワイプは一覧側でだけ受ける。入力欄の上の横ドラッグはカーソル
            // 移動・文字選択なので、そちらへ触らない。
            Expanded(
              child: BackSwipe(enabled: !_bodySelectionActive, child: _body()),
            ),
            _Composer(
              key: _composerKey,
              controller: _composer,
              focusNode: _composerFocus,
              onSend: _submit,
              onPickAndUploadImage: _pickAndUploadImage,
              onPickAndUploadFile: _pickAndUploadFile,
              enabled: _canWrite,
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
    if (_notFound) {
      return const _NotFoundView();
    }
    if (_state.isEmpty && _error != null) {
      return _ErrorView(error: _error!, onRetry: _refresh);
    }

    final res = _state.res;
    final idCounts = _idCounts(res);
    final idOrdinals = _idOrdinals(res);
    final replies = replyCounts(res);
    final guroMasked = guroMaskedResNumbers(res);
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

    // スレ内検索中は一致箇所をハイライトし、今ジャンプ先の一致レスを強調する。
    final searchQuery = _searching ? _searchController.text.trim() : '';
    final searchMatches = searchQuery.isEmpty ? const <Res>[] : _searchMatches;
    final currentMatchNumber = searchMatches.isEmpty
        ? null
        : searchMatches[math.min(_currentSearchIndex, searchMatches.length - 1)]
              .number;

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
              // レス間は線を引かず、スレ一覧と同じく余白だけで区切る。各レスは
              // 番号・名前の見出し行が始点の目印になる。
              if (ngHidden) {
                return _NgPlaceholder(
                  number: item.number,
                  onReveal: () => setState(() => _revealedNg.add(item.number)),
                  onLongPress: () => _showResActions(item),
                );
              }
              return PostItem(
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
                    _handleBodySelectionActiveChanged(item.number, active),
                onLongPress: () => _showResActions(item),
                bodySelectable: false,
                isOwn: _history.isOwnPost(widget.threadKey, item.number),
                isReplyToOwn: _isReplyToOwnPost(item),
                blurImages: guroMasked.contains(item.number),
                highlightQuery: searchQuery,
                isCurrentMatch: item.number == currentMatchNumber,
                defaultName: widget.defaultName,
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
              markers: _mapMarkers(items, searchMatches, replies),
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

class _ThreadSearchField extends StatelessWidget {
  const _ThreadSearchField({
    required this.controller,
    required this.focusNode,
    required this.matchLabel,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String matchLabel;
  final ValueChanged<String> onChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  /// 検索インプットの枠。全状態で枠線を消し、角丸だけ一覧の検索欄に合わせる。
  static final _searchBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide.none,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'スレ内検索',
              isDense: true,
              // 一覧の検索欄と同じ「検索インプット」の見た目に揃える（角丸14・
              // 枠なし・prefix は onSurfaceVariant）。塗りは不透明面なので M3 標準の
              // surfaceContainerHighest のまま（ガラス面の一覧は onSurface@0.06）。
              prefixIcon: Icon(Icons.search, color: scheme.onSurfaceVariant),
              suffixText: matchLabel,
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: _searchBorder,
              enabledBorder: _searchBorder,
              focusedBorder: _searchBorder,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            onChanged: onChanged,
            onSubmitted: (_) => onNext?.call(),
          ),
        ),
        IconButton(
          tooltip: '前の一致',
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: onPrevious,
        ),
        IconButton(
          tooltip: '次の一致',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: onNext,
        ),
        IconButton(
          tooltip: '検索を閉じる',
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
      ],
    );
  }
}

enum _ThreadTitleAction { search }

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
    this.markers = const [],
  });

  final ItemPositionsListener positions;
  final int itemCount;
  final void Function(int index) onJump;
  final String Function(int index) labelForIndex;

  /// トラックに出すスレマップの目印。
  final List<ThreadMapMarker> markers;

  @override
  State<_FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<_FastScroller> {
  static const double _handleHeight = 52;
  static const double _handleWidth = 30;

  /// ドラッグ中に目印へ吸い付く距離（論理ピクセル）。
  static const double _snapDistance = 12;

  /// 目印のタップ当たり判定。目印自体は数ピクセルなので指で押せる大きさに広げる。
  static const double _tapTargetWidth = 22;
  static const double _tapTargetHeight = 28;
  bool _dragging = false;
  double _fraction = 0;

  /// いま吸い付いている目印。吹き出しの文言とつまみの位置に使う。
  ThreadMapMarker? _snapped;

  // つまみはスクロール中・ドラッグ中だけ表示し、静止したら隠す。隠れている間は
  // 当たり判定も消し（IgnorePointer）、下にある返信ボタン等のタップを塞がない。
  bool _visible = false;
  Timer? _hideTimer;
  // 静止してから消すまでの時間。少し余裕を持たせる。
  static const _hideDelay = Duration(milliseconds: 2400);
  // 再表示に必要な最小スクロール量（1 行分に対する割合）。小さめにして、
  // わずかなスクロールでも出るようゆるめに判定する。
  static const _revealThreshold = 0.015;
  // 直近に表示したときのスクロール位置（先頭行 index からその行のスクロール量を
  // 引いた連続値）。ここから一定量動いたら再表示する。末尾追記のデータ更新では
  // 先頭行が動かないので出さない。未設定は NaN。
  double _lastScroll = double.nan;

  @override
  void initState() {
    super.initState();
    widget.positions.itemPositions.addListener(_onPositionsChanged);
    // 入室直後に一度だけ出して場所を知らせ、そのまま自動で隠す。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal();
    });
  }

  @override
  void dispose() {
    widget.positions.itemPositions.removeListener(_onPositionsChanged);
    _hideTimer?.cancel();
    super.dispose();
  }

  /// 少しでもスクロールしたら表示する（末尾追記のデータ更新では先頭行が動かない
  /// ので出さない）。前回表示位置から一定量動いたかで判定する。
  void _onPositionsChanged() {
    final m = _scrollMetric();
    if (_lastScroll.isFinite && (m - _lastScroll).abs() < _revealThreshold) {
      return;
    }
    _lastScroll = m;
    _reveal();
  }

  /// つまみを表示し、一定時間操作が無ければ隠すタイマーを貼り直す。
  void _reveal() {
    _hideTimer?.cancel();
    if (!_visible) setState(() => _visible = true);
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted || _dragging) return;
      setState(() => _visible = false);
    });
  }

  /// 見えている先頭行を基準にした連続スクロール量。下へ進むほど大きくなる。
  /// 行インデックスの丸ごとの変化を待たず、わずかなスクロールも拾える。
  double _scrollMetric() {
    final positions = widget.positions.itemPositions.value;
    ItemPosition? top;
    for (final p in positions) {
      if (p.itemTrailingEdge <= 0) continue;
      if (top == null || p.index < top.index) top = p;
    }
    if (top == null) return 0;
    // itemLeadingEdge は行上端の位置（0=ビューポート上端、上へ流れると負）。
    // index から引くと下方向スクロールで単調増加する連続値になる。
    return top.index - top.itemLeadingEdge;
  }

  /// 見えている先頭行のインデックス。
  int _currentTopIndex() {
    final positions = widget.positions.itemPositions.value;
    if (positions.isEmpty) return 0;
    var topIndex = widget.itemCount;
    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && p.index < topIndex) topIndex = p.index;
    }
    return topIndex >= widget.itemCount ? 0 : topIndex;
  }

  /// 見えている先頭行から現在位置（0〜1）を求める。
  double _currentFraction() {
    if (widget.itemCount <= 1) return 0;
    return (_currentTopIndex() / (widget.itemCount - 1)).clamp(0.0, 1.0);
  }

  int _indexFor(double fraction) => (fraction * (widget.itemCount - 1)).round();

  /// つまみのドラッグ量 [dy] だけ位置を進め、その行へジャンプする。つまみ自体を
  /// つかんだ時だけ動かすので、トラック上の返信ボタン等のタップは邪魔しない。
  ///
  /// 近くに飛び先の目印があれば吸い付く。目印は数ピクセル幅しかなく、狙って
  /// 止めるのは難しいため。[_fraction] は生の位置のまま持ち（吸着で書き換えると
  /// 長いドラッグでずれていく）、つまみと飛び先だけ目印に寄せる。
  void _applyDelta(double dy, double travel) {
    if (travel <= 0) return;
    final fraction = (_fraction + dy / travel).clamp(0.0, 1.0);
    final index = _indexFor(fraction);
    final snapped = _snapTarget(index, travel);
    // 別の目印に乗り換えた瞬間だけ、吸い付いたことを触感で返す。
    if (snapped != null && snapped.index != _snapped?.index) {
      unawaited(HapticFeedback.selectionClick());
    }
    setState(() {
      _fraction = fraction;
      _snapped = snapped;
    });
    widget.onJump(snapped?.index ?? index);
  }

  /// [index] の近くにある目印。
  ThreadMapMarker? _snapTarget(int index, double travel) {
    if (widget.itemCount <= 1) return null;
    // ピクセルでの許容距離を行インデックスに直す。
    final tolerance = _snapDistance / travel * (widget.itemCount - 1);
    ThreadMapMarker? best;
    var bestDistance = double.infinity;
    for (final marker in widget.markers) {
      final distance = (marker.index - index).abs().toDouble();
      if (distance > tolerance || distance >= bestDistance) continue;
      best = marker;
      bestDistance = distance;
    }
    return best;
  }

  /// 目印をタップしてその行へ飛ぶ。飛んだ先が分かるよう、目印は出したままにする。
  void _jumpToMarker(ThreadMapMarker marker) {
    unawaited(HapticFeedback.selectionClick());
    widget.onJump(marker.index);
    _reveal();
  }

  /// 吹き出しの文言。目印に吸い付いているときは何の目印かも出す（この大きさ
  /// では色だけでは種別が読めないので、ここで答え合わせをする）。
  String _bubbleLabel() {
    final snapped = _snapped;
    final label = widget.labelForIndex(snapped?.index ?? _indexFor(_fraction));
    return switch (snapped?.kind) {
      ThreadMapMarkerKind.newArrival => 'ここから新着',
      ThreadMapMarkerKind.manyReplies => '返信$manyRepliesThreshold+ · $label',
      ThreadMapMarkerKind.veryManyReplies =>
        '返信$veryManyRepliesThreshold+ · $label',
      ThreadMapMarkerKind.own => '自分 · $label',
      ThreadMapMarkerKind.replyToOwn => '自分宛 · $label',
      ThreadMapMarkerKind.searchMatch => '一致 · $label',
      _ => label,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _handleWidth,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final travel = constraints.maxHeight - _handleHeight;
          return ValueListenableBuilder<Iterable<ItemPosition>>(
            valueListenable: widget.positions.itemPositions,
            builder: (context, _, _) {
              // 吸い付いている間はつまみも目印の高さに寄せる（掴んでいる位置は
              // [_fraction] のまま持つので、離しても位置がずれていかない）。
              final snappedFraction = _snapped == null || widget.itemCount <= 1
                  ? null
                  : _snapped!.index / (widget.itemCount - 1);
              final fraction = _dragging
                  ? (snappedFraction ?? _fraction)
                  : _currentFraction();
              final top = travel <= 0 ? 0.0 : fraction * travel;
              // 表示中・ドラッグ中だけ見せる。隠れている間は当たり判定も消す。
              final shown = _visible || _dragging;
              // つまみ以外の場所は素通しにして、トラック上に重なる返信ボタン
              // などのタップを邪魔しないようにする（ジェスチャはつまみ限定）。
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  // スレマップ。つまみと同じタイミングで出し入れし、静止したら
                  // 一緒に消えるので普段の読みを邪魔しない。当たり判定は持たない。
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: shown ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: CustomPaint(
                          painter: ThreadMapPainter(
                            markers: widget.markers,
                            itemCount: widget.itemCount,
                            handleHeight: _handleHeight,
                            scheme: scheme,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 目印そのものをタップして飛べるようにする。当たり判定は
                  // 「目印が見えている間」かつ「目印の位置だけ」に限る。トラック
                  // 全面を塞ぐと、下に重なるレスの返信ボタン等が押せなくなる。
                  if (travel > 0 && widget.itemCount > 1)
                    for (final marker in widget.markers)
                      Positioned(
                        right: 0,
                        width: _tapTargetWidth,
                        height: _tapTargetHeight,
                        top:
                            _handleHeight / 2 +
                            marker.index / (widget.itemCount - 1) * travel -
                            _tapTargetHeight / 2,
                        child: IgnorePointer(
                          ignoring: !shown,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _jumpToMarker(marker),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                  // ドラッグ中はつまみの左にレス番号の吹き出しを出す。
                  if (_dragging)
                    Positioned(
                      right: _handleWidth + 8,
                      top: top + (_handleHeight - 32) / 2,
                      child: IgnorePointer(
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
                            _bubbleLabel(),
                            style: TextStyle(
                              color: scheme.onInverseSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 0,
                    top: top,
                    // 隠れているときは opacity 0＋IgnorePointer で当たり判定も消し、
                    // 下の返信ボタンを塞がない。再表示はスクロールで行う。
                    child: AnimatedOpacity(
                      opacity: shown ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !shown,
                        // ジェスチャーアリーナを介さない Listener で、押した瞬間から
                        // ポインタを掴む。親リストの縦スクロールと取り合わないので
                        // 「一度タップしてからでないと動かせない」問題が起きない。
                        // 掴んだ位置からの相対移動なので飛びもない。
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (_) {
                            _hideTimer?.cancel();
                            setState(() {
                              _dragging = true;
                              _visible = true;
                              _fraction = _currentFraction();
                              _snapped = null;
                            });
                          },
                          onPointerMove: (e) => _applyDelta(e.delta.dy, travel),
                          onPointerUp: (_) {
                            setState(() {
                              _dragging = false;
                              _snapped = null;
                            });
                            _reveal();
                          },
                          onPointerCancel: (_) {
                            setState(() {
                              _dragging = false;
                              _snapped = null;
                            });
                            _reveal();
                          },
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
                    ),
                  ),
                ],
              );
            },
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
    required this.guroMasked,
    required this.onTapId,
    required this.onTapRes,
    required this.onTapResRange,
    required this.onTapReplies,
    required this.onTapUrl,
    required this.onSend,
    required this.onPickAndUploadImage,
    required this.onPickAndUploadFile,
    required this.onShowActions,
    required this.isOwnPost,
    required this.isReplyToOwn,
    required this.ng,
    required this.revealedNg,
    required this.enabled,
    this.defaultName,
  });

  final String title;
  final List<_ConversationEntry> entries;
  final ScrollController scrollController;
  final int? focusNumber;
  final Map<String, int> idCounts;
  final Map<int, int> idOrdinals;
  final Map<int, int> replyCountByNumber;

  /// 「グロ」注意が付き、画像サムネイルへモザイクを掛けるレス番号の集合。
  final Set<int> guroMasked;
  final ValueChanged<String> onTapId;
  final void Function(int source, int target) onTapRes;
  final void Function(int source, List<int> targets) onTapResRange;
  final ValueChanged<int> onTapReplies;
  final ValueChanged<Uri> onTapUrl;

  /// 会話シート内の入力欄から直接送信する投稿関数（受理で true）。
  final Future<bool> Function(String) onSend;

  /// 画像選択とアップロード。成功時はレス本文へ挿入する URL を返す。
  final Future<Uri?> Function() onPickAndUploadImage;

  /// ファイル選択とアップロード。成功時はレス本文へ挿入する URL を返す。
  final Future<Uri?> Function() onPickAndUploadFile;

  /// レス長押しでアクションメニューを出す。
  final ValueChanged<Res> onShowActions;
  final bool Function(int number) isOwnPost;

  /// 自分のレスへ返信している（自分宛の）レスか。
  final bool Function(Res res) isReplyToOwn;

  /// NG 判定に使う設定と、タップで一時表示にしたレス番号の集合（画面と共有）。
  final NgStore ng;
  final Set<int> revealedNg;

  /// 入力欄を有効にするか（停止スレでは false）。
  final bool enabled;

  /// 板の既定の名前。名無しのレスから名前を省くのに使う（[PostItem.defaultName]）。
  final String? defaultName;

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
                        isReplyToOwn:
                            widget.isReplyToOwn(entry.res) &&
                            !widget.isOwnPost(entry.res.number),
                        depth: entry.depth,
                        refs: entry.refs,
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
                                isReplyToOwn: widget.isReplyToOwn(entry.res),
                                showReplyToOwnAccent: false,
                                blurImages: widget.guroMasked.contains(
                                  entry.res.number,
                                ),
                                defaultName: widget.defaultName,
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
                  onPickAndUploadImage: widget.onPickAndUploadImage,
                  onPickAndUploadFile: widget.onPickAndUploadFile,
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
    required this.isReplyToOwn,
  });
  final Widget child;
  final int depth;
  final List<int> refs;
  final bool highlighted;
  final bool isReplyToOwn;

  /// インデントを付ける最大の深さ。これ以上深くなっても字下げは増やさない。
  /// 深いツリーで本文幅（＝ヘッダ行）が潰れて表示が破綻するのを防ぐ。
  static const _maxIndentLevels = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indent = math.min(depth, _maxIndentLevels) * 18.0;
    final accentColor = highlighted
        ? scheme.primary
        : isReplyToOwn
        ? scheme.primary
        : null;
    final borderColor =
        accentColor ?? scheme.outlineVariant.withValues(alpha: 0.8);
    final borderWidth = accentColor != null
        ? 4.0
        : depth > 0
        ? 2.0
        : 0.0;
    final contentLeftPadding = accentColor != null
        ? (depth > 0 ? 6.0 : 12.0)
        : depth > 0
        ? 8.0
        : 0.0;

    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(
        decoration: BoxDecoration(
          color: highlighted
              ? scheme.primaryContainer.withValues(alpha: 0.18)
              : isReplyToOwn
              ? scheme.primaryContainer.withValues(alpha: 0.2)
              : Colors.transparent,
          border: borderWidth > 0
              ? Border(
                  left: BorderSide(color: borderColor, width: borderWidth),
                )
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.only(left: contentLeftPadding),
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
            ],
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
    required this.onPickAndUploadImage,
    required this.onPickAndUploadFile,
    required this.enabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 送信。受理されたら true を返す（入力欄をクリアする）。
  final Future<bool> Function(String) onSend;
  final Future<Uri?> Function() onPickAndUploadImage;
  final Future<Uri?> Function() onPickAndUploadFile;
  final bool enabled;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _sending = false;
  bool _uploadingImage = false;
  bool _uploadingFile = false;

  @override
  void initState() {
    super.initState();
    // 本文中の URL から添付プレビューを作るので、テキスト変更で作り直す。
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    // URL 挿入で末尾に付く改行は投稿本文に残さない。AA は末尾の空白が絵の
    // 一部になりうるので、落とすのは末尾の改行だけにする。
    final text = widget.controller.text.replaceAll(RegExp(r'\n+$'), '');
    if (!widget.enabled ||
        text.trim().isEmpty ||
        _sending ||
        _uploadingImage ||
        _uploadingFile) {
      return;
    }
    setState(() => _sending = true);
    try {
      final accepted = await widget.onSend(text);
      if (accepted) widget.controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attachImage() async {
    if (!widget.enabled || _sending || _uploadingImage || _uploadingFile) {
      return;
    }
    setState(() => _uploadingImage = true);
    try {
      final url = await widget.onPickAndUploadImage();
      if (url != null) _insertUrl(url.toString());
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _attachFile() async {
    if (!widget.enabled || _sending || _uploadingImage || _uploadingFile) {
      return;
    }
    setState(() => _uploadingFile = true);
    try {
      final url = await widget.onPickAndUploadFile();
      if (url != null) _insertUrl(url.toString());
    } finally {
      if (mounted) setState(() => _uploadingFile = false);
    }
  }

  void _insertUrl(String url) {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = start > 0 ? text[start - 1] : '';
    final after = end < text.length ? text[end] : '';
    final prefix = before.isEmpty || before == '\n' ? '' : '\n';
    // URL の後ろは常に改行して次の入力を新しい行から始められるようにする。
    // すでに直後が改行なら足さない。
    final suffix = after == '\n' ? '' : '\n';
    final insertion = '$prefix$url$suffix';
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
    widget.focusNode.requestFocus();
  }

  /// 添付プレビューの × から呼ばれ、本文中の該当 URL を取り除く。
  /// URL に続く（なければ直前の）改行も一緒に消して空行を残さない。
  void _removeUrl(Uri url) {
    final controller = widget.controller;
    final text = controller.text;
    final raw = url.toString();
    final index = text.indexOf(raw);
    if (index < 0) return;
    var start = index;
    var end = index + raw.length;
    if (end < text.length && text[end] == '\n') {
      end += 1;
    } else if (start > 0 && text[start - 1] == '\n') {
      start -= 1;
    }
    final newText = text.replaceRange(start, end, '');
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start.clamp(0, newText.length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = composeBodyTextStyle(theme);
    final text = widget.controller.text;
    final imageUrls = imageUrlsIn(text);
    final videoUrls = videoUrlsIn(text);
    final audioUrls = audioUrlsIn(text);
    final embedVideos = embedVideosIn(text);
    final hasAttachments =
        imageUrls.isNotEmpty ||
        videoUrls.isNotEmpty ||
        audioUrls.isNotEmpty ||
        embedVideos.isNotEmpty;
    // [_send] が受け付ける条件と同じ。送信ボタンの塗りをこれで切り替える。
    final canSend =
        widget.enabled &&
        text.trim().isNotEmpty &&
        !_sending &&
        !_uploadingImage &&
        !_uploadingFile;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          // 上辺は面を分けるだけの控えめな線に。浮遊感のある方向性に合わせ、
          // 区切り線（outlineVariant@0.4）より薄くして主張を抑える。
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
        ),
        // 送信ボタンが塗りを持つので、左右の余白は同じにして端を揃える。
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasAttachments) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: PostImages(
                    urls: imageUrls,
                    videoUrls: videoUrls,
                    audioUrls: audioUrls,
                    embedVideos: embedVideos,
                    onRemove: _removeUrl,
                    thumbSize: 96,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    // 停止スレでも欄は生かしたまま読み取り専用にする。無効
                    // （enabled: false）にすると書きかけを選択もコピーもできず、
                    // 次スレへ持っていく手立てが無くなるため。書けないことは
                    // ヒントと、無効になった送信・添付ボタンで示す。
                    readOnly: !widget.enabled,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    // 行高を明示すると 1 行時の高さがフォントに左右されず、
                    // kComposeControlHeight にぴたりと収まる。
                    style: textStyle,
                    decoration:
                        composeFieldDecoration(
                          scheme: scheme,
                          hintText: widget.enabled ? 'レスを書く' : '書き込み停止中',
                          textStyle: textStyle,
                          // 21（15×1.4）+ 10.5×2 = 42 = kComposeControlHeight。
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10.5,
                          ),
                        ).copyWith(
                          suffixIcon:
                              widget.enabled && widget.focusNode.hasFocus
                              ? IconButton(
                                  tooltip: 'キーボードを閉じる',
                                  icon: const Icon(
                                    Icons.keyboard_hide,
                                    size: 20,
                                  ),
                                  padding: EdgeInsets.zero,
                                  style: composeQuietButtonStyle(scheme),
                                  onPressed: widget.focusNode.unfocus,
                                )
                              : null,
                          // ボタンの既定の最小サイズ（48）に入力欄が引っ張られると、
                          // フォーカスした瞬間だけ欄が伸びて他のボタンとずれる。
                          // 高さを行に合わせて固定し、出入りしても動かないようにする。
                          suffixIconConstraints: const BoxConstraints.tightFor(
                            width: 40,
                            height: kComposeControlHeight,
                          ),
                        ),
                  ),
                ),
                const SizedBox(width: 6),
                // 添付系は入力欄に添えるだけの脇役なので、色を onSurfaceVariant に
                // 落として送信ボタンとの主従をはっきりさせる。
                SizedBox(
                  width: kComposeControlHeight,
                  height: kComposeControlHeight,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '画像を追加',
                    style: composeQuietButtonStyle(scheme),
                    onPressed:
                        !widget.enabled ||
                            _sending ||
                            _uploadingImage ||
                            _uploadingFile
                        ? null
                        : _attachImage,
                    icon: _uploadingImage
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image_outlined, size: 21),
                  ),
                ),
                SizedBox(
                  width: kComposeControlHeight,
                  height: kComposeControlHeight,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: 'ファイルを添付',
                    style: composeQuietButtonStyle(scheme),
                    onPressed:
                        !widget.enabled ||
                            _sending ||
                            _uploadingImage ||
                            _uploadingFile
                        ? null
                        : _attachFile,
                    icon: _uploadingFile
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file, size: 21),
                  ),
                ),
                const SizedBox(width: 4),
                // 送信ボタンは 1 行時の入力欄と同じ高さに固定。複数行に伸びたら
                // crossAxisAlignment.end で下端に留まる。丸ボタンだと入力欄の角丸
                // （14）から浮くので、同じ角丸の四角に合わせる。
                // 本文が空のうちは押しても何も起きない（[_send] が弾く）ので、
                // 塗りも控えめにして「まだ送れない」ことを見た目でも伝える。
                SizedBox(
                  width: kComposeControlHeight,
                  height: kComposeControlHeight,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '送信',
                    onPressed: !widget.enabled || _sending ? null : _send,
                    style: IconButton.styleFrom(
                      backgroundColor: canSend
                          ? scheme.primary
                          : Colors.transparent,
                      foregroundColor: canSend
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      shape: composeShape,
                    ),
                    icon: _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : const Icon(Icons.send, size: 19),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// dat も過去ログ（kako）も見つからないスレに出す。エラーではなく「消えた」。
class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_toggle_off,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('スレッドが見つかりません'),
            const SizedBox(height: 6),
            Text(
              'dat落ち後、過去ログも残っていないようです。',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
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
