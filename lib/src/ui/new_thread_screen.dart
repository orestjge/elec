import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import '../net/auth_launcher.dart';
import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
import 'attachment_uploader.dart';
import 'embed_urls.dart';
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
    this.pickAndUploadImage,
    this.pickAndUploadFile,
    this.maxTitle,
    this.maxBody,
  });

  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;

  /// スレタイ・本文の最大文字数（板の SETTING.TXT 実測値）。null なら既定値。
  final int? maxTitle;
  final int? maxBody;
  final AuthStore? authStore;
  final AuthLauncher authLauncher;

  /// 画像・ファイルのアップロード実装。未指定なら設定に従って組み立てる。
  final AttachmentUploader? attachmentUploader;

  /// テスト用に画像・ファイル選択を差し替えるフック。指定時は実際の選択を行わない。
  final Future<Uri?> Function()? pickAndUploadImage;
  final Future<Uri?> Function()? pickAndUploadFile;

  @override
  State<NewThreadScreen> createState() => _NewThreadScreenState();
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

  final _title = TextEditingController();
  final _body = TextEditingController();
  final _bodyFocus = FocusNode();
  bool _sending = false;
  bool _uploadingImage = false;
  bool _uploadingFile = false;

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _authStore = widget.authStore ?? AuthStore.shared;
    _uploader = widget.attachmentUploader ?? AttachmentUploader();
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
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
      final url =
          await (widget.pickAndUploadImage?.call() ??
              _uploader.pickAndUploadImage(_showSnack));
      if (url != null) _insertUrl(url.toString());
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
        Navigator.of(context).pop(title); // 一覧を更新させ、自分のスレとして記録する
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('スレを立てる')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _title,
            maxLength: _titleMax,
            textInputAction: TextInputAction.next,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            decoration: _filledInputDecoration(scheme, hintText: 'スレッドタイトル'),
          ),
          _CharCount(length: _title.text.characters.length, max: _titleMax),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            focusNode: _bodyFocus,
            maxLength: _bodyMax,
            minLines: 10,
            maxLines: 24,
            textInputAction: TextInputAction.newline,
            decoration: _filledInputDecoration(scheme, hintText: '本文を書く'),
          ),
          _CharCount(length: _body.text.characters.length, max: _bodyMax),
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
      bottomNavigationBar: _NewThreadActions(
        sending: _sending,
        uploadingImage: _uploadingImage,
        uploadingFile: _uploadingFile,
        onAttachImage: _busy ? null : _attachImage,
        onAttachFile: _busy ? null : _attachFile,
        onSubmit: _canSubmit ? _submit : null,
      ),
    );
  }
}

/// レス入力欄・スレ内検索欄と同じ filled + 角丸スタイル。アプリ内で入力欄の
/// 見た目を1系統に揃えるための共通デコレーション。
InputDecoration _filledInputDecoration(
  ColorScheme scheme, {
  required String hintText,
}) {
  return InputDecoration(
    hintText: hintText,
    counterText: '',
    filled: true,
    fillColor: scheme.surfaceContainerHighest,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  );
}

/// 入力欄の下に出す控えめな文字数カウンタ。空欄では場所を取らず、上限に近づく
/// と色で知らせる。上限自体は [TextField.maxLength] が弾く。
class _CharCount extends StatelessWidget {
  const _CharCount({required this.length, required this.max});

  final int length;
  final int max;

  @override
  Widget build(BuildContext context) {
    if (length == 0) return const SizedBox(height: 4);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final near = length >= max * 0.9;
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          '$length / $max',
          style: theme.textTheme.bodySmall?.copyWith(
            color: near ? scheme.error : scheme.onSurfaceVariant,
          ),
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
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '画像を追加',
                onPressed: onAttachImage,
                icon: uploadingImage
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined, size: 22),
              ),
            ),
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: 'ファイルを添付',
                onPressed: onAttachFile,
                icon: uploadingFile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.attach_file, size: 22),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              key: const ValueKey('new-thread-submit'),
              onPressed: onSubmit,
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, 40),
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
