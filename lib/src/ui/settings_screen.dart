import 'package:flutter/material.dart';

import '../net/file_upload_settings.dart';
import '../net/image_upload_settings.dart';
import '../net/ng_store.dart';
import 'file_upload_settings_screen.dart';
import 'image_upload_settings_screen.dart';
import 'ng_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
        ],
      ),
    );
  }
}
