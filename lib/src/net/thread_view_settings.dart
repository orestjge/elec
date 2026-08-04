import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// スレ画面でのレスの並べ方。
enum ThreadLayout {
  /// 番号順。dat の順にそのまま並べる（既定）。
  number,

  /// ツリー。開いた時点までのレスを `>>N` でぶら下げ、その後に増えたレスは
  /// ツリーへ挿し込まず下へ足していく。詳細は `thread_tree.dart`。
  tree,
}

/// スレ画面の表示設定。今のところ並べ方だけ。
///
/// 既定は [ThreadLayout.number]。番号順は「新着が必ず一番下に来る」という
/// 掲示板の素の読み方で、実況にも強い。ツリーは返信の筋を追いやすい代わりに
/// レスが番号順に並ばないので、選んだ人にだけ出す。
class ThreadViewSettings extends ChangeNotifier {
  ThreadViewSettings(this._storage);

  static final ThreadViewSettings shared = ThreadViewSettings(
    FileThreadViewSettingsStorage(),
  );

  final ThreadViewSettingsStorage _storage;
  ThreadLayout _layout = ThreadLayout.number;

  ThreadLayout get layout => _layout;

  Future<void> load() async {
    _layout = _parse(await _storage.load()) ?? ThreadLayout.number;
  }

  Future<void> setLayout(ThreadLayout layout) async {
    if (_layout == layout) return;
    _layout = layout;
    notifyListeners();
    // 覚え損ねても次に開いたとき既定に戻るだけなので、書けなくても投げない。
    try {
      await _storage.save(layout.name);
    } catch (_) {}
  }

  /// 知らない名前（古い/新しい版が書いたもの）は未設定として扱う。
  static ThreadLayout? _parse(String? name) {
    for (final layout in ThreadLayout.values) {
      if (layout.name == name) return layout;
    }
    return null;
  }
}

abstract interface class ThreadViewSettingsStorage {
  Future<String?> load();
  Future<void> save(String name);
}

class FileThreadViewSettingsStorage implements ThreadViewSettingsStorage {
  FileThreadViewSettingsStorage({Directory? directory}) : _override = directory;

  final Directory? _override;
  static const _fileName = 'elec_thread_view.json';

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
      final name = json['layout'];
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String name) async {
    final file = await _file();
    await file.writeAsString(jsonEncode({'layout': name}));
  }
}

class MemoryThreadViewSettingsStorage implements ThreadViewSettingsStorage {
  MemoryThreadViewSettingsStorage([this._name]);

  String? _name;

  String? get name => _name;

  @override
  Future<String?> load() async => _name;

  @override
  Future<void> save(String name) async {
    _name = name;
  }
}
