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
import '../net/thread_link.dart';
import '../net/thread_view_settings.dart';
import 'attachment_uploader.dart';
import 'compose_style.dart';
import 'back_swipe.dart';
import 'embed_urls.dart';
import 'id_icon.dart';
import 'image_set_screen.dart';
import 'image_urls.dart';
import 'ng_screen.dart';
import 'post_images.dart';
import 'post_item.dart';
import 'reply_swipe.dart';
import 'dat_html.dart';
import 'reply_tier.dart';
import 'res_body.dart';
import 'thread_map.dart';
import 'thread_tree.dart';
import 'mini_player.dart';
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
    this.threadViewSettings,
    this.imagePicker,
    this.imgurUploader,
    this.imageUploadSettings,
    this.fileUploadSettings,
    this.pickAndUploadImages,
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

  /// レスの並べ方（番号順 / ツリー）。既定はアプリ共有インスタンス。
  final ThreadViewSettings? threadViewSettings;

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
  final Future<List<Uri>> Function()? pickAndUploadImages;

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
  late final ThreadViewSettings _view;
  late final ImagePicker _imagePicker;
  late final ImgurUploader _imgurUploader;
  late final ImageUploadSettings _imageUploadSettings;
  late final FileUploadSettings _fileUploadSettings;
  late final AttachmentUploader _uploader;

  /// NG 判定されたが、タップで一時的に表示したレス番号。
  final _revealedNg = <int>{};
  final _itemScroll = ItemScrollController();
  final _scrollOffset = ScrollOffsetController();
  final _positions = ItemPositionsListener.create();

  /// 直近に届いた一覧の寸法（現在位置・端・画面の高さ）。
  ///
  /// [ScrollablePositionedList] はピクセル位置を持たず、行の位置も**画面に
  /// 掛かっている行のぶんしか**教えてくれない。末尾までの残りはここから測る。
  ScrollMetrics? _listMetrics;
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _composerKey = GlobalKey();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// 一覧の各行。[ThreadTreeRow]（レス・返信先の引用）か [_NewArrivalMarker]
  /// （新着境界）のどちらか。
  List<Object> _items = const [];

  /// 初回表示で合わせる位置の決め方（前回位置 / 末尾 / 先頭）。
  _Landing _landing = _Landing.top;

  /// 初回表示で合わせるインデックス。行を組んだ時点で一度だけ決める。
  int _initialIndex = 0;
  bool _landingResolved = false;

  /// 末尾（最新レス）が画面に見えているか。新着の自動追従に使う。
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
  /// 追跡し、スレ一覧の既読位置として保存する。
  int _furthestRead = 0;

  /// ツリー表示で通り過ぎたレス番号。番号順に並んでいないので、既読位置は
  /// これが 1 から続いているところまでで測る（[_onPositions]）。
  final _seenResNumbers = <int>{};

  /// [_seenResNumbers] に数え終わった行の位置。ここまでは通り過ぎている。
  /// 行の並びが組み替わったら -1 に戻して数え直す。
  int _passedRowIndex = -1;

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

  /// 届いたら映っているか見に行く自分のレスの番号（書き込み直後だけ入る）。
  ///
  /// 末尾に居るときだけ追従する既定の動きでは、ツリー表示で自分のレスが末尾に
  /// 来ない並びのときに送ったレスを見失う。[_noticeOwnPostAfter] を参照。
  int? _ownPostToShow;
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
    _view = widget.threadViewSettings ?? ThreadViewSettings.shared;
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
    _view.addListener(_onViewSettingsChanged);
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
    _view.removeListener(_onViewSettingsChanged);
    _positions.itemPositions.removeListener(_onPositions);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _postRefreshTimer?.cancel();
    _dismissTopSnack();
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

  /// 末尾（最新レス）が見えているか。新着の自動追従に使う。
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
        _landing = entry.landing;
        _loading = false;
        _error = null;
      });
      // 行はこれから組み直される（新着ラインの位置が決まる）。
      _passedRowIndex = -1;
      _maybeShowReplySwipeHint();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// レスの左スワイプで返信できることを一度だけ知らせる。
  ///
  /// ヘッダに常時出していた返信ボタンを畳んだ代わりの導線で、静止した画面には
  /// 何も出ない。見逃してもレスの長押しメニューに「>>N に返信」が残っている。
  ///
  /// 書き込めないスレ（dat落ち・過去ログ）では出さない。そこで覚えてもらっても
  /// その場では使えないうえ、「見た」ことにして二度目を潰してしまうため。
  void _maybeShowReplySwipeHint() {
    if (!_canWrite || _state.res.isEmpty) return;
    if (_view.replySwipeHintSeen) return;
    _showSnack('レスを左へスワイプすると返信できます');
    _view.markReplySwipeHintSeen();
  }

  /// 全 [total] レスのスレを開いたときの、新着境界（ここから下が新着）と
  /// 着地位置。[lastSeen] は前回どこまで見たか（未読なら null）。
  ///
  /// - 未読（初回）: 先頭から。新着ライン無し。
  /// - 既読＆新着あり: 前回位置に新着ラインを置き、そこへ合わせる。
  /// - 既読＆新着なし: 末尾（続き）へ。
  ///
  /// 着地の行インデックスは行を組んでから [_landingIndex] で出す。ツリー表示
  /// ではレス数と行位置が一致しないため。
  ({int openCount, _Landing landing}) _entryPositions(
    int total,
    int? lastSeen,
  ) {
    if (lastSeen == null) return (openCount: total, landing: _Landing.top);
    if (lastSeen < total) {
      return (openCount: lastSeen, landing: _Landing.newArrival);
    }
    return (openCount: total, landing: _Landing.bottom);
  }

  /// 組み上がった行から初回の着地インデックスを出す。新着ラインへ合わせる場合は
  /// 少し手前に寄せて、直前の流れを思い出せるようにする。
  int _landingIndex(List<Object> items) {
    const overlap = 3;
    if (items.isEmpty) return 0;
    switch (_landing) {
      case _Landing.top:
        return 0;
      case _Landing.bottom:
        return items.length - 1;
      case _Landing.newArrival:
        // 前回位置が 0 レス目なら新着ラインは出ない。その場合は先頭から。
        final marker = items.indexWhere((item) => item is _NewArrivalMarker);
        if (marker < 0) return 0;
        return marker - overlap < 0 ? 0 : marker - overlap;
    }
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
    // 新着ラインが動く＝ツリーの並びも組み替わるので、数え直しにする。
    _passedRowIndex = -1;
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
        final own = _ownPostToShow;
        final ownArrived =
            own != null && r.state.res.any((post) => post.number == own);
        if (ownArrived) _ownPostToShow = null;
        // 末尾に居たなら追従する。
        var settled = Future<void>.value();
        if (wasShortContent) {
          _scrollToTopSoon();
        } else if (wasAtBottom) {
          settled = _scrollToBottomSoon();
        }
        // 送ったレスが映らなかったときだけ、追従が済んでから知らせる。
        if (ownArrived) unawaited(_noticeOwnPostAfter(settled, own));
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
  ///
  /// 番号順表示では「見えた最大レス番号」がそのまま既読位置になる（飛ばした
  /// ぶんは読み飛ばしたものとして扱う）。ツリー表示では並びが番号順でないので、
  /// **通り過ぎた行**のレス番号を覚えておき、それが 1 から続いているところまで
  /// を既読位置にする。ツリーの上の方に出てきた新しい番号のレスで既読位置が
  /// 飛ぶと、その手前の未読を読まずに読了扱いにしてしまうため。
  void _onPositions() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty || _items.isEmpty) return;
    final lastIndex = _items.length - 1;
    final tree = _view.layout == ThreadLayout.tree;
    var maxRes = _furthestRead;
    var atBottom = false;
    var deepest = -1;
    for (final p in positions) {
      // 一部でも見えている行か。
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) continue;
      // 引用行（返信先の再掲）は読んだ位置に数えない。番号が前へ戻るうえ、
      // 本体はまだ下（新着側）にあるため。
      final item = _items[p.index];
      if (!tree && item is ThreadTreeRow && !item.quote) {
        if (item.res.number > maxRes) maxRes = item.res.number;
      }
      if (p.index > deepest) deepest = p.index;
      if (p.index == lastIndex && p.itemTrailingEdge <= 1.0001) atBottom = true;
    }
    if (tree) {
      _passRowsThrough(deepest);
      var next = maxRes + 1;
      while (_seenResNumbers.contains(next)) {
        next++;
      }
      maxRes = next - 1;
    }
    final readAdvanced = maxRes > _furthestRead;
    // どちらも表示には出ない（既読の保存と新着追従の判定にだけ使う）ので、
    // スクロールのたびに一覧を組み直さないよう setState は挟まない。
    _furthestRead = maxRes;
    _atBottomNow = atBottom;
    if (readAdvanced) _persistReadPosition(maxRes);
  }

  /// [index] 行目までを通り過ぎたものとして数える（ツリー表示の既読位置用）。
  ///
  /// **見えている行をその都度拾うのでは足りない。** 勢いよく送ると行はフレーム
  /// を跨いで飛ぶし、つまみで一気に運べば間の行はそもそも組まれない。取りこぼした
  /// 番号が 1 つあるだけで既読位置はそこで止まり、下まで読んでも次に開いたとき
  /// 古い位置と新着ラインへ戻される。**どこまで下ったか**で数えれば、通った行は
  /// 全部数に入る（番号順表示が「見えた最大レス番号」で測るのと同じ扱い）。
  void _passRowsThrough(int index) {
    if (index <= _passedRowIndex) return;
    for (var i = _passedRowIndex + 1; i <= index && i < _items.length; i++) {
      final item = _items[i];
      if (item is ThreadTreeRow && !item.quote) {
        _seenResNumbers.add(item.res.number);
      }
    }
    _passedRowIndex = index;
  }

  void _persistReadPosition([int? resCount]) {
    final count = resCount ?? _furthestRead;
    if (count <= 0) return;
    unawaited(_history.markRead(widget.threadKey, count));
  }

  /// 行が組み上がってから末尾へ運ぶ。返る Future はスクロールが終わったところ
  /// で完了する（[_noticeOwnPostAfter] の待ち合わせに使う）。
  ///
  /// 二度待つのは、増えたぶんを含んだ**寸法が届く**まで（一覧の寸法は行が
  /// 組み上がったフレームの後で届く）。古い寸法で測ると末尾までの残りを
  /// 見誤り、行き過ぎて跳ね返る。
  Future<void> _scrollToBottomSoon() async {
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scrollToBottom();
  }

  void _scrollToTopSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTop());
  }

  /// 送ったレスが映っていないときだけ、押せば飛べる知らせを出す。
  ///
  /// **画面は勝手に動かさない。** 途中まで読んで返信しただけなのに運ばれると、
  /// 読んでいた場所を探し直しになる。映っているなら知らせも要らない（送信時の
  /// 「書き込みました」で足りる）ので、見えなかったときだけ道を出す。
  ///
  /// 判定は [settled]（末尾追従のスクロール）が終わってから。動いている途中で
  /// 見ると、これから映るレスを「映っていない」と取り違える。
  Future<void> _noticeOwnPostAfter(Future<void> settled, int number) async {
    // 行が組み上がる（この更新の描画が済む）まで待ってから位置を見る。
    await WidgetsBinding.instance.endOfFrame;
    await settled;
    if (!mounted) return;
    final index = _indexForResNumber(number);
    if (index == null || _isRowVisible(index)) return;
    _showTopSnack(
      '書き込みが反映されました',
      actionLabel: '見る',
      onAction: () => _showRes(number),
    );
  }

  bool _isRowVisible(int index) {
    for (final p in _positions.itemPositions.value) {
      if (p.index != index) continue;
      return p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1;
    }
    return false;
  }

  /// レス [number] が見えるところへ運ぶ。
  ///
  /// 直前が**そのレスの引用行**ならそこから見せる。何への返信かごと目に入り、
  /// 送った内容を確かめられる。
  void _showRes(int number) {
    if (!mounted || !_itemScroll.isAttached) return;
    final index = _indexForResNumber(number);
    if (index == null) return;
    // 複数に返しているレスは引用行が続けて何本も並ぶので、その手前まで戻る。
    var target = index;
    while (target > 0) {
      final previous = _items[target - 1];
      if (previous is! ThreadTreeRow || !previous.quote) break;
      target--;
    }
    _itemScroll.scrollTo(
      index: target,
      alignment: 0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
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
      if (item is ThreadTreeRow && !item.quote) return '${item.res.number}';
    }
    for (var i = index + 1; i < _items.length; i++) {
      final item = _items[i];
      if (item is ThreadTreeRow && !item.quote) return '${item.res.number}';
    }
    return '';
  }

  /// 追従・書き込み後などに末尾へスクロールする。
  ///
  /// **行を指して頼まない**（[ItemScrollController.scrollTo] を使わない）。
  /// あれは「その行の上端を画面のここへ」としか頼めず、最後の行を上端に置くには
  /// その下に無いぶんまで送ることになる。スクロールは端で止まらずに越えていき、
  /// 跳ね返って戻る。新着のたびに画面が大きく上へ流れて戻って見えるのはこれ。
  ///
  /// 代わりに**端までの残りぶんだけ**送る。行き先が端そのものなので越えない。
  /// 残りが測れないとき（まだ寸法が来ていない）だけ、従来どおり行を指して頼む。
  Future<void> _scrollToBottom() {
    if (!_itemScroll.isAttached || _items.isEmpty) return Future.value();
    if (_contentFitsViewport()) {
      _scrollToTop();
      return Future.value();
    }
    const duration = Duration(milliseconds: 300);
    final room = _roomBelow();
    if (room != null) {
      if (room <= 0.5) return Future.value(); // すでに端に居る
      return _scrollOffset.animateScroll(
        offset: room,
        duration: duration,
        curve: Curves.easeOut,
      );
    }
    return _itemScroll.scrollTo(
      index: _items.length - 1,
      alignment: 0,
      duration: duration,
      curve: Curves.easeOut,
    );
  }

  /// 一覧の寸法を控える。中の別のスクロール（本文の選択など）は数えない。
  bool _onListMetrics(Notification notification) {
    if (notification is ScrollNotification && notification.depth == 0) {
      _listMetrics = notification.metrics;
    } else if (notification is ScrollMetricsNotification &&
        notification.depth == 0) {
      _listMetrics = notification.metrics;
    }
    return false;
  }

  /// 末尾までの残り（ピクセル）。分からなければ null。
  ///
  /// 遠い（画面 2 つぶんより先）ときは返さない。そこまで一息に送るのは
  /// [ItemScrollController.scrollTo] の仕事（間を飛ばして繋ぐ）で、こちらの
  /// 出番ではない。間の行が組まれていない＝端の位置も概算でしかない。
  double? _roomBelow() {
    final m = _listMetrics;
    if (m == null || !m.hasContentDimensions || !m.hasPixels) return null;
    final room = m.maxScrollExtent - m.pixels;
    if (room > m.viewportDimension * 2) return null;
    return room;
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

  /// スレ主（`>>1` を書いた人）の ID。ID の無い板や、`>>1` がまだ取れていない
  /// ときは null。
  ///
  /// ID は日付で変わるので、日をまたいだスレの後半では同じ人でも別 ID になり、
  /// 印が付かなくなる。それでも `>>1` 自身と、その日のスレ主の発言は拾えるので、
  /// 「付いていれば確かにスレ主」を満たす側に倒す。
  String? _threadOwnerId(List<Res> res) {
    if (res.isEmpty) return null;
    final first = res.first;
    // 先頭が 1 でないのは差分取得の途中など。誰がスレ主か分からないので出さない。
    return first.number == 1 ? first.id : null;
  }

  /// このレスをスレ主のものとして印を付けるか。
  bool _isThreadOwnerPost(Res res, String? ownerId) {
    if (res.number == 1) return true;
    return ownerId != null && res.id == ownerId;
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
      // 取りに行っている間に書き込み欄へ移っていたら奪い返さない（フォーカスの
      // 有無は取得を始めた時点のもので、返ってきた頃には変わっていることがある）。
      if (_composerFocus.hasFocus) return;
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

  /// NG に当たっていて、まだ「見る」を押されていないレスか。
  bool _isNgHidden(Res res) =>
      _ng.matches(res) && !_revealedNg.contains(res.number);

  /// 入力欄の返信先表示に出すレス。無い番号（まだ来ていない・打ち間違い）なら
  /// null を返して何も出さない。NG のレスは中身を伏せ、番号だけ出す。
  ///
  /// 画像は URL の文字列を落としてサムネイルにする（引用行と同じ扱い）。返信先
  /// が画像だけのレスだと、長い URL が 1 行を埋めるばかりで宛先を確かめられない。
  /// AA も同じく、1 行に潰さず縮めた絵で出す（[QuotedResBody.asciiArt]）。
  _ReplyTarget? _replyTargetFor(int number) {
    final res = _resByNumber(number);
    if (res == null) return null;
    if (_isNgHidden(res)) return _ReplyTarget(number, '');
    final body = quotedResBody(res);
    return _ReplyTarget(
      number,
      body.excerpt,
      asciiArt: body.asciiArt,
      images: body.images,
      blurImages: _guroMasked.contains(number),
    );
  }

  /// 「グロ」注意が付いたレスの番号。[_state] の更新ごとに数え直す。
  ///
  /// 全レスの本文を走査するので、入力のたびに呼ばれる返信先の帯のために毎回は
  /// 数えない。
  Set<int> _guroMaskedCache = const {};
  List<Res>? _guroMaskedFor;

  Set<int> get _guroMasked {
    final res = _state.res;
    if (!identical(_guroMaskedFor, res)) {
      _guroMaskedFor = res;
      _guroMaskedCache = guroMaskedResNumbers(res);
    }
    return _guroMaskedCache;
  }

  Res? _resByNumber(int number) {
    final res = _state.res;
    // dat は 1 始まりの連番なので、まずは位置で当てる。
    if (number >= 1 &&
        number <= res.length &&
        res[number - 1].number == number) {
      return res[number - 1];
    }
    for (final r in res) {
      if (r.number == number) return r;
    }
    return null;
  }

  int? _indexForResNumber(int number) {
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item is ThreadTreeRow && !item.quote && item.res.number == number) {
        return i;
      }
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
      _ownPostToShow = res.number; // 番号が取れないサーバでもここで分かる
    }
    _pendingOwnPosts -= count;
  }

  void _showIdPosts(String id) {
    final posts = _state.res.where((r) => r.id == id).toList();
    _showPostsSheet('ID:$id  ${posts.length}レス', posts, id: id);
  }

  /// 名前欄のワッチョイタップ。このスレでの同じワッチョイの発言をまとめて出す。
  ///
  /// ID は日付が変わると別物になるが、ワッチョイは回線・端末が同じなら数日
  /// 変わらない。日をまたぐスレでは「ID が違うだけの同じ人」がここで繋がる
  /// ——ID の一覧では追えない繋がりなので、別の導線として要る。
  void _showWacchoiPosts(String wacchoi) {
    final posts = _state.res
        .where((r) => wacchoiOf(htmlToText(r.name)) == wacchoi)
        .toList();
    _showPostsSheet(
      'ワッチョイ:$wacchoi  ${posts.length}レス',
      posts,
      wacchoi: wacchoi,
    );
  }

  /// NG 設定が変わったら再描画する。以前タップで表示したレスの一時表示は解除して、
  /// 新しいルールで判定し直す。
  void _onNgChanged() {
    if (!mounted) return;
    _markerKindCache.clear(); // あぼーん判定が変わるのでスレマップも組み直す
    setState(_revealedNg.clear);
  }

  /// 表示設定（並べ方、リンクのカード表示）が変わったら組み直す。
  ///
  /// 行の並びや高さが変わるので、今いちばん上に見えているレスを覚えておいて、
  /// 組み直したあとで同じレスへ戻す。設定を切り替えただけで読んでいた場所を
  /// 見失うのを避ける。
  void _onViewSettingsChanged() {
    if (!mounted) return;
    final anchor = _topVisibleResNumber();
    // 並べ方が変われば行の並びも変わる。通り過ぎた行の数え直しから始める。
    _passedRowIndex = -1;
    setState(() {});
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScroll.isAttached) return;
      final index = _indexForResNumber(anchor);
      if (index != null) _itemScroll.jumpTo(index: index, alignment: 0);
    });
  }

  /// いま画面の一番上に見えているレスの番号（引用行・新着ラインは飛ばす）。
  int? _topVisibleResNumber() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty || _items.isEmpty) return null;
    int? topIndex;
    for (final p in positions) {
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) continue;
      if (topIndex == null || p.index < topIndex) topIndex = p.index;
    }
    if (topIndex == null) return null;
    for (var i = topIndex; i < _items.length; i++) {
      final item = _items[i];
      if (item is ThreadTreeRow && !item.quote) return item.res.number;
    }
    return null;
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
  /// 返信・全体コピー・本文コピー・生表示・NGワードの操作を並べる。
  ///
  /// ID の操作（コピー・必死チェッカー・NG）はここには置かない。ID アイコンを
  /// タップすれば同じ導線が同一 ID 一覧の頭に出るので、長押しメニューにも並べると
  /// ただ長くなって、レスそのものへの操作が埋もれる。
  ///
  /// [onReply] を渡すと返信の宛先をそちらの入力欄にできる（会話シートなど、
  /// main の入力欄がシートに隠れている場面用）。
  void _showResActions(Res res, {void Function(int)? onReply}) {
    final idCount = _idCounts(_state.res)[res.id] ?? 1;
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
                    // 本文を選べるのはここだけ。返信スワイプの掛かっていない
                    // 場所なので、なぞる操作を選択に使い切れる。
                    bodySelectable: true,
                    isOwn: _history.isOwnPost(widget.threadKey, res.number),
                    isThreadOwner: _isThreadOwnerPost(
                      res,
                      _threadOwnerId(_state.res),
                    ),
                    isReplyToOwn: _isReplyToOwnPost(res),
                    blurImages: _guroMasked.contains(res.number),
                    linkPreviews: _view.linkPreviews,
                    resLayout: _view.resLayout,
                    defaultName: widget.defaultName,
                  ),
                ),
              ),
              const Divider(height: 1),
              // 返信は左スワイプが本筋だが、見えない操作なのでここにも残す。
              // 副題でその左スワイプ自体を教える（このメニューを開いた人は、
              // 今まさに返信の入り口を探している）。書き込めないスレ・板では
              // 出さない。
              if (_canWrite)
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: Text('>>${res.number} に返信'),
                  subtitle: const Text('レスを左へスワイプしても入ります'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    (onReply ?? _reply)(res.number);
                  },
                ),
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
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('クラシック表示で見る'),
                subtitle: const Text('サムネイルもカードも挟まない、昔ながらの1行ヘッダの表示'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showClassicRes(res);
                },
              ),
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

  /// レスを昔ながらの掲示板の見た目で出す。
  ///
  /// 通常の表示はかなり手を入れている。画像や動画の URL はサムネイルへ、リンクは
  /// OGP カードへ差し替えて URL の文字列自体を畳み、ヘッダは名前を省いて ID を
  /// 絵にしている。ふだんはその方が読みやすいが、
  ///  - サムネイルになった URL を実際に確かめたい／控えたい
  ///  - 妙な表示になるレスが、元からそう書かれているのかこちらの整形のせいなのか
  /// といったときに、差し替えを挟まない姿を見る手立てが要る。
  ///
  /// 出し方は read.cgi が昔から出しているものに合わせる。
  ///
  /// ```
  /// 1 名前:エッヂの名無し (L20 xxxx) Mail:sage 投稿日:2026/08/06(木) 22:49:24.219 ID:xxxx
  ///
  /// 本文
  /// ```
  ///
  /// 日付から後ろは [Res.rawDateField]（日付・ID・BE を切り分ける前の欄）をその
  /// まま置くだけで、掲示板の表記と同じになる。
  ///
  /// HTML は効かせる（[datHtmlSpans]）。dat の各項目はブラウザに流し込めばそう
  /// 見える HTML として書かれていて、`<br>` や `</b>`、`<a href=…>` が文字として
  /// 並ぶのは元の姿ではない。**差し替えないのはアプリの整形の方**で、掲示板
  /// そのものの見え方には合わせる。
  void _showClassicRes(Res res) {
    // 5ch / エッヂの日付欄は `日付 ID:xxx` がひと続き。したらばは ID が別項目
    // なので、含まれていなければ後ろに足して同じ 1 行にする。
    var posted = res.rawDateField.isNotEmpty ? res.rawDateField : res.dateText;
    if (res.id case final id? when !posted.contains('ID:')) {
      posted = posted.isEmpty ? 'ID:$id' : '$posted ID:$id';
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        final link = scheme.primary;
        final header = <InlineSpan>[
          TextSpan(text: '${res.number} 名前:'),
          ...datHtmlSpans(res.name, linkColor: link),
          const TextSpan(text: ' Mail:'),
          ...datHtmlSpans(res.mail, linkColor: link),
          TextSpan(text: ' 投稿日:$posted'),
        ];
        final whole = TextSpan(
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          children: [
            // ヘッダは 1 行に詰める。折り返しても本文と混ざらないよう、一段
            // 小さく控えめな色で置く。
            TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              children: [
                ...header,
                const TextSpan(text: '\n'),
              ],
            ),
            const TextSpan(text: '\n'),
            ...datHtmlSpans(res.body, linkColor: link),
          ],
        );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('クラシック表示', style: theme.textTheme.titleMedium),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    // ヘッダと本文をひと続きの 1 つのテキストにする。別々の
                    // SelectableText に分けると選択が境目で切れて、ヘッダごと
                    // なぞって持っていけない。
                    child: SelectableText.rich(whole),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.copy_all),
                  title: const Text('この形でコピー'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _copyText(whole.toPlainText(), 'レスをコピーしました');
                  },
                ),
              ],
            ),
          ),
        );
      },
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

  /// レス群をボトムシートで一覧表示する（同一 ID・同一ワッチョイ・返信一覧で共用）。
  ///
  /// [id] を渡すと、必死チェッカー導線と ID コピー・NG の操作行を上部に出す。
  /// [wacchoi] を渡すと、ワッチョイのコピー・NG の操作行を出す。
  void _showPostsSheet(
    String title,
    List<Res> posts, {
    String? id,
    String? wacchoi,
  }) {
    final idCounts = _idCounts(_state.res);
    final idOrdinals = _idOrdinals(_state.res);
    final replyCountByNumber = replyCounts(_state.res);
    final guroMasked = _guroMasked;
    final ownerId = _threadOwnerId(_state.res);
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
                child: Row(
                  children: [
                    // ID 一覧のときだけ、その ID の identicon を大きく出す。
                    // ここは「こいつ誰だ」と思って開く場所なので、レス一覧の
                    // 密度を気にせず絵を大きくできる。ヘッダのチップと同じ絵の
                    // 拡大版なので、一覧に戻ったときの照合もこれで効く。
                    //
                    // チップにある連投数のリングは付けない。レス数はすぐ右の
                    // タイトルに数字で出ているので、輪で二度言う必要がない。
                    if (id != null) ...[
                      IdIcon(id: id, size: 40),
                      const SizedBox(width: 12),
                    ]
                    // ワッチョイには identicon を出さない。同じ絵の作り方でも
                    // ID の絵とは別物になるので、並べて見た人が「同じ人なのに
                    // 絵が違う」と受け取ってしまう。人ではなく回線・端末を指す
                    // ものなので、指紋の記号に留める。
                    else if (wacchoi != null) ...[
                      Icon(
                        Icons.fingerprint,
                        size: 32,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
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
              if (wacchoi != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => _copyText(wacchoi, 'ワッチョイをコピーしました'),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('ワッチョイをコピー'),
                      ),
                      if (_ng.isNgWacchoi(wacchoi))
                        TextButton.icon(
                          onPressed: () {
                            _ng.removeWacchoi(wacchoi);
                            setSheetState(() {});
                            _showSnack('ワッチョイのNGを解除しました');
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
                            _ng.addWacchoi(wacchoi);
                            setSheetState(() {});
                            // ID の NG と違って日付をまたいでも効き続ける。
                            // 効き目の違いはここで伝えないと分からない。
                            _showSnack('ワッチョイをNGにしました（スレをまたいで効きます）');
                          },
                          icon: const Icon(Icons.block, size: 18),
                          label: const Text('ワッチョイをNG'),
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
                    // 返信先は main の入力欄。このシートに隠れたままだと打てない
                    // ので、閉じてから `>>N` を入れる。
                    void replyAndClose(int number) {
                      Navigator.pop(context);
                      _reply(number);
                    }

                    if (_ng.matches(post) &&
                        !_revealedNg.contains(post.number)) {
                      return _NgPlaceholder(
                        number: post.number,
                        onReveal: () =>
                            setSheetState(() => _revealedNg.add(post.number)),
                        onLongPress: () =>
                            _showResActions(post, onReply: replyAndClose),
                      );
                    }
                    return SwipeToReply(
                      onReply: () => replyAndClose(post.number),
                      child: PostItem(
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
                        onLongPress: () =>
                            _showResActions(post, onReply: replyAndClose),
                        isOwn: _history.isOwnPost(
                          widget.threadKey,
                          post.number,
                        ),
                        isThreadOwner: _isThreadOwnerPost(post, ownerId),
                        isReplyToOwn: _isReplyToOwnPost(post),
                        blurImages: guroMasked.contains(post.number),
                        linkPreviews: _view.linkPreviews,
                        resLayout: _view.resLayout,
                        defaultName: widget.defaultName,
                      ),
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

  /// 会話シートの見出しに出す対象レスの並び（[centers] は昇順・重複なし）。
  ///
  /// `>>3-5` のような連続した並びは `3-5` と縮める。`>>1,5,9` のように飛んだ
  /// 並びを縮めると別のレスまで含んでいるように読めるので、そちらは番号を並べる。
  /// 見出しが折り返さない程度で打ち切る。
  static String _conversationRangeLabel(List<int> centers) {
    if (centers.length == 1) return '${centers.single}';
    if (centers.last - centers.first + 1 == centers.length) {
      return '${centers.first}-${centers.last}';
    }
    const shown = 5;
    if (centers.length <= shown) return centers.join(',');
    return '${centers.take(shown).join(',')}…';
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
    final guroMasked = _guroMasked;
    final title = '会話 #${_conversationRangeLabel(centers)}';
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
          linkPreviews: _view.linkPreviews,
          resLayout: _view.resLayout,
          onTapId: _showIdPosts,
          onTapWacchoi: _showWacchoiPosts,
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
          composer: _composer,
          replyTargetFor: _replyTargetFor,
          // 返信先を押したときは、シートを閉じて開き直すのではなくレスの操作
          // メニューを重ねる。書きかけを抱えたまま「誰に返しているか」を確かめ
          // たいだけなので、閉じると今いる会話まで畳んでしまう。
          onTapReplyTarget: (number, {onReply}) {
            final target = _resByNumber(number);
            if (target != null) _showResActions(target, onReply: onReply);
          },
          onSend: _submit,
          onPickAndUploadImages: _pickAndUploadImages,
          onPickAndUploadFile: _pickAndUploadFile,
          onShowActions: _showResActions,
          isOwnPost: (n) => _history.isOwnPost(widget.threadKey, n),
          isThreadOwner: (post) =>
              _isThreadOwnerPost(post, _threadOwnerId(res)),
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

    // 中心レスの手前は、返信先をたどれるだけたどって載せる。直接の返信先だけを
    // 出すと会話の途中から読み始めることになり、その前が何の話だったのかを見る
    // のに開き直しを繰り返すことになる。**始まりまで積んでおいて、上へ遡るだけ
    // で読める**ようにする。
    final ancestorNumbers = _conversationAncestors(
      centerPosts,
      byNumber,
      centers,
    );
    for (final n in ancestorNumbers) {
      add(n, 0);
    }

    // 手前のレスは何世代さかのぼっても字下げしない。世代のぶんだけ下げると中心
    // レス——読みに来た当のもの——が右へ押し込まれて本文が潰れる。誰への返信かは
    // 各レスの返信先の見出し（[_ConversationEntry.refs]）で読める。
    final centerDepth = ancestorNumbers.isEmpty ? 0 : 1;
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

  /// 会話シートに載せる「中心レスより手前」のレス番号を、返信先をたどって集める。
  ///
  /// 近い世代から順に採り、[_maxConversationAncestorLevels] 世代
  /// ・[_maxConversationAncestors] 件で打ち切る。**複数に返しているレス**を通ると
  /// 一世代が枝分かれして際限なく広がるので、件数の頭打ちで抑える。近い方から
  /// 埋まるので、落ちるのは遠い枝＝会話の本筋から外れたところになる。
  ///
  /// 返す並びは番号順＝会話の起きた順。
  List<int> _conversationAncestors(
    List<int> centerPosts,
    Map<int, Res> byNumber,
    Set<int> centers,
  ) {
    final found = <int>{};
    var frontier = centerPosts;
    for (var level = 0; level < _maxConversationAncestorLevels; level++) {
      final next = <int>[];
      for (final n in frontier) {
        for (final ref in _referencedNumbers(byNumber[n]!)) {
          if (!byNumber.containsKey(ref)) continue;
          if (centers.contains(ref)) continue;
          if (!found.add(ref)) continue;
          if (found.length >= _maxConversationAncestors) {
            return found.toList()..sort();
          }
          next.add(ref);
        }
      }
      if (next.isEmpty) break;
      frontier = next;
    }
    return found.toList()..sort();
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
      final row = items[i];
      if (row is! ThreadTreeRow) {
        markers.add(ThreadMapMarker(i, ThreadMapMarkerKind.newArrival));
        continue;
      }
      // 引用行は同じレスの二度目の登場なので、目印は本体の行にだけ出す。
      if (row.quote) continue;
      final item = row.res;
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

  /// [url] が知っている板のスレリンクなら、そのスレをアプリ内で開いて true。
  /// 対象外なら false（呼び出し側でブラウザへ回す）。
  ///
  /// 自板のスレはそのまま重ねて開く。別板のスレ（[ThreadLinks] が板一覧から
  /// 見つけたもの）は、その板の既読履歴を読み込んでから開く。
  bool _openThreadLink(Uri url) {
    if (url.host == widget.endpoints.host) {
      final ref = parseThreadUrl(url);
      if (ref != null && ref.board == widget.endpoints.boardKey) {
        if (ref.threadKey == widget.threadKey) {
          // 今開いているスレ自身へのリンク。開き直さず、あれば先頭へ戻す程度に
          // 留める。
          _showSnack('このスレです');
          return true;
        }
        Navigator.of(context).push(
          _threadLinkRoute(
            threadKey: ref.threadKey,
            endpoints: widget.endpoints,
            history: _history,
            defaultName: widget.defaultName,
          ),
        );
        return true;
      }
    }

    final target = ThreadLinks.targetOf(url);
    if (target == null) return false;
    unawaited(_openBoardThread(target));
    return true;
  }

  /// 別板のスレを開く。既読履歴は板ごとに分かれているので、その板のぶんを
  /// 読み込んでから重ねる（初めて開く板だけ待ちが入る）。
  Future<void> _openBoardThread(ThreadLinkTarget target) async {
    final board = target.board;
    final history =
        ReadHistory.cachedFor(board) ?? await ReadHistory.forBoard(board);
    if (!mounted) return;
    Navigator.of(context).push(
      _threadLinkRoute(
        threadKey: target.threadKey,
        endpoints: EdgeEndpoints.forBoard(board),
        history: history,
        defaultName: board.defaultName,
        // カードで既にスレタイが取れていれば、開いた瞬間から出せる。まだなら
        // 空のまま開いて dat の 1 レス目から埋める。
        title: ThreadLinks.cachedTitle(target) ?? '',
      ),
    );
  }

  PageRoute<void> _threadLinkRoute({
    required String threadKey,
    required EdgeEndpoints endpoints,
    required ReadHistory history,
    String? defaultName,
    String title = '',
  }) {
    return SwipeBackPageRoute<void>(
      pageBuilder: (context, animation, secondaryAnimation) => ThreadScreen(
        threadKey: threadKey,
        // タイトルは開くまで不明なことが多い。dat の 1 レス目から補完する。
        threadTitle: title,
        fetcher: _fetcher,
        endpoints: endpoints,
        pollInterval: widget.pollInterval,
        authStore: _authStore,
        authLauncher: widget.authLauncher,
        readHistory: history,
        ngStore: _ng,
        imagePicker: _imagePicker,
        imgurUploader: _imgurUploader,
        imageUploadSettings: _imageUploadSettings,
        pickAndUploadImages: widget.pickAndUploadImages,
        defaultName: defaultName,
      ),
    );
  }

  /// スレ画面の通知は入力欄や末尾レスに重ならないよう、上部へ出す。
  void _showSnack(String message) {
    _showTopSnack(message);
  }

  /// [actionLabel] を渡すと押せるボタンが付く。押すまで待つぶん、知らせだけの
  /// ときより長く出す。ボタン無しのスナックはこれまで通り操作を透かす
  /// （[IgnorePointer]）ので、下のレスをそのまま触れる。
  void _showTopSnack(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _topSnackTimer?.cancel();
    _topSnackEntry?.remove();
    final overlay = Overlay.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasAction = actionLabel != null && onAction != null;
    _topSnackEntry = OverlayEntry(
      builder: (context) {
        final bar = Material(
          color: scheme.inverseSurface,
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            // ボタンは自前で余白を持つので、その側だけ詰めて高さを揃える。
            padding: hasAction
                ? const EdgeInsets.fromLTRB(16, 4, 8, 4)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
                if (hasAction)
                  TextButton(
                    onPressed: () {
                      _dismissTopSnack();
                      onAction();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.inversePrimary,
                    ),
                    child: Text(actionLabel),
                  ),
              ],
            ),
          ),
        );
        return Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          left: 12,
          right: 12,
          child: hasAction ? bar : IgnorePointer(child: bar),
        );
      },
    );
    overlay.insert(_topSnackEntry!);
    _topSnackTimer = Timer(
      Duration(seconds: hasAction ? 5 : 2),
      _dismissTopSnack,
    );
  }

  void _dismissTopSnack() {
    _topSnackTimer?.cancel();
    _topSnackTimer = null;
    _topSnackEntry?.remove();
    _topSnackEntry = null;
  }

  // ---- 書き込み ----

  Future<List<Uri>> _pickAndUploadImages() async {
    final injected = widget.pickAndUploadImages;
    if (injected != null) return injected();
    return _uploader.pickAndUploadImages(
      _showSnackIfMounted,
      prepare: (picked) async =>
          mounted ? prepareImagesForUpload(context, picked) : picked,
    );
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
        _ownPostToShow = resNum;
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
        toolbarHeight: _ThreadTitleBar.barHeight,
        // 戻るとスレタイの間は既定（leading 56＋titleSpacing 16）だと 32px も
        // 空き、そのぶんスレタイの折り返しが早まる。押せる大きさ（48）は保った
        // まま枠を詰め、間隔もタイトル側の内側の余白（4）だけにする。
        leadingWidth: 48,
        titleSpacing: 0,
        // ルートとして開かれていないときは自前で戻るを出す（既定の実装は
        // ルートが積まれているかどうかで判断するため、ここでは出てこない）。
        leading: widget.onClose == null
            ? null
            : BackButton(onPressed: widget.onClose),
        // タイトルは重要なので AppBar 内でできるだけ読ませる（入りきらない
        // ぶんは字を落として行を足す＝[_ThreadTitleBar]）。それでも溢れる
        // 極端に長いものは、これまで通りタップで全文を出す。
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
            : _ThreadTitleBar(
                title: _effectiveTitle.isEmpty
                    ? 'スレッド'
                    : decodeEntities(_effectiveTitle),
                status: _loading || _error != null || _notFound
                    ? null
                    : _statusLabel == null
                    ? '${_state.res.length}レス'
                    : '${_state.res.length}レス ・ $_statusLabel',
                onTap: _showFullTitle,
              ),
        // 取得中の細い線は AppBar の下端に**重ねて**出す。bottom に置くと出て
        // いる間だけ AppBar が 2px 高くなり、本文がそのぶん下がって戻る＝
        // ポーリングのたびにレスが上下に揺れる。
        //
        // 置き場所（flexibleSpace）は取得中かどうかに関わらず**常に埋める**。
        // AppBar は flexibleSpace が null かどうかで木の形を変える（非 null の
        // ときだけ Stack と Material を挟む）ので、ポーリングのたびに null と
        // 行き来させると title ごと作り直しになる。作り直されると検索欄の
        // [EditableText] が state から作り直され、キーボードとの接続が張り直
        // されて、変換中の文字・選択・カーソルが飛ぶ。中身だけ差し替える。
        flexibleSpace: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 2,
            child: _polling
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
        ),
      ),
      body: Column(
        children: [
          // 戻るスワイプは一覧側でだけ受ける。入力欄の上の横ドラッグはカーソル
          // 移動・文字選択なので、そちらへ触らない。
          Expanded(child: BackSwipe(child: _body())),
          _Composer(
            key: _composerKey,
            controller: _composer,
            focusNode: _composerFocus,
            onSend: _submit,
            onPickAndUploadImages: _pickAndUploadImages,
            onPickAndUploadFile: _pickAndUploadFile,
            enabled: _canWrite,
            replyTargetFor: _replyTargetFor,
            onTapReplyTarget: (number) {
              final target = _resByNumber(number);
              if (target != null) _showResActions(target);
            },
          ),
        ],
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
    final guroMasked = _guroMasked;
    final threadOwnerId = _threadOwnerId(res);
    // 「新着」の境界（前回位置）。0 か総数以上なら新着ライン無し。
    final hasNewArrival = _openCount > 0 && _openCount < res.length;

    // 行データを組む（[ThreadTreeRow] か 新着ライン）。インデックス指定
    // スクロールのため Widget ではなくデータで持ち、[_items] に保存する。
    final items = <Object>[];
    // ツリーに固めるのは新着ラインより上（＝開いた時点まで）。新着ラインが
    // 無ければ全部が対象。あとから来たぶんはツリーへ挿さず下へ積む。番号順では
    // 並びが変わらないので、境界は新着ラインを挟む位置を決めるだけ。
    final settledCount = hasNewArrival ? _openCount : res.length;
    final layout = _view.layout == ThreadLayout.tree
        ? layOutThreadTree(res, settledCount: settledCount)
        : layOutFlatRows(res, settledCount: settledCount);
    items.addAll(layout.settled);
    if (hasNewArrival) items.add(const _NewArrivalMarker());
    items.addAll(layout.arrivals);
    _items = items;
    // 着地位置は行が組み上がって初めて出せる（ツリーではレス数と行位置が
    // 一致しない）。初回の一度きり。
    if (!_landingResolved) {
      _landingResolved = true;
      _initialIndex = _landingIndex(items);
    }

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
          // 一覧の寸法はここでしか受け取れない。中身が伸びただけのときも来る
          // ので、行が増えた直後でも末尾までの残りが分かる。
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _onListMetrics,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onListMetrics,
              child: ScrollablePositionedList.builder(
                itemScrollController: _itemScroll,
                scrollOffsetController: _scrollOffset,
                itemPositionsListener: _positions,
                initialScrollIndex: _initialIndex,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final row = items[i];
                  if (row is! ThreadTreeRow) return const _NewArrivalLine();
                  final item = row.res;
                  final ngHidden = _isNgHidden(item);
                  // 返信先の再掲。NG のレスはここでも出さない（行だけ畳む）。
                  if (row.quote) {
                    if (ngHidden) return const SizedBox.shrink();
                    // 直前も引用行なら詰めて重ねる（複数に返しているレス）。
                    // NG で畳んだ行の下では詰めない——上に何も無いので、間が
                    // 空くのではなく前のレスに貼り付いてしまう。
                    final previous = i > 0 ? items[i - 1] : null;
                    final joins =
                        previous is ThreadTreeRow &&
                        previous.quote &&
                        !_isNgHidden(previous.res);
                    // 引用行もそのレスと同じ深さに置く（ツリーの途中に挟まる
                    // 「親以外の返信先」が、どのレスに付いているかを揃える）。
                    return ThreadTreeTier(
                      depth: row.depth,
                      child: QuotedResRow(
                        res: item,
                        joinsPrevious: joins,
                        onTap: () => _showConversation(
                          item.number,
                          focusNumber: item.number,
                        ),
                        blurImages: guroMasked.contains(item.number),
                      ),
                    );
                  }
                  // レス間は線を引かず、スレ一覧と同じく余白だけで区切る。各レスは
                  // 番号・名前の見出し行が始点の目印になる。
                  if (ngHidden) {
                    return ThreadTreeTier(
                      depth: row.depth,
                      child: _NgPlaceholder(
                        number: item.number,
                        onReveal: () =>
                            setState(() => _revealedNg.add(item.number)),
                        onLongPress: () => _showResActions(item),
                      ),
                    );
                  }
                  // 目印（自分宛・検索の現在位置）は字下げ帯の色に移す。深さ 0
                  // には字下げ帯が無いので、そこだけはレス側に描かせる。
                  final isMatch = item.number == currentMatchNumber;
                  final isToOwn =
                      _isReplyToOwnPost(item) &&
                      !_history.isOwnPost(widget.threadKey, item.number);
                  final scheme = Theme.of(context).colorScheme;
                  final accent = isMatch
                      ? scheme.tertiary
                      : isToOwn
                      ? scheme.primary
                      : null;
                  // 字下げ帯は行の持ち物なので、スワイプはツリーの外側から掛ける。
                  // PostItem だけを包むと本文が自分の帯の下から抜け出す。
                  return SwipeToReply(
                    onReply: () => _reply(item.number),
                    child: ThreadTreeTier(
                      depth: row.depth,
                      accent: row.depth > 0 ? accent : null,
                      child: PostItem(
                        res: item,
                        nested: row.depth > 0,
                        idCount: idCounts[item.id] ?? 1,
                        idOrdinal: idOrdinals[item.number] ?? 1,
                        onTapId: _showIdPosts,
                        onTapWacchoi: _showWacchoiPosts,
                        onTapRes: _showResPopup,
                        onTapResRange: _showConversationRange,
                        onTapUrl: _openUrl,
                        replyCount: replies[item.number] ?? 0,
                        onTapReplies: _showReplies,
                        onLongPress: () => _showResActions(item),
                        isOwn: _history.isOwnPost(
                          widget.threadKey,
                          item.number,
                        ),
                        isThreadOwner: _isThreadOwnerPost(item, threadOwnerId),
                        isReplyToOwn: _isReplyToOwnPost(item),
                        showAccentBar: row.depth <= 0,
                        blurImages: guroMasked.contains(item.number),
                        linkPreviews: _view.linkPreviews,
                        resLayout: _view.resLayout,
                        highlightQuery: searchQuery,
                        isCurrentMatch: item.number == currentMatchNumber,
                        defaultName: widget.defaultName,
                      ),
                    ),
                  );
                },
              ),
            ),
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

/// AppBar のスレタイと、その下の「Nレス ・ 取得時刻」の行。
///
/// スレタイは長さがまちまちで、固定サイズの 2 行では入りきらないものが珍しく
/// ない（エッヂの実況スレは 40 字を超えるものが多い）。**入る大きさまで字を
/// 落とし、それでも入らなければ 3 行目まで使う**。優先するのは字の大きさで、
/// 行を足すのは同じ大きさで 2 行に入らないときだけ——1 行の情報量より、まず
/// 読める字であることを取る。
///
/// 収まり判定は [TextPainter] で実測する。[FittedBox] のように見た目だけ縮める
/// 方法は下限が無く、長いスレタイで字が潰れて読めなくなる。高さの持ち分は
/// [barHeight] から自分の余白を引いて求めるので、端末の文字サイズ設定を大きく
/// している人でも AppBar から溢れない（そのぶん行数か字の大きさが減る）。
///
/// **高さは制約から取れない**——AppBar は title を高さ無制限で測ってから中央へ
/// 置く（`_AppBarTitleBox`）ので、`LayoutBuilder` に降りてくる `maxHeight` は
/// `toolbarHeight` ではなく infinity になる。ここを制約任せにしていた頃は、
/// 3 行のスレタイが AppBar を 1px はみ出して上下が削れていた。
class _ThreadTitleBar extends StatelessWidget {
  const _ThreadTitleBar({
    required this.title,
    required this.status,
    required this.onTap,
  });

  /// AppBar の高さ（`toolbarHeight`）。中身の収まりを決めるのはこの値なので、
  /// AppBar と同じ定数をここから渡す。
  static const barHeight = 80.0;

  final String title;

  /// タイトルの下に出す小さい行。取得前・エラー時は null（行ごと出さない）。
  final String? status;

  final VoidCallback onTap;

  /// 大きい順に試す文字サイズ。
  ///
  /// 上限の 15 は本文（`titleMedium` 相当）より気持ち小さいくらいで、2〜3 行の
  /// 塊として読みやすい大きさ。**16 だと 1 行に入る字数が足りず、短めのスレタイ
  /// でもすぐ折り返していた**ので 1 段落とした。下限の 13 は、3 行にしても
  /// `toolbarHeight: 80` に収まる大きさでもある。
  static const _sizes = [15.0, 14.0, 13.0];

  /// 使ってよい行数（少ない方を優先する）。
  static const _lineCounts = [2, 3];

  static const _lineHeight = 1.22;

  /// 押せる範囲（＝タップの反応が出る枠）の内側の余白。
  static const _padding = EdgeInsets.symmetric(vertical: 4, horizontal: 4);

  /// 押せる範囲と AppBar の端との間隔。右は画面の端（actions が無く
  /// `titleSpacing` も 0 なので、空けないと長いスレタイが端に貼り付く）、上は
  /// ステータスバー側との間。**枠の外側**に置く（内側に足すと、タップの反応が
  /// 端まで伸びてしまう）。どちらも「触れていない」と分かるだけの最小限。
  static const _margin = EdgeInsets.only(top: 3, right: 8);

  static TextPainter _painter(
    String text,
    TextStyle style,
    TextScaler scaler,
    double maxWidth,
    int maxLines,
  ) => TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: maxLines,
    textScaler: scaler,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);

  /// [budget] の高さ・[maxWidth] の幅に収まる（文字サイズ, 行数）を選ぶ。
  ///
  /// どの組み合わせでも入りきらないときは、**高さには収まる中でいちばん多く
  /// 読める組み合わせ**（＝最小サイズの最大行数）を返す。呼ぶ側で末尾を省く。
  static (double, int) _fit(
    String text,
    TextStyle base,
    TextScaler scaler,
    double maxWidth,
    double budget,
  ) {
    (double, int)? fallback;
    for (final size in _sizes) {
      for (final lines in _lineCounts) {
        final painter = _painter(
          text,
          base.copyWith(fontSize: size),
          scaler,
          maxWidth,
          lines,
        );
        final tooTall = painter.height > budget;
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        // 高さが尽きたら、この字で行を足しても入らない。次の小さい字へ。
        if (tooTall) break;
        if (!overflows) return (size, lines);
        fallback = (size, lines);
      }
    }
    return fallback ?? (_sizes.last, 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final inherited = DefaultTextStyle.of(context).style;
    // 実測に使うので、AppBar から降りてくる既定（フォントなど）に重ねた
    // 「実際に描かれる」スタイルを組み立てる。
    final titleStyle = inherited.merge(
      const TextStyle(fontWeight: FontWeight.w600, height: _lineHeight),
    );
    final status = this.status;
    final statusStyle = inherited.merge(
      theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    return Padding(
      padding: _margin,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: _padding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 高さは AppBar から降りてこない（クラスの説明を参照）ので、
              // 自分の余白を引いて求める。何かに挟まれて縦が狭くなっている
              // ときだけ、降りてきた制約の方を採る。
              var budget = math.min(
                constraints.maxHeight,
                barHeight - _margin.vertical - _padding.vertical,
              );
              if (status != null) {
                final painter = _painter(
                  status,
                  statusStyle,
                  scaler,
                  constraints.maxWidth,
                  1,
                );
                budget -= painter.height;
                painter.dispose();
              }
              final (size, lines) = _fit(
                title,
                titleStyle,
                scaler,
                constraints.maxWidth,
                budget,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle.copyWith(fontSize: size),
                  ),
                  if (status != null)
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: statusStyle,
                    ),
                ],
              );
            },
          ),
        ),
      ),
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

