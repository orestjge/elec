import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// スレ画面でのレスの並べ方。
enum ThreadLayout {
  /// 番号順。dat の順にそのまま並べる。
  number,

  /// ツリー。開いた時点までのレスを `>>N` でぶら下げ、その後に増えたレスは
  /// ツリーへ挿し込まず下へ足していく（既定）。詳細は `thread_tree.dart`。
  tree,
}

/// レス 1 件の組み方。
///
/// どちらが良いかはスレの性格で変わる。identicon が効くのは**同じ人が何度も
/// 書いているとき**で、単発 ID ばかりのスレでは絵は誰も語らずただ場所を取る。
/// 逆に数人が言い合っているスレでは、絵があると誰の発言かを追うのが格段に楽に
/// なる。板やスレによって当たり外れがあるので、選べるようにしてある。
enum ResLayout {
  /// identicon をレスの左に柱として立て、ヘッダは中身があるときだけ出し、時刻は
  /// レスの足元に置く。絵が大きく、連投を追いやすい。
  gutter,

  /// identicon を小さくしてヘッダの行に並べ、名前・時刻とまとめて 1 行に収める
  /// （既定）。絵は小さくなるが、レス 1 件あたりの横幅も高さも節約できる。
  header,
}

/// スレ画面の表示設定。
///
/// 並べ方の既定は [ThreadLayout.tree]。返信の筋を追えるほうが読みやすいスレが
/// 多いため。番号順は「新着が必ず一番下に来る」という掲示板の素の読み方で、
/// 実況には強いので、そちらが良い人は設定で戻せる。
class ThreadViewSettings extends ChangeNotifier {
  ThreadViewSettings(this._storage);

  static final ThreadViewSettings shared = ThreadViewSettings(
    FileThreadViewSettingsStorage(),
  );

  final ThreadViewSettingsStorage _storage;
  ThreadLayout _layout = ThreadLayout.tree;
  ResLayout _resLayout = ResLayout.header;
  bool _linkPreviews = true;
  bool _loaded = false;
  bool _replySwipeHintSeen = false;

  ThreadLayout get layout => _layout;

  /// レス 1 件の組み方。既定は [ResLayout.header]。
  ResLayout get resLayout => _resLayout;

  /// 行を単独で占めるリンクの OGP を取りに行き、カードで見せるか。
  ///
  /// 既定は真。画像を自動で読み込むのと釣り合う扱いにしてある。ただし対象が
  /// 「画像 URL」から**あらゆるリンク**に広がり、リンク先には読んだ人の IP が
  /// 渡る。踏みたくないリンクにも当たるので、丸ごと切れるようにしてある。
  bool get linkPreviews => _linkPreviews;

  /// 「レスを左へスワイプすると返信」のヒントを一度でも出したか。
  ///
  /// スワイプは画面に何も置かない操作なので、初めてスレを開いたときだけ一度
  /// 知らせる（`PostItem.onReply`）。
  ///
  /// **設定をまだ読めていないうちは「出した」扱いにする。** 出したことを覚えて
  /// おけない状態でヒントを出すと、一度きりのつもりが毎回出るものになるため。
  bool get replySwipeHintSeen => !_loaded || _replySwipeHintSeen;

  Future<void> load() async {
    final values = await _storage.load();
    _layout = _parse(values['layout']) ?? ThreadLayout.tree;
    _resLayout = _parseRes(values['resLayout']) ?? ResLayout.header;
    _linkPreviews = switch (values['linkPreviews']) {
      final bool value => value,
      // 古い設定ファイル（この項目が無い）は既定のまま。
      _ => true,
    };
    _replySwipeHintSeen = values['replySwipeHintSeen'] == true;
    _loaded = true;
  }

  Future<void> setLayout(ThreadLayout layout) async {
    if (_layout == layout) return;
    _layout = layout;
    notifyListeners();
    await _save();
  }

  Future<void> setResLayout(ResLayout layout) async {
    if (_resLayout == layout) return;
    _resLayout = layout;
    notifyListeners();
    await _save();
  }

  Future<void> setLinkPreviews(bool enabled) async {
    if (_linkPreviews == enabled) return;
    _linkPreviews = enabled;
    notifyListeners();
    await _save();
  }

  /// ヒントを出したことを覚える。表示に関わる設定ではないので通知はしない。
  Future<void> markReplySwipeHintSeen() async {
    if (_replySwipeHintSeen) return;
    _replySwipeHintSeen = true;
    await _save();
  }

  /// 覚え損ねても次に開いたとき既定に戻るだけなので、書けなくても投げない。
  Future<void> _save() async {
    try {
      await _storage.save({
        'layout': _layout.name,
        'resLayout': _resLayout.name,
        'linkPreviews': _linkPreviews,
        'replySwipeHintSeen': _replySwipeHintSeen,
      });
    } catch (_) {}
  }

  /// 知らない名前（古い/新しい版が書いたもの）は未設定として扱う。
  static ThreadLayout? _parse(Object? name) {
    for (final layout in ThreadLayout.values) {
      if (layout.name == name) return layout;
    }
    return null;
  }

  static ResLayout? _parseRes(Object? name) {
    for (final layout in ResLayout.values) {
      if (layout.name == name) return layout;
    }
    return null;
  }
}

abstract interface class ThreadViewSettingsStorage {
  Future<Map<String, Object?>> load();
  Future<void> save(Map<String, Object?> values);
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
  Future<Map<String, Object?>> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const {};
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> save(Map<String, Object?> values) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(values));
  }
}

class MemoryThreadViewSettingsStorage implements ThreadViewSettingsStorage {
  MemoryThreadViewSettingsStorage([this._values = const {}]);

  Map<String, Object?> _values;

  Map<String, Object?> get values => _values;

  @override
  Future<Map<String, Object?>> load() async => _values;

  @override
  Future<void> save(Map<String, Object?> values) async {
    _values = values;
  }
}
