import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// NG ワード 1 件。正規表現として扱うかを持つ。
@immutable
class NgWord {
  const NgWord(this.pattern, {this.isRegex = false});

  /// 一致させる文字列。[isRegex] が true なら正規表現、false なら部分一致。
  final String pattern;

  /// 正規表現として扱うか。
  final bool isRegex;

  Map<String, Object?> toJson() => {'pattern': pattern, 'isRegex': isRegex};

  static NgWord? fromJson(Object? value) {
    if (value is! Map) return null;
    final pattern = value['pattern'];
    if (pattern is! String) return null;
    return NgWord(pattern, isRegex: value['isRegex'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is NgWord && other.pattern == pattern && other.isRegex == isRegex;

  @override
  int get hashCode => Object.hash(pattern, isRegex);
}

/// NG 設定の保存内容。
class NgSnapshot {
  const NgSnapshot({this.words = const [], this.ids = const {}});
  final List<NgWord> words;
  final Set<String> ids;
}

/// NG 設定の保存先の抽象。
abstract interface class NgStorage {
  Future<NgSnapshot> load();
  Future<void> save(NgSnapshot snapshot);
}

class FileNgStorage implements NgStorage {
  FileNgStorage({Directory? directory}) : _override = directory;
  final Directory? _override;
  static const _fileName = 'elec_ng.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<NgSnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const NgSnapshot();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return const NgSnapshot();
      final wordsJson = json['words'];
      final idsJson = json['ids'];
      return NgSnapshot(
        words: wordsJson is List
            ? wordsJson
                  .map(NgWord.fromJson)
                  .whereType<NgWord>()
                  .toList(growable: false)
            : const [],
        ids: idsJson is List ? idsJson.whereType<String>().toSet() : const {},
      );
    } catch (_) {
      return const NgSnapshot();
    }
  }

  @override
  Future<void> save(NgSnapshot snapshot) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({
        'words': snapshot.words.map((w) => w.toJson()).toList(),
        'ids': snapshot.ids.toList()..sort(),
      }),
    );
  }
}

class MemoryNgStorage implements NgStorage {
  MemoryNgStorage([List<NgWord>? words, Set<String>? ids])
    : _words = words ?? [],
      _ids = ids ?? {};
  List<NgWord> _words;
  Set<String> _ids;

  @override
  Future<NgSnapshot> load() async =>
      NgSnapshot(words: List.of(_words), ids: Set.of(_ids));

  @override
  Future<void> save(NgSnapshot snapshot) async {
    _words = List.of(snapshot.words);
    _ids = Set.of(snapshot.ids);
  }
}

/// NG（あぼーん）設定。ワード（正規表現可）とユーザー ID で判定する。
///
/// 変更を [ChangeNotifier] で通知するので、開いているスレ画面へ即時反映できる。
class NgStore extends ChangeNotifier {
  NgStore(this._storage);

  static final NgStore shared = NgStore(FileNgStorage());

  final NgStorage _storage;
  List<NgWord> _words = [];
  Set<String> _ids = {};

  /// 判定用にコンパイル済みのルール。正規表現ワードは [RegExp]、
  /// 部分一致ワードは null（小文字化して contains する）。
  List<(NgWord, RegExp?)> _compiled = const [];
  Future<void> _pendingSave = Future.value();

  Future<void> load() async {
    final snapshot = await _storage.load();
    _words = List.of(snapshot.words);
    _ids = Set.of(snapshot.ids);
    _recompile();
  }

  /// 登録済み NG ワード（登録順）。
  List<NgWord> get words => List.unmodifiable(_words);

  /// 登録済み NG の ID（昇順）。
  List<String> get ids => _ids.toList()..sort();

  bool isNgId(String? id) => id != null && _ids.contains(id);

  /// [res] が NG に該当するか。ID・名前・本文（整形後）を見る。
  bool matches(Res res) {
    if (res.id != null && _ids.contains(res.id)) return true;
    if (_compiled.isEmpty) return false;
    final target = '${htmlToText(res.name)}\n${htmlToText(res.body)}';
    final lower = target.toLowerCase();
    for (final (word, regex) in _compiled) {
      if (regex != null) {
        if (regex.hasMatch(target)) return true;
      } else if (lower.contains(word.pattern.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  Future<void> addWord(NgWord word) async {
    if (word.pattern.isEmpty || _words.contains(word)) return;
    _words.add(word);
    _recompile();
    notifyListeners();
    await _save();
  }

  Future<void> removeWord(NgWord word) async {
    if (!_words.remove(word)) return;
    _recompile();
    notifyListeners();
    await _save();
  }

  Future<void> addId(String id) async {
    if (id.isEmpty || !_ids.add(id)) return;
    notifyListeners();
    await _save();
  }

  Future<void> removeId(String id) async {
    if (!_ids.remove(id)) return;
    notifyListeners();
    await _save();
  }

  /// 正規表現として妥当か（設定 UI の入力チェック用）。
  static bool isValidRegex(String pattern) {
    try {
      RegExp(pattern);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _recompile() {
    final out = <(NgWord, RegExp?)>[];
    for (final word in _words) {
      if (word.pattern.isEmpty) continue;
      if (word.isRegex) {
        final regex = _tryCompile(word.pattern);
        if (regex != null) out.add((word, regex));
      } else {
        out.add((word, null));
      }
    }
    _compiled = out;
  }

  RegExp? _tryCompile(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final snapshot = NgSnapshot(words: List.of(_words), ids: Set.of(_ids));
    _pendingSave = _pendingSave.then((_) => _storage.save(snapshot));
    await _pendingSave;
  }
}
