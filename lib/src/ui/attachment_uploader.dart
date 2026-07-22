import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../net/file_upload_settings.dart';
import '../net/file_uploader.dart';
import '../net/image_upload_settings.dart';
import '../net/imgur_uploader.dart';

/// 画像・ファイルの選択とアップロードをまとめて扱う。スレ立てとレス書き込みで
/// 共用する。UI には触れず、進捗・結果の文言は [onMessage] で呼び出し側へ返す。
class AttachmentUploader {
  AttachmentUploader({
    ImagePicker? imagePicker,
    ImgurUploader? imgurUploader,
    ImageUploadSettings? imageUploadSettings,
    FileUploadSettings? fileUploadSettings,
  }) : _imagePicker = imagePicker ?? ImagePicker(),
       _imgurUploader =
           imgurUploader ??
           const ImgurUploader(
             clientId: String.fromEnvironment('IMGUR_CLIENT_ID'),
           ),
       _imageUploadSettings = imageUploadSettings ?? ImageUploadSettings.shared,
       _fileUploadSettings = fileUploadSettings ?? FileUploadSettings.shared;

  static const _bundledImgurClientId = String.fromEnvironment(
    'ELEC_DEFAULT_IMGUR_CLIENT_ID',
  );

  final ImagePicker _imagePicker;
  final ImgurUploader _imgurUploader;
  final ImageUploadSettings _imageUploadSettings;
  final FileUploadSettings _fileUploadSettings;

  /// ギャラリーから画像を選んでアップロードし、URL を返す。選ばなかった・失敗した
  /// ときは null。進捗や失敗の文言は [onMessage] へ渡す。
  Future<Uri?> pickAndUploadImage(void Function(String) onMessage) async {
    final uploader = _imageUploader();
    if (!uploader.configured) {
      onMessage(_imageUploaderMissingMessage());
      return null;
    }
    final image = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (image == null) return null;

    onMessage('画像をアップロード中...');
    try {
      final url = await uploader.upload(image);
      onMessage('画像URLを挿入しました');
      return url;
    } on ImgurUploadException catch (e) {
      onMessage(e.message);
      return null;
    } catch (e) {
      onMessage('画像アップロードに失敗しました: $e');
      return null;
    }
  }

  /// ファイルを選んでアップロードし、URL を返す。挙動は [pickAndUploadImage] と同様。
  Future<Uri?> pickAndUploadFile(void Function(String) onMessage) async {
    final picked = await FilePicker.pickFiles(withData: true);
    final file = (picked == null || picked.files.isEmpty)
        ? null
        : picked.files.first;
    if (file == null) return null;

    final bytes = file.bytes;
    if (bytes == null) {
      onMessage('ファイルを読み込めませんでした');
      return null;
    }

    onMessage('ファイルをアップロード中...');
    try {
      final url = await _fileUploader().upload(
        bytes: bytes,
        filename: file.name,
      );
      onMessage('ファイルURLを挿入しました');
      return url;
    } on FileUploadException catch (e) {
      onMessage(e.message);
      return null;
    } catch (e) {
      onMessage('ファイルのアップロードに失敗しました: $e');
      return null;
    }
  }

  ImageUploader _imageUploader() {
    final settings = _imageUploadSettings.snapshot;
    return switch (settings.provider) {
      ImageUploadProvider.defaultImgur =>
        _bundledImgurClientId.isNotEmpty
            ? const ImgurUploader(clientId: _bundledImgurClientId)
            : _imgurUploader,
      ImageUploadProvider.imgur => ImgurUploader(
        clientId: settings.imgurClientId,
      ),
      ImageUploadProvider.imgbb => ImgBbUploader(apiKey: settings.imgbbApiKey),
    };
  }

  String _imageUploaderMissingMessage() {
    return switch (_imageUploadSettings.snapshot.provider) {
      ImageUploadProvider.defaultImgur => '既定の Imgur Client ID が設定されていません',
      ImageUploadProvider.imgur => 'Imgur Client ID が設定されていません',
      ImageUploadProvider.imgbb => 'ImgBB API Key が設定されていません',
    };
  }

  FileUploader _fileUploader() {
    return switch (_fileUploadSettings.snapshot.provider) {
      FileUploadProvider.catbox => const CatboxUploader(),
      FileUploadProvider.uguu => const UguuUploader(),
    };
  }
}
