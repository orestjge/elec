import 'package:elec/src/net/file_upload_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('既定値は catbox を使う', () {
    const snapshot = FileUploadSettingsSnapshot();
    expect(snapshot.provider, FileUploadProvider.catbox);
  });

  test('JSON から provider を復元する', () {
    final snapshot = FileUploadSettingsSnapshot.fromJson({'provider': 'uguu'});
    expect(snapshot.provider, FileUploadProvider.uguu);
  });

  test('未知の provider は catbox にフォールバックする', () {
    final snapshot = FileUploadSettingsSnapshot.fromJson({'provider': 'nope'});
    expect(snapshot.provider, FileUploadProvider.catbox);
  });

  test('保存した設定を再読込できる', () async {
    final storage = MemoryFileUploadSettingsStorage();
    final store = FileUploadSettings(storage);
    await store.save(
      const FileUploadSettingsSnapshot(provider: FileUploadProvider.uguu),
    );

    final reloaded = FileUploadSettings(storage);
    await reloaded.load();

    expect(reloaded.snapshot.provider, FileUploadProvider.uguu);
  });
}
