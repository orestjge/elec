import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/auth_launcher.dart';
import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
import '../net/thread_command.dart';
import 'attachment_uploader.dart';
import 'compose_style.dart';
import 'embed_urls.dart';
import 'image_set_screen.dart';
import 'image_urls.dart';
import 'post_images.dart';
import 'write_auth.dart';

/// スレ立て画面。タイトルと本文を入力して新規スレッドを作成する。
/// 認証フローはレス書き込みと共用（[submitWithAuth]）。
class NewThreadScreen extends StatefulWidget {
  const NewThreadScreen({
    super.key,
    this.fetcher,
    this.endpoints = const EdgeEndpoints(),
    this.authStore,
    this.authLauncher = const SystemBrowserLauncher(),
    this.attachmentUploader,
    this.pickAndUploadImages,
    this.pickAndUploadFile,
    this.maxTitle,
    this.maxBody,
    this.initialTitle = '',
    this.initialBody = '',
    this.onDraftChanged,
    this.onDraftCleared,
  });

  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;

  /// スレタイ・本文の最大文字数（板の SETTING.TXT 実測値）。null なら既定値。
  final int? maxTitle;
  final int? maxBody;
  final String initialTitle;
  final String initialBody;
  final ValueChanged<NewThreadDraft>? onDraftChanged;
  final VoidCallback? onDraftCleared;
  final AuthStore? authStore;
  final AuthLauncher authLauncher;

  /// 画像・ファイルのアップロード実装。未指定なら設定に従って組み立てる。
  final AttachmentUploader? attachmentUploader;

  /// テスト用に画像・ファイル選択を差し替えるフック。指定時は実際の選択を行わない。
  final Future<List<Uri>> Function()? pickAndUploadImages;
  final Future<Uri?> Function()? pickAndUploadFile;

  @override
  State<NewThreadScreen> createState() => _NewThreadScreenState();
}

class NewThreadDraft {
  const NewThreadDraft({this.title = '', this.body = ''});

  final String title;
  final String body;

  bool get isEmpty => title.isEmpty && body.isEmpty;
}

class _NewThreadScreenState extends State<NewThreadScreen> {
  // SETTING.TXT の実測既定値。超過はサーバが弾くので手前で止める。板から実測値が
  // 渡ればそれを使う（5ch は本文 4096・スレタイ 96〜128 とエッヂより小さい）。
  static const _defaultTitleMax = 192;
  static const _defaultBodyMax = 9192;
  int get _titleMax => widget.maxTitle ?? _defaultTitleMax;
  int get _bodyMax => widget.maxBody ?? _defaultBodyMax;

  late final HttpFetcher _fetcher;
  late final bool _ownsFetcher;
  late final AuthStore _authStore;
  late final AttachmentUploader _uploader;

