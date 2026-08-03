import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../net/file_upload_settings.dart';
import '../net/file_uploader.dart';
import '../net/image_upload_settings.dart';
import '../net/imgur_uploader.dart';

/// 一度に選べる画像の枚数。
///
/// Imgur の匿名アップロードは時間あたりの回数に上限があり、**同梱の Client ID は
/// 利用者全員で共有する**ので、まとめて上げすぎると詰まる。
const int maxImagesPerPick = 6;

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

  /// ギャラリーから画像を選んでアップロードし、URL を返す。選ばなかった・失敗
  /// したときは空。進捗や失敗の文言は [onMessage] へ渡す。
  ///
  /// [prepare] を渡すと、選んだ画像をアップロードする前にそこへ通す（編集画面や
  /// 一覧画面）。null が返ったら送らずにやめる。
  Future<List<Uri>> pickAndUploadImages(
    void Function(String) onMessage, {
    Future<List<XFile>?> Function(List<XFile> picked)? prepare,
  }) async {
    final uploader = _imageUploader();
    if (!uploader.configured) {
      onMessage(_imageUploaderMissingMessage());
      return const [];
    }
    var picked = await _imagePicker.pickMultiImage(limit: maxImagesPerPick);
    if (picked.isEmpty) return const [];
    if (picked.length > maxImagesPerPick) {
      // limit を効かせられない環境（古い Android など）向けの保険。
      picked = picked.take(maxImagesPerPick).toList();
      onMessage('画像は一度に $maxImagesPerPick 枚までです');
    }

    final images = prepare == null ? picked : await prepare(picked);
    if (images == null || images.isEmpty) return const [];

    final urls = <Uri>[];
    for (var i = 0; i < images.length; i++) {
      onMessage(_uploadingMessage(i + 1, images.length));
      try {
        urls.add(await uploader.upload(images[i]));
      } on ImgurUploadException catch (e) {
        onMessage(_failureMessage(e.message, urls.length, images.length));
        return urls;
      } catch (e) {
        onMessage(
          _failureMessage('画像アップロードに失敗しました: $e', urls.length, images.length),
        );
        return urls;
      }
    }
    onMessage(
      images.length == 1 ? '画像URLを挿入しました' : '${images.length} 枚の画像URLを挿入しました',
    );
    return urls;
  }

  static String _uploadingMessage(int index, int total) =>
      total == 1 ? '画像をアップロード中...' : '画像をアップロード中... ($index/$total)';

  /// 途中で失敗したときの文言。**残りは送らずに止める**——レート制限に当たって
  /// いることが多く、続けても失敗を重ねるだけなので。
  static String _failureMessage(String reason, int done, int total) =>
      done == 0 ? reason : '$total 枚中 $done 枚をアップロードしました（$reason）';

  /// ファイルを選んでアップロードし、URL を返す。挙動は [pickAndUploadImages]
  /// と同様（こちらは 1 つずつ）。
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
