import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 現行一覧の並べ替えの既定。並べ替えシートで選んだものをそのまま覚えて、次に
/// 開いたときの既定にする。
///
/// 覚えるのは現行だけ。履歴・お気に入り・新着ありは「最後に見た順」など表示に
/// 合った並びで見たいことがほとんどで、その場で切り替えても次に開くときは既定
/// へ戻ってほしいため。
///
/// 値は [ThreadSort] の `name`（UI 側の enum に依存しないよう文字列で持つ）。
/// 知らない名前が入っていたら未設定として扱う。
class ThreadSortSettings extends ChangeNotifier {
  ThreadSortSettings(this._storage);

  static final ThreadSortSettings shared = ThreadSortSettings(
    FileThreadSortSettingsStorage(),
  );

  final ThreadSortSettingsStorage _storage;
  String? _currentSort;

  /// 現行一覧の既定の並び。未設定なら null（画面側の既定に従う）。
  String? get currentSort => _currentSort;

  Future<void> load() async {
    _currentSort = await _storage.load();
  }

  Future<void> saveCurrentSort(String? name) async {
    if (_currentSort == name) return;
    _currentSort = name;
    notifyListeners();
    // 覚え損ねても次に開いたとき既定に戻るだけなので、書けなくても投げない。
    try {
      await _storage.save(name);
    } catch (_) {}
  }
}

abstract interface class ThreadSortSettingsStorage {
  Future<String?> load();
  Future<void> save(String? name);
}

class FileThreadSortSettingsStorage implements ThreadSortSettingsStorage {
  FileThreadSortSettingsStorage({Directory? directory}) : _override = directory;

  final Directory? _override;
  static const _fileName = 'elec_thread_sort.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<String?> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      final name = json['current'];
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String? name) async {
    final file = await _file();
    await file.writeAsString(jsonEncode({'current': name}));
  }
}

class MemoryThreadSortSettingsStorage implements ThreadSortSettingsStorage {
  MemoryThreadSortSettingsStorage([this._name]);

  String? _name;

  String? get name => _name;

  @override
  Future<String?> load() async => _name;

  @override
  Future<void> save(String? name) async {
    _name = name;
  }
}
