import 'package:elec/src/net/image_upload_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('既定値は同梱 Imgur を使う', () {
    const snapshot = ImageUploadSettingsSnapshot();
    expect(snapshot.provider, ImageUploadProvider.defaultImgur);
    expect(snapshot.imgurClientId, isEmpty);
    expect(snapshot.imgbbApiKey, isEmpty);
  });

  test('JSON から provider とキーを復元する', () {
    final snapshot = ImageUploadSettingsSnapshot.fromJson({
      'provider': 'imgbb',
      'imgurClientId': 'imgur-id',
      'imgbbApiKey': 'imgbb-key',
    });

    expect(snapshot.provider, ImageUploadProvider.imgbb);
    expect(snapshot.imgurClientId, 'imgur-id');
    expect(snapshot.imgbbApiKey, 'imgbb-key');
  });

  test('保存した設定を再読込できる', () async {
    final storage = MemoryImageUploadSettingsStorage();
    final store = ImageUploadSettings(storage);
    await store.save(
      const ImageUploadSettingsSnapshot(
        provider: ImageUploadProvider.imgur,
        imgurClientId: 'abc123',
      ),
    );

    final reloaded = ImageUploadSettings(storage);
    await reloaded.load();

    expect(reloaded.snapshot.provider, ImageUploadProvider.imgur);
    expect(reloaded.snapshot.imgurClientId, 'abc123');
  });
}
