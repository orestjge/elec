import 'package:flutter/material.dart';

import '../net/file_upload_settings.dart';
import '../net/image_cache_store.dart';
import '../net/image_upload_settings.dart';
import '../net/ng_store.dart';
import 'file_upload_settings_screen.dart';
import 'format.dart';
import 'image_upload_settings_screen.dart';
import 'ng_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, ImageCacheStore? imageCache})
    : _imageCache = imageCache;

  /// テストから差し替えるための置き場。未指定なら共有のものを使う。
  final ImageCacheStore? _imageCache;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ImageCacheStore get _imageCache =>
      widget._imageCache ?? ImageCacheStore.shared;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
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
