import 'package:flutter/material.dart';

import '../net/file_upload_settings.dart';
import 'back_swipe.dart';

class FileUploadSettingsScreen extends StatefulWidget {
  const FileUploadSettingsScreen({super.key, required this.store});

  final FileUploadSettings store;

  @override
  State<FileUploadSettingsScreen> createState() =>
      _FileUploadSettingsScreenState();
}

class _FileUploadSettingsScreenState extends State<FileUploadSettingsScreen> {
  late FileUploadProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = widget.store.snapshot.provider;
  }

  Future<void> _save() async {
    await widget.store.save(FileUploadSettingsSnapshot(provider: _provider));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('ファイルアップロード設定を保存しました')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ファイルアップロード設定'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      // 設定画面と同じく、右へのスワイプで前の画面へ戻る。
      body: BackSwipe(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              '投稿欄の添付ボタンで、任意ファイルをアップロードして URL を貼り付けられます。'
              '送信先を選んでください。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final provider in FileUploadProvider.values)
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
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'uguu.se は一時ホスティングのため、アップロードしたファイルは数時間〜数日で'
                        '消えてリンク切れになります。あとから残したいものは catbox.moe を選んでください。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _description(FileUploadProvider provider) => switch (provider) {
    FileUploadProvider.catbox =>
      '匿名アップロードは最終アクセスから2年で削除。上限 200MB。一部の実行ファイル形式は不可。',
    FileUploadProvider.uguu => '一時保存（数時間〜数日で消える）。上限 128MB。',
  };
}
