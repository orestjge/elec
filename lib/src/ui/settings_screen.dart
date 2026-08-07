import 'package:flutter/material.dart';

import '../net/file_upload_settings.dart';
import '../net/image_cache_store.dart';
import '../net/image_upload_settings.dart';
import '../net/ng_store.dart';
import '../net/thread_view_settings.dart';
import 'file_upload_settings_screen.dart';
import 'format.dart';
import 'image_upload_settings_screen.dart';
import 'ng_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    ImageCacheStore? imageCache,
    ThreadViewSettings? threadView,
  }) : _imageCache = imageCache,
       _threadView = threadView;

  /// テストから差し替えるための置き場。未指定なら共有のものを使う。
  final ImageCacheStore? _imageCache;
  final ThreadViewSettings? _threadView;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ImageCacheStore get _imageCache =>
      widget._imageCache ?? ImageCacheStore.shared;
  ThreadViewSettings get _threadView =>
      widget._threadView ?? ThreadViewSettings.shared;

  int? _cacheBytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _readCacheSize();
  }

  Future<void> _readCacheSize() async {
    final bytes = await _imageCache.usedBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    await _imageCache.clear();
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _cacheBytes = 0;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('画像キャッシュを削除しました')));
  }

  /// レスの並べ方を選ぶ。選んだらその場で全スレ画面に効く。
  Future<void> _pickThreadLayout() async {
    final picked = await showModalBottomSheet<ThreadLayout>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        final current = _threadView.layout;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  'レスの並べ方',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final layout in ThreadLayout.values)
                ListTile(
                  leading: Icon(
                    _layoutIcon(layout),
                    color: layout == current ? scheme.primary : null,
                  ),
                  title: Text(_layoutLabel(layout)),
                  subtitle: Text(_layoutDescription(layout)),
                  trailing: layout == current
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, layout),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    await _threadView.setLayout(picked);
    if (mounted) setState(() {});
  }

  static IconData _layoutIcon(ThreadLayout layout) => switch (layout) {
    ThreadLayout.number => Icons.format_list_numbered,
    ThreadLayout.tree => Icons.account_tree_outlined,
  };

  static String _layoutLabel(ThreadLayout layout) => switch (layout) {
    ThreadLayout.number => '番号順',
    ThreadLayout.tree => 'ツリー',
  };

  static String _layoutDescription(ThreadLayout layout) => switch (layout) {
    ThreadLayout.number => 'dat の順にそのまま並べる',
    ThreadLayout.tree => '開いた時点までを返信でぶら下げ、そのあとの新着は下へ足す',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('settings-thread-layout'),
            leading: Icon(_layoutIcon(_threadView.layout)),
            title: const Text('レスの並べ方'),
            subtitle: Text(
              '${_layoutLabel(_threadView.layout)} ・ '
              '${_layoutDescription(_threadView.layout)}',
            ),
            onTap: _pickThreadLayout,
          ),
          const Divider(height: 1),
          SwitchListTile(
            key: const ValueKey('settings-link-previews'),
            secondary: const Icon(Icons.link),
            title: const Text('リンクをカードで見せる'),
            // 端末から直接リンク先を読みに行くことを隠さない。相手のサーバに
            // アクセスが残る（＝IP が渡る）ので、承知のうえで選べるようにする。
            // 貼られたスレのカードは切っても出る（読みに行くのは元から見ている
            // 掲示板サーバなので、この設定の理由に当たらない）ことも書いておく。
            subtitle: const Text(
              '行に URL だけがあるとき、その場でリンク先を読んで見出しと絵を出す。'
              '知っている板のスレは、切っていてもスレタイを出す',
            ),
            value: _threadView.linkPreviews,
            onChanged: (enabled) async {
              await _threadView.setLinkPreviews(enabled);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('画像アップロード設定'),
            subtitle: const Text('Imgur / ImgBB のアップロード先と API キー'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImageUploadSettingsScreen(
                    store: ImageUploadSettings.shared,
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: const Text('ファイルアップロード設定'),
            subtitle: const Text('catbox.moe / uguu.se の任意ファイル送信先'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FileUploadSettingsScreen(
                    store: FileUploadSettings.shared,
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('NG設定'),
            subtitle: const Text('NGワード・ID・スレ主の管理'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NgScreen(store: NgStore.shared),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('settings-clear-image-cache'),
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('画像キャッシュを削除'),
            // 見た画像は端末に残る。中身によっては消したいことがあるので、
            // 手で消せる場所を用意しておく。
            subtitle: Text(
              _cacheBytes == null
                  ? '一度見た画像を端末に残して、開き直しを速くしています'
                  : 'いま ${formatBytes(_cacheBytes!)} 使っています',
            ),
            trailing: _clearing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            enabled: !_clearing && (_cacheBytes ?? 0) > 0,
            onTap: _clearCache,
          ),
        ],
      ),
    );
  }
}
