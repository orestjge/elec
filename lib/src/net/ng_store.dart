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
  const NgSnapshot({
    this.words = const [],
    this.ids = const {},
    this.creators = const {},
  });
  final List<NgWord> words;
  final Set<String> ids;

  /// NG にしたスレ立て人の metadent（8 文字）。`subject-metadent.txt` の
  /// `[xxx★]` をそのまま持つ。
  final Set<String> creators;
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
      final creatorsJson = json['creators'];
      return NgSnapshot(
        words: wordsJson is List
            ? wordsJson
                  .map(NgWord.fromJson)
                  .whereType<NgWord>()
                  .toList(growable: false)
            : const [],
        ids: idsJson is List ? idsJson.whereType<String>().toSet() : const {},
        creators: creatorsJson is List
            ? creatorsJson.whereType<String>().toSet()
            : const {},
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
        'creators': snapshot.creators.toList()..sort(),
      }),
    );
  }
}

class MemoryNgStorage implements NgStorage {
  MemoryNgStorage([
    List<NgWord>? words,
    Set<String>? ids,
    Set<String>? creators,
  ]) : _words = words ?? [],
       _ids = ids ?? {},
       _creators = creators ?? {};
  List<NgWord> _words;
  Set<String> _ids;
  Set<String> _creators;

  @override
  Future<NgSnapshot> load() async => NgSnapshot(
    words: List.of(_words),
    ids: Set.of(_ids),
    creators: Set.of(_creators),
  );

  @override
  Future<void> save(NgSnapshot snapshot) async {
    _words = List.of(snapshot.words);
    _ids = Set.of(snapshot.ids);
    _creators = Set.of(snapshot.creators);
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
  Set<String> _creators = {};

  /// 判定用にコンパイル済みのルール。正規表現ワードは [RegExp]、
  /// 部分一致ワードは null（小文字化して contains する）。
  List<(NgWord, RegExp?)> _compiled = const [];

  /// NG ID から導いた 4 文字キー（= 表示 ID の先頭 3＋末尾 1）。metadent の
  /// 後半 4 文字と突き合わせて、その ID のスレ立てを一覧で判定するのに使う。
  Set<String> _idKeys = {};
  Future<void> _pendingSave = Future.value();

  Future<void> load() async {
    final snapshot = await _storage.load();
    _words = List.of(snapshot.words);
    _ids = Set.of(snapshot.ids);
    _creators = Set.of(snapshot.creators);
    _recompile();
  }

  /// 登録済み NG ワード（登録順）。
  List<NgWord> get words => List.unmodifiable(_words);

  /// 登録済み NG の ID（昇順）。
  List<String> get ids => _ids.toList()..sort();

  /// 登録済み NG のスレ立て人 metadent（昇順）。
  List<String> get creators => _creators.toList()..sort();

  bool isNgId(String? id) => id != null && _ids.contains(id);

  /// metadent（8 文字）→ スレ主判定用の 4 文字キー（後半 4 文字）。
  /// = そのスレ主の表示 ID の「先頭 3＋末尾 1」。短すぎるなら null。
  static String? creatorKeyFromMetadent(String? metadent) =>
      (metadent != null && metadent.length >= 8)
      ? metadent.substring(4, 8)
      : null;

  /// 表示 ID（9 文字想定）→ スレ主判定用の 4 文字キー（先頭 3＋末尾 1）。
  static String? creatorKeyFromId(String? id) => (id != null && id.length >= 2)
      ? id.substring(0, id.length < 3 ? id.length : 3) +
            id.substring(id.length - 1)
      : null;

  /// スレ立て人が NG か。[metadent] は `subject-metadent.txt` の `[xxx★]`。
  /// 直接登録した metadent に一致するか、NG ID から導いた 4 文字キーに
  /// 後半 4 文字が一致すれば NG。
  bool isNgCreator(String? metadent) {
    if (metadent == null) return false;
    if (_creators.contains(metadent)) return true;
    final key = creatorKeyFromMetadent(metadent);
    return key != null && _idKeys.contains(key);
  }

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
    _recomputeIdKeys();
    notifyListeners();
    await _save();
  }

  Future<void> removeId(String id) async {
    if (!_ids.remove(id)) return;
    _recomputeIdKeys();
    notifyListeners();
    await _save();
  }

  Future<void> addCreator(String metadent) async {
    if (metadent.isEmpty || !_creators.add(metadent)) return;
    notifyListeners();
    await _save();
  }

  Future<void> removeCreator(String metadent) async {
    if (!_creators.remove(metadent)) return;
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
    _recomputeIdKeys();
  }

  void _recomputeIdKeys() {
    _idKeys = {
      for (final id in _ids)
        if (creatorKeyFromId(id) case final key?) key,
    };
  }

  RegExp? _tryCompile(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final snapshot = NgSnapshot(
      words: List.of(_words),
      ids: Set.of(_ids),
      creators: Set.of(_creators),
    );
    _pendingSave = _pendingSave.then((_) => _storage.save(snapshot));
    await _pendingSave;
  }
}
