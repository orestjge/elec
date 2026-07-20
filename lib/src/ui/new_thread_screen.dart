import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import '../net/auth_launcher.dart';
import '../net/auth_store.dart';
import '../net/endpoints.dart';
import '../net/http_fetcher.dart';
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
  });

  final HttpFetcher? fetcher;
  final EdgeEndpoints endpoints;
  final AuthStore? authStore;
  final AuthLauncher authLauncher;

  @override
  State<NewThreadScreen> createState() => _NewThreadScreenState();
}

class _NewThreadScreenState extends State<NewThreadScreen> {
  // SETTING.TXT の実測値。超過はサーバが弾くので手前で止める。
  static const _titleMax = 192;
  static const _bodyMax = 9192;

  late final HttpFetcher _fetcher;
  late final bool _ownsFetcher;
  late final AuthStore _authStore;

  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _ownsFetcher = widget.fetcher == null;
    _fetcher = widget.fetcher ?? HttpClientFetcher();
    _authStore = widget.authStore ?? AuthStore.shared;
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    final fetcher = _fetcher;
    if (_ownsFetcher && fetcher is HttpClientFetcher) fetcher.close();
    super.dispose();
  }

  bool get _canSubmit =>
      !_sending &&
      _title.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty;

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
      message: _body.text,
      tokens: _authStore.tokens,
    );
    await _authStore.setTokens(result.tokens);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('スレを立てる'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('立てる'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            maxLength: _titleMax,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'スレッドタイトル',
              hintText: '例）〇〇について語るスレ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            maxLength: _bodyMax,
            minLines: 6,
            maxLines: 16,
            decoration: const InputDecoration(
              labelText: '本文（1レス目）',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '※ スレ立てには一定の書き込み実績と間隔制限があります（初回書き込みでは立てられません）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
