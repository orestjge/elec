import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum FileUploadProvider {
  catbox,
  uguu;

  String get label => switch (this) {
    FileUploadProvider.catbox => 'catbox.moe（長期）',
    FileUploadProvider.uguu => 'uguu.se（一時）',
  };
}

@immutable
class FileUploadSettingsSnapshot {
  const FileUploadSettingsSnapshot({
    this.provider = FileUploadProvider.catbox,
  });

  final FileUploadProvider provider;

  FileUploadSettingsSnapshot copyWith({FileUploadProvider? provider}) =>
      FileUploadSettingsSnapshot(provider: provider ?? this.provider);

  Map<String, Object?> toJson() => {'provider': provider.name};

  static FileUploadSettingsSnapshot fromJson(Object? value) {
    if (value is! Map) return const FileUploadSettingsSnapshot();
    final providerName = value['provider'];
    final provider = FileUploadProvider.values
        .where((p) => p.name == providerName)
        .firstOrNull;
    return FileUploadSettingsSnapshot(
      provider: provider ?? FileUploadProvider.catbox,
    );
  }
}

abstract interface class FileUploadSettingsStorage {
  Future<FileUploadSettingsSnapshot> load();
  Future<void> save(FileUploadSettingsSnapshot snapshot);
}

class FileFileUploadSettingsStorage implements FileUploadSettingsStorage {
  FileFileUploadSettingsStorage({Directory? directory}) : _override = directory;

  final Directory? _override;
  static const _fileName = 'elec_file_upload.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<FileUploadSettingsSnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const FileUploadSettingsSnapshot();
      return FileUploadSettingsSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      return const FileUploadSettingsSnapshot();
    }
  }

  @override
  Future<void> save(FileUploadSettingsSnapshot snapshot) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(snapshot.toJson()));
  }
}

class MemoryFileUploadSettingsStorage implements FileUploadSettingsStorage {
  MemoryFileUploadSettingsStorage([
    this._snapshot = const FileUploadSettingsSnapshot(),
  ]);

  FileUploadSettingsSnapshot _snapshot;

  @override
  Future<FileUploadSettingsSnapshot> load() async => _snapshot;

  @override
  Future<void> save(FileUploadSettingsSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

class FileUploadSettings extends ChangeNotifier {
  FileUploadSettings(this._storage);

  static final FileUploadSettings shared = FileUploadSettings(
    FileFileUploadSettingsStorage(),
  );

  final FileUploadSettingsStorage _storage;
  FileUploadSettingsSnapshot _snapshot = const FileUploadSettingsSnapshot();

  FileUploadSettingsSnapshot get snapshot => _snapshot;

  Future<void> load() async {
    _snapshot = await _storage.load();
  }

  Future<void> save(FileUploadSettingsSnapshot snapshot) async {
    _snapshot = snapshot;
    notifyListeners();
    await _storage.save(snapshot);
  }
}
