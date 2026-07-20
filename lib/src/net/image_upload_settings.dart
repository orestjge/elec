import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum ImageUploadProvider {
  defaultImgur,
  imgur,
  imgbb;

  String get label => switch (this) {
    ImageUploadProvider.defaultImgur => '既定の Imgur',
    ImageUploadProvider.imgur => '自分の Imgur Client ID',
    ImageUploadProvider.imgbb => 'ImgBB API Key',
  };
}

@immutable
class ImageUploadSettingsSnapshot {
  const ImageUploadSettingsSnapshot({
    this.provider = ImageUploadProvider.defaultImgur,
    this.imgurClientId = '',
    this.imgbbApiKey = '',
  });

  final ImageUploadProvider provider;
  final String imgurClientId;
  final String imgbbApiKey;

  ImageUploadSettingsSnapshot copyWith({
    ImageUploadProvider? provider,
    String? imgurClientId,
    String? imgbbApiKey,
  }) => ImageUploadSettingsSnapshot(
    provider: provider ?? this.provider,
    imgurClientId: imgurClientId ?? this.imgurClientId,
    imgbbApiKey: imgbbApiKey ?? this.imgbbApiKey,
  );

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'imgurClientId': imgurClientId,
    'imgbbApiKey': imgbbApiKey,
  };

  static ImageUploadSettingsSnapshot fromJson(Object? value) {
    if (value is! Map) return const ImageUploadSettingsSnapshot();
    final providerName = value['provider'];
    final provider = ImageUploadProvider.values
        .where((p) => p.name == providerName)
        .firstOrNull;
    return ImageUploadSettingsSnapshot(
      provider: provider ?? ImageUploadProvider.defaultImgur,
      imgurClientId: value['imgurClientId'] is String
          ? value['imgurClientId'] as String
          : '',
      imgbbApiKey: value['imgbbApiKey'] is String
          ? value['imgbbApiKey'] as String
          : '',
    );
  }
}

abstract interface class ImageUploadSettingsStorage {
  Future<ImageUploadSettingsSnapshot> load();
  Future<void> save(ImageUploadSettingsSnapshot snapshot);
}

class FileImageUploadSettingsStorage implements ImageUploadSettingsStorage {
  FileImageUploadSettingsStorage({Directory? directory})
    : _override = directory;

  final Directory? _override;
  static const _fileName = 'elec_image_upload.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<ImageUploadSettingsSnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const ImageUploadSettingsSnapshot();
      return ImageUploadSettingsSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      return const ImageUploadSettingsSnapshot();
    }
  }

  @override
  Future<void> save(ImageUploadSettingsSnapshot snapshot) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(snapshot.toJson()));
  }
}

class MemoryImageUploadSettingsStorage implements ImageUploadSettingsStorage {
  MemoryImageUploadSettingsStorage([
    this._snapshot = const ImageUploadSettingsSnapshot(),
  ]);

  ImageUploadSettingsSnapshot _snapshot;

  @override
  Future<ImageUploadSettingsSnapshot> load() async => _snapshot;

  @override
  Future<void> save(ImageUploadSettingsSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

class ImageUploadSettings extends ChangeNotifier {
  ImageUploadSettings(this._storage);

  static final ImageUploadSettings shared = ImageUploadSettings(
    FileImageUploadSettingsStorage(),
  );

  final ImageUploadSettingsStorage _storage;
  ImageUploadSettingsSnapshot _snapshot = const ImageUploadSettingsSnapshot();

  ImageUploadSettingsSnapshot get snapshot => _snapshot;

  Future<void> load() async {
    _snapshot = await _storage.load();
  }

  Future<void> save(ImageUploadSettingsSnapshot snapshot) async {
    _snapshot = snapshot;
    notifyListeners();
    await _storage.save(snapshot);
  }
}
