import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../net/auth_launcher.dart';
import '../net/image_upload_settings.dart';
import 'back_swipe.dart';

class ImageUploadSettingsScreen extends StatefulWidget {
  const ImageUploadSettingsScreen({super.key, required this.store});

  final ImageUploadSettings store;

  @override
  State<ImageUploadSettingsScreen> createState() =>
      _ImageUploadSettingsScreenState();
}

class _ImageUploadSettingsScreenState extends State<ImageUploadSettingsScreen> {
  static final _imgurApiDocs = Uri.parse('https://apidocs.imgur.com/');
  static final _imgbbHome = Uri.parse('https://imgbb.com/');
  static final _imgbbApiDocs = Uri.parse('https://api.imgbb.com/');

  late ImageUploadProvider _provider;
  late final TextEditingController _imgur;
  late final TextEditingController _imgbb;

  @override
  void initState() {
    super.initState();
    final snapshot = widget.store.snapshot;
    _provider = snapshot.provider;
    _imgur = TextEditingController(text: snapshot.imgurClientId);
    _imgbb = TextEditingController(text: snapshot.imgbbApiKey);
  }

  @override
  void dispose() {
    _imgur.dispose();
    _imgbb.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.save(
      ImageUploadSettingsSnapshot(
        provider: _provider,
        imgurClientId: _imgur.text.trim(),
        imgbbApiKey: _imgbb.text.trim(),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('画像アップロード設定を保存しました')));
  }

  Future<void> _openLink(Uri url) async {
    final ok = await const SystemBrowserLauncher().open(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('画像アップロード設定'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      // 設定画面と同じく、右へのスワイプで前の画面へ戻る。キーの入力欄の上では
      // 文字を触る側（カーソル移動・選択）が競り合いに勝つので、入力中に横へ
      // なぞって画面が退くことはない。
      body: BackSwipe(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              '投稿欄の画像ボタンで使うアップロード先を選びます。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('どれを選べばいい？'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                _HelpText(
                  spans: [
                    const TextSpan(text: '迷ったら「既定の Imgur」を選んでください。\n\n'),
                    const TextSpan(
                      text:
                          'Imgur Client ID を既に持っている場合は「自分の Imgur Client ID」を選ぶと、'
                          'アプリ同梱 ID のレート制限を避けられます。\n\n',
                    ),
                    const TextSpan(
                      text:
                          'Imgur ID を持っていない場合や新規発行できない場合は、ImgBB のアカウントを作って '
                          'API Key を使うのが分かりやすい代替です。',
                    ),
                  ],
                  onTap: _openLink,
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Imgur Client ID / ImgBB API Key とは？'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                _HelpText(
                  spans: [
                    const TextSpan(
                      text:
                          'Imgur Client ID は Imgur API で匿名アップロードするためのアプリ識別子です。'
                          '取得済みの ID があれば入力してください。\n'
                          '詳しくは ',
                    ),
                    LinkTextSpan(text: 'Imgur API ドキュメント', url: _imgurApiDocs),
                    const TextSpan(text: ' を確認してください。\n\n'),
                    const TextSpan(
                      text:
                          'ImgBB API Key は ImgBB に画像をアップロードするためのキーです。'
                          'まず ',
                    ),
                    LinkTextSpan(text: 'ImgBB', url: _imgbbHome),
                    const TextSpan(text: ' でアカウントを作成し、'),
                    LinkTextSpan(text: 'ImgBB API ページ', url: _imgbbApiDocs),
                    const TextSpan(text: ' から取得します。'),
                  ],
                  onTap: _openLink,
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final provider in ImageUploadProvider.values)
              ListTile(
                leading: Icon(
                  _provider == provider
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(provider.label),
                subtitle: Text(_description(provider)),
                selected: _provider == provider,
                onTap: () => setState(() => _provider = provider),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _imgur,
              enabled: _provider == ImageUploadProvider.imgur,
              decoration: const InputDecoration(
                labelText: 'Imgur Client ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _imgbb,
              enabled: _provider == ImageUploadProvider.imgbb,
              decoration: const InputDecoration(
                labelText: 'ImgBB API Key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _description(ImageUploadProvider provider) => switch (provider) {
    ImageUploadProvider.defaultImgur => 'アプリに同梱された Imgur Client ID を使います。',
    ImageUploadProvider.imgur => '利用者が用意した Imgur Client ID を使います。',
    ImageUploadProvider.imgbb => '利用者が用意した ImgBB API Key を使います。',
  };
}

class LinkTextSpan extends TextSpan {
  const LinkTextSpan({required String text, required this.url})
    : super(text: text);

  final Uri url;
}

class _HelpText extends StatefulWidget {
  const _HelpText({required this.spans, required this.onTap});

  final List<InlineSpan> spans;
  final ValueChanged<Uri> onTap;

  @override
  State<_HelpText> createState() => _HelpTextState();
}

class _HelpTextState extends State<_HelpText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall,
          children: [
            for (final span in widget.spans)
              if (span is LinkTextSpan)
                TextSpan(
                  text: span.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                  recognizer: _linkRecognizer(span.url),
                )
              else
                span,
          ],
        ),
      ),
    );
  }

  TapGestureRecognizer _linkRecognizer(Uri url) {
    final recognizer = TapGestureRecognizer()..onTap = () => widget.onTap(url);
    _recognizers.add(recognizer);
    return recognizer;
  }
}