  late final TextEditingController _title;
  late final TextEditingController _body;
  final _bodyFocus = FocusNode();
  bool _sending = false;
  bool _uploadingImage = false;
  bool _uploadingFile = false;
  bool _trackingSwipe = false;
  double _horizontalDragDistance = 0;
  double _verticalDragDistance = 0;
  Timer? _swipeStartTimer;
  static const double _swipeDistanceThreshold = 25;
  static const Duration _swipeStartTimeout = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _body = TextEditingController(text: widget.initialBody);
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _authStore = widget.authStore ?? AuthStore.shared;
    _uploader = widget.attachmentUploader ?? AttachmentUploader();
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
  }

  void _onChanged() {
    widget.onDraftChanged?.call(
      NewThreadDraft(title: _title.text, body: _body.text),
    );
    setState(() {});
  }

  @override
  void dispose() {
    _swipeStartTimer?.cancel();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    final fetcher = _fetcher;
    if (_ownsFetcher && fetcher is HttpClientFetcher) fetcher.close();
    super.dispose();
  }

  bool get _busy => _sending || _uploadingImage || _uploadingFile;

  bool get _canSubmit =>
      !_busy && _title.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _attachImage() async {
    if (_busy) return;
    setState(() => _uploadingImage = true);
    try {
      final urls =
          await (widget.pickAndUploadImages?.call() ??
              _uploader.pickAndUploadImages(
                _showSnack,
                prepare: (picked) async =>
                    mounted ? prepareImagesForUpload(context, picked) : picked,
              ));
      // 複数枚のときは選んだ順に URL を積む。
      for (final url in urls) {
        _insertUrl(url.toString());
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _attachFile() async {
    if (_busy) return;
    setState(() => _uploadingFile = true);
    try {
      final url =
          await (widget.pickAndUploadFile?.call() ??
              _uploader.pickAndUploadFile(_showSnack));
      if (url != null) _insertUrl(url.toString());
    } finally {
      if (mounted) setState(() => _uploadingFile = false);
    }
  }

  /// カーソル位置へ URL を挿入する。URL の後ろは改行して次の入力を新しい行から
  /// 始められるようにする（[thread_screen] のレス入力欄と同じ挙動）。
  void _insertUrl(String url) {
    final value = _body.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = start > 0 ? text[start - 1] : '';
    final after = end < text.length ? text[end] : '';
    final prefix = before.isEmpty || before == '\n' ? '' : '\n';
    final suffix = after == '\n' ? '' : '\n';
    final insertion = '$prefix$url$suffix';
    _body.value = TextEditingValue(
      text: text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
    _bodyFocus.requestFocus();
  }

  /// この板でスレ立て時にコマンドを書けるなら、その方言。書けない板では
  /// 名前欄の選択そのものを出さない。
  ThreadCommandDialect? get _commands => dialectFor(widget.endpoints.kind);

  /// 名前欄に出すものを選び直し、本文のコマンド行を差し替える。
  Future<void> _pickCommand(ThreadCommandDialect dialect) async {
    final current = dialect.selected(_body.text);
    final picked = await showModalBottomSheet<ThreadCommandOption>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('名前欄に出すもの', style: theme.textTheme.titleMedium),
                      // 後から変えられないので、選ぶ前に言っておく。
                      Text(
                        'スレ立てのときだけ決められます。以降のレス全部に効きます',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                for (final option in dialect.options)
                  ListTile(
                    title: Text(option.label),
                    subtitle: Text(option.description),
                    trailing: option.id == current.id
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    selected: option.id == current.id,
                    onTap: () => Navigator.pop(context, option),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || picked.id == current.id) return;
    final text = dialect.apply(_body.text, picked);
    // コマンド行は本文の先頭で増減するので、書きかけの位置は差分だけずらす。
    // 末尾へ飛ばすと、書いている途中に選び直したときカーソルを見失う。
    final selection = _body.selection;
    final shift = text.length - _body.text.length;
    final offset = selection.isValid
        ? (selection.baseOffset + shift).clamp(0, text.length)
        : text.length;
    _body.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  /// 添付プレビューの × から呼ばれ、本文中の該当 URL を取り除く。
  void _removeUrl(Uri url) {
    final text = _body.text;
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
    _body.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start.clamp(0, newText.length),
      ),
    );
  }

  Future<BbsCgiResult> _postOnce() async {
    final fetcher = _fetcher;
    if (fetcher is! HttpPoster) {
      return const PostRejected(
        errorCode: 'Unsupported',
        message: 'この環境では書き込みに未対応です',
      );
    }
    final result = await BbsWriter(fetcher as HttpPoster).createThread(
      bbsCgi: widget.endpoints.bbsCgi,
      board: widget.endpoints.boardKey,
      title: _title.text.trim(),
      // URL 挿入で末尾に付く改行は残さない。AA の末尾空白は保持したいので、
      // 落とすのは末尾の改行だけにする。
      message: _body.text.replaceAll(RegExp(r'\n+$'), ''),
      tokens: _authStore.tokensFor(widget.endpoints.host),
      referer: widget.endpoints.writeReferer(),
      time: widget.endpoints.isFivech
          ? '${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
          : null,
      userAgent: widget.endpoints.writeUserAgent,
    );
    await _authStore.setTokensFor(widget.endpoints.host, result.tokens);
    return result.outcome;
  }

  Future<void> _submit() async {
    setState(() => _sending = true);
    try {
      final accepted = await submitWithAuth(
        context: context,
        launcher: widget.authLauncher,
        postOnce: _postOnce,
      );
      if (!mounted) return;
      if (accepted != null) {
        final title = _title.text.trim();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('スレッドを立てました')));
        widget.onDraftCleared?.call();
        Navigator.of(context).pop(title); // 一覧を更新させ、自分のスレとして記録する
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
    if (_horizontalDragDistance < _swipeDistanceThreshold) return;
    if (_horizontalDragDistance < _verticalDragDistance * 1.2) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _swipeStartTimer?.cancel();
    _trackingSwipe = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // スレタイは本文より一段強く。行高を明示して、密度に関係なく高さを決める。
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.4,
    );
    final bodyStyle = composeBodyTextStyle(theme);
    return Scaffold(
      appBar: AppBar(title: const Text('スレを立てる')),
      // 操作バーは bottomNavigationBar ではなく body の中に置く。Scaffold は
      // bottomNavigationBar をキーボードの上へ押し上げない（縮むのは body だけ）
      // ため、あちらに置くと立てる・添付ボタンがキーボードに隠れてしまう。
      // body の末尾に置けばキーボード分だけ入力欄側が縮み、バーは常にその上に残る。
      body: Column(
        children: [
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  TextField(
                    controller: _title,
                    maxLength: _titleMax,
                    minLines: 1,
                    maxLines: null,
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                    ],
                    textInputAction: TextInputAction.next,
                    style: titleStyle,
                    decoration: composeFieldDecoration(
                      scheme: scheme,
                      hintText: 'スレッドタイトル',
                      textStyle: titleStyle,
                      // 1 行のときはレス入力欄と同じ高さ（42）に収める。
                      // 行高 22（16×1.4）+ 10×2 = 42。折り返したらこの余白のまま伸びる。
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                  _CharCount(
                    length: _title.text.characters.length,
                    max: _titleMax,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _body,
                    focusNode: _bodyFocus,
                    maxLength: _bodyMax,
                    minLines: 10,
                    maxLines: 24,
                    textInputAction: TextInputAction.newline,
                    // 本文はレス入力欄と同じ組み方（15px・行高 1.4）。
                    style: bodyStyle,
                    decoration: composeFieldDecoration(
                      scheme: scheme,
                      hintText: '本文を書く',
                      textStyle: bodyStyle,
                    ),
                  ),
                  _CharCount(
                    length: _body.text.characters.length,
                    max: _bodyMax,
                  ),
                  // 名前欄の指定は本文に書くコマンドそのものなので、入力欄の
                  // すぐ下に置いて「今どうなっているか」を札の文字で見せる。
                  if (_commands case final dialect?) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ActionChip(
                        key: const ValueKey('new-thread-command'),
                        avatar: const Icon(Icons.badge_outlined, size: 18),
                        label: Text(
                          '名前欄: ${dialect.selected(_body.text).label}',
                        ),
                        onPressed: _busy ? null : () => _pickCommand(dialect),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _AttachmentPreview(body: _body, onRemove: _removeUrl),
                  const SizedBox(height: 12),
                  Text(
                    'スレ立てには一定の書き込み実績と間隔制限があります',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _NewThreadActions(
            sending: _sending,
            uploadingImage: _uploadingImage,
            uploadingFile: _uploadingFile,
            onAttachImage: _busy ? null : _attachImage,
            onAttachFile: _busy ? null : _attachFile,
            onSubmit: _canSubmit ? _submit : null,
          ),
        ],
      ),
    );
  }
}

/// 入力欄の下に出す控えめな文字数カウンタ。上限に近づくと色で知らせる。
/// 上限自体は [TextField.maxLength] が弾く。
///
/// 0 文字でも出しっぱなしにする。書き始めた瞬間に現れる作りだと、その一文字で
/// 下の入力欄が押し下げられて画面が跳ねるため。空のうちは色を落として、
/// 場所は取りつつ視線は引かないようにする。
class _CharCount extends StatelessWidget {
  const _CharCount({required this.length, required this.max});

  final int length;
  final int max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final near = length >= max * 0.9;
    final color = near
        ? scheme.error
        : scheme.onSurfaceVariant.withValues(alpha: length == 0 ? 0.5 : 1);
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          '$length / $max',
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _NewThreadActions extends StatelessWidget {
  const _NewThreadActions({
    required this.sending,
    required this.uploadingImage,
    required this.uploadingFile,
    required this.onAttachImage,
    required this.onAttachFile,
    required this.onSubmit,
  });

  final bool sending;
  final bool uploadingImage;
  final bool uploadingFile;
  final VoidCallback? onAttachImage;
  final VoidCallback? onAttachFile;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          // 上辺はレス入力欄のバーと同じ、面を分けるだけの控えめな線に。
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 添付系はレス入力欄と同じ脇役の見た目（onSurfaceVariant・角丸14）。
            SizedBox(
              width: kComposeControlHeight,
              height: kComposeControlHeight,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: '画像を追加',
                style: composeQuietButtonStyle(scheme),
                onPressed: onAttachImage,
                icon: uploadingImage
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
                onPressed: onAttachFile,
                icon: uploadingFile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.attach_file, size: 21),
              ),
            ),
            const Spacer(),
            // 立てるボタンは M3 既定のピル型だと入力欄の角丸から浮くので、
            // 送信ボタンと同じ角丸14・高さ 42 に合わせる。
            FilledButton.icon(
              key: const ValueKey('new-thread-submit'),
              onPressed: onSubmit,
              style: FilledButton.styleFrom(
                minimumSize: const Size(96, kComposeControlHeight),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: composeShape,
                // 入力欄と同じ理由で密度を固定する。デスクトップの compact だと
                // ここだけ 34 に縮み、隣の添付ボタン（42）とずれる。
                visualDensity: VisualDensity.standard,
              ),
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
              label: const Text('立てる'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 本文に含まれる画像・動画などの URL を、レス表示と同じ仕組みでプレビュー表示
/// する。× で本文中の URL を取り消せる。親が本文変更のたび再ビルドする前提。
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.body, required this.onRemove});

  final TextEditingController body;
  final ValueChanged<Uri> onRemove;

  @override
  Widget build(BuildContext context) {
    final text = body.text;
    final imageUrls = imageUrlsIn(text);
    final videoUrls = videoUrlsIn(text);
    final audioUrls = audioUrlsIn(text);
    final embedVideos = embedVideosIn(text);
    if (imageUrls.isEmpty &&
        videoUrls.isEmpty &&
        audioUrls.isEmpty &&
        embedVideos.isEmpty) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: SingleChildScrollView(
        child: PostImages(
          urls: imageUrls,
          videoUrls: videoUrls,
          audioUrls: audioUrls,
          embedVideos: embedVideos,
          onRemove: onRemove,
          thumbSize: 96,
        ),
      ),
    );
  }
}