/// 開いたときの着地位置の決め方。行インデックスは行を組んでから決まる。
enum _Landing { top, newArrival, bottom }

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

/// 会話シートで中心レスより手前へ遡る世代の上限。
///
/// 会話は長くても数往復で、それより前は話題が変わっていることが多い。際限なく
/// 遡っても、読みに来た当のレスが下へ押し流されるだけになる。
const int _maxConversationAncestorLevels = 6;

/// 会話シートに載せる「手前のレス」の件数の上限（[_maxConversationAncestorLevels]
/// より手前に効く）。枝分かれで膨らんだときの頭打ち。
const int _maxConversationAncestors = 12;

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
    required this.linkPreviews,
    required this.resLayout,
    required this.onTapId,
    required this.onTapWacchoi,
    required this.onTapRes,
    required this.onTapResRange,
    required this.onTapReplies,
    required this.onTapUrl,
    required this.composer,
    required this.replyTargetFor,
    required this.onTapReplyTarget,
    required this.onSend,
    required this.onPickAndUploadImages,
    required this.onPickAndUploadFile,
    required this.onShowActions,
    required this.isOwnPost,
    required this.isThreadOwner,
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

  /// 行を単独で占めるリンクを OGP カードにするか（[PostItem.linkPreviews]）。
  final bool linkPreviews;

  /// レス 1 件の組み方（[PostItem.resLayout]）。
  final ResLayout resLayout;
  final ValueChanged<String> onTapId;
  final ValueChanged<String> onTapWacchoi;
  final void Function(int source, int target) onTapRes;
  final void Function(int source, List<int> targets) onTapResRange;
  final ValueChanged<int> onTapReplies;
  final ValueChanged<Uri> onTapUrl;

  /// 書きかけのレス。スレ画面の入力欄と**同じ** [TextEditingController] を受け取る。
  ///
  /// 下書きはスレに 1 つで、見ている場所（番号順の一覧・会話シート）では変わら
  /// ない。会話を開いた拍子に書きかけが消えたり、シートで書いたぶんが閉じた
  /// 途端に無くなったりしないようにするため。
  final TextEditingController composer;

  /// 本文の `>>N` から返信先を引く（[_Composer.replyTargetFor]）。
  final _ReplyTarget? Function(int number) replyTargetFor;

  /// 返信先の行を押したとき。そのレスの操作メニュー（[onShowActions] と同じもの）
  /// をこのシートの上に重ねる。返信はシート内の入力欄へ渡す。
  final void Function(int number, {void Function(int)? onReply})
  onTapReplyTarget;

  /// 会話シート内の入力欄から直接送信する投稿関数（受理で true）。
  final Future<bool> Function(String) onSend;

  /// 画像選択とアップロード。成功時はレス本文へ挿入する URL を返す。
  final Future<List<Uri>> Function() onPickAndUploadImages;

  /// ファイル選択とアップロード。成功時はレス本文へ挿入する URL を返す。
  final Future<Uri?> Function() onPickAndUploadFile;

  /// レス長押しでアクションメニューを出す。返信はシート内の入力欄へ渡す。
  final void Function(Res res, {void Function(int)? onReply}) onShowActions;
  final bool Function(int number) isOwnPost;

  /// スレ主（`>>1` を書いた人）のレスか。
  final bool Function(Res res) isThreadOwner;

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
  // 中身（下書き）はスレと共有で、欄そのものだけがシートのもの。フォーカスは
  // 共有できない（同じ [FocusNode] を 2 つの欄に付けられない）ので、ここで持つ。
  final _focus = FocusNode();

  /// 入力欄を出しているか。レスを左へスワイプして返信したときに出す（常時表示
  /// だと「会話全体への返信」と誤解されうるため）。ただし書きかけを持ったまま
  /// 開いたときは初めから出す。隠したままだと、シートに覆われて手の届かない
  /// 場所へ下書きが消えたように見えるため。
  late bool _replying;

  /// このシートを開いた時点で下書きがあったか。
  ///
  /// 「閉じる」の意味がこれで変わる。ここで書き始めたぶんは破棄してよいが、
  /// 一覧側から持ち込んだ書きかけまで消すと、読むために閉じただけで長文が
  /// 飛ぶ。持ち込みぶんは欄を畳むだけにして、スレの下書きとして残す。
  late final bool _carriedDraft;

  /// このシートで返信の宛先（`>>N`）を入れたか。見出しの文言に使う。
  bool _repliedHere = false;

  @override
  void initState() {
    super.initState();
    _keys = {for (final entry in widget.entries) entry.res.number: GlobalKey()};
    _carriedDraft = widget.composer.text.trim().isNotEmpty;
    _replying = _carriedDraft;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// レスの返信ボタンで呼ばれる。入力欄を出して `>>N` を挿入・フォーカスする。
  void _replyLocal(int number) {
    final anchor = '>>$number\n';
    final sel = widget.composer.selection;
    final text = widget.composer.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    widget.composer.value = TextEditingValue(
      text: text.replaceRange(start, end, anchor),
      selection: TextSelection.collapsed(offset: start + anchor.length),
    );
    setState(() {
      _replying = true;
      _repliedHere = true;
    });
    _focus.requestFocus();
  }

  /// 送信。受理されたら入力欄を閉じる。
  Future<bool> _handleSend(String text) async {
    final accepted = await widget.onSend(text);
    if (accepted && mounted) setState(() => _replying = false);
    return accepted;
  }

  /// 入力欄を閉じる。ここで書き始めたぶんは下書きごと捨てる（[_carriedDraft]）。
  void _cancelReply() {
    if (!_carriedDraft) widget.composer.clear();
    _focus.unfocus();
    setState(() => _replying = false);
  }

  /// 入力欄の上の見出し。null なら文言を出さず、閉じるボタンだけの行にする。
  ///
  /// 宛先が返信先の帯（[_ReplyTargetBar]）に出ているなら、その上でもう一度
  /// 「返信」と名乗る必要はない。書きかけを持ち込んだだけの間は、宛先を決めて
  /// 出した欄ではないので「返信」とは呼ばない。
  ({IconData icon, String text})? _barLabel(String text) {
    final hasTarget = referencedResNumbers(
      text,
    ).any((n) => widget.replyTargetFor(n) != null);
    if (hasTarget) return null;
    return _carriedDraft && !_repliedHere
        ? (icon: Icons.edit_outlined, text: '書きかけのレス')
        : (icon: Icons.reply, text: '返信（>>で対象を指定）');
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
                    final post = _ConversationPost(
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
                              onLongPress: () => widget.onShowActions(
                                entry.res,
                                onReply: _replyLocal,
                              ),
                            )
                          : PostItem(
                              res: entry.res,
                              nested: entry.depth > 0,
                              idCount: widget.idCounts[entry.res.id] ?? 1,
                              idOrdinal:
                                  widget.idOrdinals[entry.res.number] ?? 1,
                              onTapId: widget.onTapId,
                              onTapWacchoi: widget.onTapWacchoi,
                              onTapRes: (n) =>
                                  widget.onTapRes(entry.res.number, n),
                              onTapResRange: (numbers) => widget.onTapResRange(
                                entry.res.number,
                                numbers,
                              ),
                              onTapUrl: widget.onTapUrl,
                              replyCount:
                                  widget.replyCountByNumber[entry.res.number] ??
                                  0,
                              onTapReplies: widget.onTapReplies,
                              onLongPress: () => widget.onShowActions(
                                entry.res,
                                onReply: _replyLocal,
                              ),
                              isOwn: widget.isOwnPost(entry.res.number),
                              isThreadOwner: widget.isThreadOwner(entry.res),
                              isReplyToOwn: widget.isReplyToOwn(entry.res),
                              showAccentBar: false,
                              blurImages: widget.guroMasked.contains(
                                entry.res.number,
                              ),
                              linkPreviews: widget.linkPreviews,
                              resLayout: widget.resLayout,
                              defaultName: widget.defaultName,
                            ),
                    );
                    return KeyedSubtree(
                      key: _keys[entry.res.number],
                      // 字下げ・返信先の見出し・強調の帯まで含めて 1 行なので、
                      // スワイプは枠の外側から掛ける。畳んだ NG は中身が無いので
                      // 包まない。
                      child: ngHidden
                          ? post
                          : SwipeToReply(
                              onReply: () => _replyLocal(entry.res.number),
                              child: post,
                            ),
                    );
                  },
                ),
            ],
          ),
        ),
        // レスを左へスワイプして返信したときだけ入力欄を出す（対象は本文の
        // >>N で明示）。キーボード分だけ持ち上げる。
        if (_replying)
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(height: 1),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.composer,
                  builder: (context, value, _) => _ReplyBar(
                    onClose: _cancelReply,
                    label: _barLabel(value.text),
                  ),
                ),
                _Composer(
                  controller: widget.composer,
                  focusNode: _focus,
                  onSend: _handleSend,
                  onPickAndUploadImages: widget.onPickAndUploadImages,
                  onPickAndUploadFile: widget.onPickAndUploadFile,
                  enabled: widget.enabled,
                  // レスを左へ引いて出した欄は、そのまま書き始めるためのもの。
                  // 持ち込んだ書きかけで出ているだけなら畳んだ札で出す。
                  openForWriting: _repliedHere,
                  replyTargetFor: widget.replyTargetFor,
                  onTapReplyTarget: (number) =>
                      widget.onTapReplyTarget(number, onReply: _replyLocal),
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

/// 会話シートの入力欄の上に出す見出し。閉じるボタンを持つ。
///
/// [label] が null なら文言を出さず、閉じるボタンだけの行にする。宛先が下の
/// [_ReplyTargetBar] に出ているときに、同じことを二度言わないため。
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.onClose, required this.label});
  final VoidCallback onClose;
  final ({IconData icon, String text})? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 0),
      child: Row(
        children: [
          if (label case final label?) ...[
            Icon(label.icon, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label.text,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
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

/// 入力中の本文が指している返信先 1 件。番号と、1 行に潰した本文の抜粋。
class _ReplyTarget {
  const _ReplyTarget(
    this.number,
    this.excerpt, {
    this.asciiArt,
    this.images = const [],
    this.blurImages = false,
  });

  final int number;

  /// 本文の抜粋。NG のレスなど、中身を出さない場合は空。画像 URL の文字列は
  /// 除いてある（[images] のサムネイルで出す）。
  final String excerpt;

  /// 返信先が AA だったときの、形を残したままの本文。AA でなければ null
  /// （[QuotedResBody.asciiArt]）。
  final String? asciiArt;

  /// 返信先に貼られていた画像。
  final List<Uri> images;

  /// 返信先に「グロ」注意が付いており、サムネイルをぼかすか。
  final bool blurImages;
}

/// 入力欄の上の帯に出す AA の高さの上限。
///
/// 引用行（[quoteAsciiArtMaxHeight]）より低く抑える。この帯は入力欄を押し上げる
/// 場所にあり、しかも 1 度に 3 件まで縦に並ぶ。書いている手元を狭めてまで大きく
/// 出すものではないので、形が分かる程度で切り上げる。
const double _replyTargetAsciiArtMaxHeight = 32;

/// 入力欄の上に「今どのレスへの返信を書いているか」を出す帯。
///
/// 本文に `>>N` を書いた時点で出る。宛先を確かめるのに書いた本文を遡って読み
/// 直さずに済むようにするもの。
///
/// **行を押すと、そのレスを長押ししたときと同じ操作メニューが出る**（レスの中身が
/// 上に丸ごと載り、その下に返信・コピー・NG などが並ぶ）。会話へ飛ばさないのは、
/// ここが**書いている最中**だから——確かめたいのは「この 1 レス」で、画面ごと
/// 移ると書きかけを抱えたまま今いる場所を失う。メニューなら閉じれば入力へ戻れる
/// し、会話を追いたければメニューの中の `>>N` から入れる。
class _ReplyTargetBar extends StatelessWidget {
  const _ReplyTargetBar({required this.targets, this.onTap});

  final List<_ReplyTarget> targets;
  final ValueChanged<int>? onTap;

  /// 1 件 1 行で出す上限。残りは件数だけ添える。`>>1-50` のような範囲指定で
  /// 帯が入力欄を押し上げないようにするため。
  static const _maxShown = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final shown = targets.take(_maxShown).toList();
    final rest = targets.length - shown.length;

    Widget number(_ReplyTarget target) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        // 各行は返信先のレスそのもの（番号＋本文の頭）なので、番号は裸で出す。
        // `>>N` と書くと、この行が N への返信に見えてしまう。
        '${target.number}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    // 1 件 1 行。番号のうしろに本文の頭を添える（番号だけでは思い出せない）。
    // 画像はサムネイルで添える（引用行と同じ [QuoteThumbs]）。URL の文字列は
    // 抜粋から落としてあるので、絵を出さないと画像だけのレスが「に返信」の
    // 一言になってしまう。AA も同じ理由で、1 行に潰さず縮めた絵で出す。
    Widget body(_ReplyTarget target) {
      if (target.asciiArt case final art?) {
        return QuoteAsciiArt(
          text: art,
          color: scheme.onSurfaceVariant,
          maxHeight: _replyTargetAsciiArtMaxHeight,
        );
      }
      return Text(
        target.excerpt.isEmpty ? 'に返信' : target.excerpt,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: dim,
      );
    }

    // 行のどこを押してもそのレスを開ける（引用行と同じ）。番号だけを的にすると、
    // 本文や絵を押しても何も起きない——見えているのは返信先そのものなので、
    // そちらを押しにいくのが自然な手つきになる。
    Widget line(_ReplyTarget target) => InkWell(
      onTap: onTap == null ? null : () => onTap!(target.number),
      borderRadius: BorderRadius.circular(4),
      child: Row(
        children: [
          number(target),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: body(target),
            ),
          ),
          if (target.images.isNotEmpty)
            QuoteThumbs(
              urls: target.images,
              blurred: target.blurImages,
              color: scheme.onSurfaceVariant,
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.reply, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final target in shown) ...[
                  if (target != shown.first) const SizedBox(height: 2),
                  line(target),
                ],
                // 多いときも頭の数件は同じ形で出し、残りは件数だけ添える。
                if (rest > 0) ...[
                  const SizedBox(height: 2),
                  Text('他$rest件に返信', style: dim),
                ],
              ],
            ),
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
    required this.onPickAndUploadImages,
    required this.onPickAndUploadFile,
    required this.enabled,
    this.openForWriting = false,
    this.replyTargetFor,
    this.onTapReplyTarget,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 本文の `>>N` から返信先を引く。そのレスが無ければ null。
  final _ReplyTarget? Function(int number)? replyTargetFor;

  /// 返信先の行を押したとき。そのレスの操作メニューを出す。
  final ValueChanged<int>? onTapReplyTarget;

  /// 送信。受理されたら true を返す（入力欄をクリアする）。
  final Future<bool> Function(String) onSend;
  final Future<List<Uri>> Function() onPickAndUploadImages;
  final Future<Uri?> Function() onPickAndUploadFile;
  final bool enabled;

  /// 出た時点で書き始めるための欄か（会話シートでレスを左へ引いて出したとき）。
  /// 立っていれば畳まずに出して、焦点まで渡す。
  final bool openForWriting;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _sending = false;
  bool _uploadingImage = false;
  bool _uploadingFile = false;

  /// 畳んだ書きかけを押して、入力欄を出し直している最中か。
  ///
  /// 欄そのものが無い状態から書き始めるので、**まず欄を出し、それからフォーカスを
  /// 渡す**（[FocusNode] は付いている欄が無いと焦点を受け取れない）。この 1 フレーム
  /// だけを跨ぐための合図で、焦点が着いたら（[_onFocusChanged]）役目を終える。
  bool _resuming = false;

  @override
  void initState() {
    super.initState();
    // 本文中の URL から添付プレビューを作るので、テキスト変更で作り直す。
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
    // 書くために出された欄（会話シートの返信）は、畳まず・焦点を持って現れる。
    // 焦点は欄が組み上がってからでないと渡せないので、1 フレーム待つ。
    if (widget.openForWriting) {
      _resuming = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.focusNode.requestFocus();
      });
    }
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
    if (!mounted) return;
    // 畳んでいる間に本文が変わるのは、外から入れられたときだけ——レスを左へ
    // 引いて `>>N` を入れた、添付の URL が入った。どれも「これから書く」場面
    // なので、札のままにせず欄を開いて焦点まで渡す（畳んだ状態では焦点を渡す
    // 相手＝入力欄そのものが無く、呼び出し側の requestFocus は空振りする）。
    //
    // **手前に会話シートが載っているときは触らない。** 下書きはスレに 1 つで、
    // シート側の入力欄も同じ本文を持つため、そちらで書いている最中に後ろから
    // 焦点を奪ってしまう。
    final folded =
        widget.enabled &&
        !widget.focusNode.hasFocus &&
        !_resuming &&
        widget.controller.text.trim().isNotEmpty;
    if (folded && (ModalRoute.of(context)?.isCurrent ?? true)) {
      _resumeWriting();
      return;
    }
    setState(() {});
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _resuming = false);
  }

  /// 畳んだ書きかけを押したとき。入力欄を出し、次のフレームで焦点を渡す。
  void _resumeWriting() {
    if (!mounted) return;
    setState(() => _resuming = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
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
      if (accepted) {
        widget.controller.clear();
        // 送り終えたら書く姿勢も解く。欄は空になっていて、続けて書く用が無い
        // ならキーボードが場所を取り続ける理由も無い（欄は 1 段へ戻る）。
        widget.focusNode.unfocus();
      }
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
      // 複数枚のときは選んだ順に URL を積む。挿入のたびにカーソルが後ろへ
      // 進むので、そのまま並べれば 1 行 1 URL になる。
      for (final url in await widget.onPickAndUploadImages()) {
        _insertUrl(url.toString());
      }
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
    final replyTargetFor = widget.replyTargetFor;
    final replyTargets = <_ReplyTarget>[
      if (replyTargetFor != null)
        for (final number in referencedResNumbers(text))
          if (replyTargetFor(number) case final target?) target,
    ];
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
    // 添付ボタンを止める条件（送信中・アップロード中は触らせない）。
    final busy =
        !widget.enabled || _sending || _uploadingImage || _uploadingFile;

    // **書き始めたら 2 段に組み替える。** 1 段目が入力欄、2 段目が添付と送信。
    //
    // 何も書いていないうちは 1 行の欄とボタンが横に並んでいてよい（画面の下に
    // 置く帯として、これがいちばん低い）。書き始めると話が変わる。ボタンに
    // 取られている 90 ほどは、そのまま本文の幅であり——AA なら**縮小せずに
    // 収まるかどうかの差**になる。書いている間は幅を本文に回す。
    //
    // キーボードを閉じたら畳んで 1 段へ戻す。手が止まっている間まで場所を取る
    // 理由は無く、書きかけは畳んだ札（[_DraftPreview]）に残るので、押せばここへ
    // 戻ってこられる。**ただし停止スレでは畳まない**——もう書けない欄に残った
    // 本文は、選んでコピーして次スレへ持っていくためのもので、畳むと選べなく
    // なる。
    //
    // 添付の**アップロード中も広げたまま**にする。上げ終われば URL が本文に
    // 入って（＝書く場面に入って）どのみち広がるので、待っている間だけ 1 段に
    // 留めると、終わった拍子に欄が伸びてボタンが動く。押した直後から広げて
    // おけば、指の下は最後まで動かない。
    final expanded =
        widget.focusNode.hasFocus ||
        _resuming ||
        _uploadingImage ||
        _uploadingFile ||
        (!widget.enabled && text.isNotEmpty);
    // 欄の代わりに、畳んだ書きかけの札を出すか。
    final collapsedDraft = !expanded && text.trim().isNotEmpty;

    // AA を書いているときだけ字を組み替えるので、置ける幅を知る。
    final field = LayoutBuilder(
      builder: (context, constraints) {
        // 欄の幅から、左右の padding（14×2）とカーソルのぶんを引いたものが、
        // 字の置ける幅。
        final fit = composeAsciiArtFit(
          context,
          base: textStyle,
          text: text,
          maxWidth: constraints.maxWidth - 28 - 2,
        );
        return TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          // 停止スレでも欄は生かしたまま読み取り専用にする。無効
          // （enabled: false）にすると書きかけを選択もコピーもできず、
          // 次スレへ持っていく手立てが無くなるため。書けないことは
          // ヒントと、無効になった送信・添付ボタンで示す。
          readOnly: !widget.enabled,
          minLines: 1,
          // AA は字が小さいぶん行数を増やす（欄の高さは変わらない）。
          maxLines: fit?.lines(5) ?? 5,
          textInputAction: TextInputAction.newline,
          // 行高を明示すると 1 行時の高さがフォントに左右されず、
          // kComposeControlHeight にぴたりと収まる。
          style: fit?.style ?? textStyle,
          decoration: composeFieldDecoration(
            scheme: scheme,
            hintText: widget.enabled ? 'レスを書く' : '書き込み停止中',
            // ヒントは欄が空のとき＝AA ではないときに出るので、普通の字のまま。
            textStyle: textStyle,
            // 21（15×1.4）+ 10.5×2 = 42 = kComposeControlHeight。
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10.5,
            ),
          ),
        );
      },
    );

    // 添付系は入力欄に添えるだけの脇役なので、色を onSurfaceVariant に
    // 落として送信ボタンとの主従をはっきりさせる。
    Widget quietButton({
      required String tooltip,
      required IconData icon,
      required bool loading,
      required VoidCallback? onPressed,
    }) => SizedBox(
      width: kComposeControlHeight,
      height: kComposeControlHeight,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        style: composeQuietButtonStyle(scheme),
        onPressed: onPressed,
        icon: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 21),
      ),
    );

    final attachImageButton = quietButton(
      tooltip: '画像を追加',
      icon: Icons.image_outlined,
      loading: _uploadingImage,
      onPressed: busy ? null : _attachImage,
    );
    final attachFileButton = quietButton(
      tooltip: 'ファイルを添付',
      icon: Icons.attach_file,
      loading: _uploadingFile,
      onPressed: busy ? null : _attachFile,
    );
    // キーボードを閉じるボタンは、開いている間だけ。1 段のときは出ない
    // （フォーカスがある＝2 段に広がっている）ので、2 段目にだけ置けばよい。
    final hideKeyboardButton = widget.enabled && widget.focusNode.hasFocus
        ? quietButton(
            tooltip: 'キーボードを閉じる',
            icon: Icons.keyboard_hide,
            loading: false,
            onPressed: widget.focusNode.unfocus,
          )
        : null;

    // 送信ボタンは 1 行時の入力欄と同じ高さに固定。丸ボタンだと入力欄の角丸
    // （14）から浮くので、同じ角丸の四角に合わせる。
    // 本文が空のうちは押しても何も起きない（[_send] が弾く）ので、
    // 塗りも控えめにして「まだ送れない」ことを見た目でも伝える。
    final sendButton = SizedBox(
      width: kComposeControlHeight,
      height: kComposeControlHeight,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: '送信',
        onPressed: !widget.enabled || _sending ? null : _send,
        style: IconButton.styleFrom(
          backgroundColor: canSend ? scheme.primary : Colors.transparent,
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
    );

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
        // **この帯の中を押しても入力欄の焦点は外さない。**
        //
        // デスクトップでは入力欄の外を押した時点で焦点が外れる（[TextField] の
        // 既定の onTapOutside）。ここが効くと、指を置いた瞬間に欄が畳まれて
        // 2 段目のボタンが動き、離した指はもうボタンの上にいない——押したはずの
        // 送信も添付も起きずに、欄が 1 段へ戻るだけになる。添付・送信・返信先は
        // 入力欄の一部なので、押しても書いている状態は続く。
        child: TextFieldTapRegion(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (replyTargets.isNotEmpty)
                _ReplyTargetBar(
                  targets: replyTargets,
                  onTap: widget.onTapReplyTarget,
                ),
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
              // 入力欄は**どちらの組み方でも同じ位置**（この Row の先頭）に置く。
              // 1 段と 2 段で入れ物を変えると、切り替わった拍子に欄が作り直されて
              // フォーカスも入力中の文字も落ちる（＝タップした瞬間にキーボードが
              // 閉じる）。動かすのはボタンの側だけにする。
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: collapsedDraft
                        ? _DraftPreview(
                            text: text,
                            style: textStyle,
                            onTap: _resumeWriting,
                          )
                        : field,
                  ),
                  if (!expanded) ...[
                    const SizedBox(width: 6),
                    attachImageButton,
                    attachFileButton,
                    const SizedBox(width: 4),
                    sendButton,
                  ],
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    attachImageButton,
                    attachFileButton,
                    const Spacer(),
                    if (hideKeyboardButton != null) hideKeyboardButton,
                    const SizedBox(width: 4),
                    sendButton,
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// キーボードを閉じたあとの書きかけを、入力欄と同じ形の札 1 行に畳んだもの。
/// 押すと入力欄へ戻る（[_ComposerState._resumeWriting]）。
///
/// 手が止まっている間は、入力欄が 2 段のまま画面の下を占め続ける理由が無い。
/// かといって書きかけを隠すと、残っていること自体を忘れて別のスレへ行ってしまう
/// ——だから**畳んでも中身は見せる**。塗りも角丸も入力欄と同じにして、「ここが
/// さっきの欄だ」と分かる形に留める。
///
/// 文章は 1 行に潰して末尾を `…` で切る。**AA だけは潰さない**（[QuoteAsciiArt]）：
/// 記号の列にしてしまうと元が何の絵だったか読み取れず、引用行で同じ理由から
/// 形のまま縮めているのと揃わない。
class _DraftPreview extends StatelessWidget {
  const _DraftPreview({
    required this.text,
    required this.style,
    required this.onTap,
  });

  final String text;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: composeFieldFill(scheme),
      borderRadius: BorderRadius.circular(kComposeRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: kComposeControlHeight,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: looksLikeAsciiArt(text)
              ? QuoteAsciiArt(
                  text: trimBlankLines(text),
                  color: style?.color ?? scheme.onSurface,
                  maxHeight: kComposeControlHeight - 12,
                )
              : Text(
                  text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
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
