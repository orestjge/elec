import 'package:edge_sjis/edge_sjis.dart';

/// `SETTING.TXT`（5ch 互換の板設定）をパースした値。
///
/// エッヂ・5ch 双方が 200・`key=value`（1 行 1 項目・SJIS）で返す。板の表示名や
/// デフォルト名、どんぐり有無（[[多板対応に向けた実測]]）の判別に使う。取れない
/// 値は null。
class BoardSetting {
  const BoardSetting({required this.values});

  /// 生の `key=value` マップ。想定外のキーもそのまま持つ。
  final Map<String, String> values;

  /// 板の表示名（`BBS_TITLE`）。
  String? get title => values['BBS_TITLE'];

  /// 名前欄が空のときのデフォルト名（`BBS_NONAME_NAME`）。
  String? get defaultName => values['BBS_NONAME_NAME'];

  /// どんぐり（MonaTicket）システムの有効値。5ch のどんぐり板で `1` / `2`。
  /// 無ければ null（＝どんぐり無し、またはエッヂ）。
  String? get acorn => values['BBS_ACORN'];

  /// どんぐりゲートが有効か（`BBS_ACORN` が 1 以上）。
  bool get hasAcorn {
    final n = int.tryParse(acorn ?? '');
    return n != null && n >= 1;
  }

  /// 本文の最大文字数（`BBS_MESSAGE_COUNT`）。
  int? get messageMaxCount => int.tryParse(values['BBS_MESSAGE_COUNT'] ?? '');

  /// スレタイの最大文字数（`BBS_SUBJECT_COUNT`）。
  int? get subjectMaxCount => int.tryParse(values['BBS_SUBJECT_COUNT'] ?? '');
}

/// `SETTING.TXT` のバイト列（SJIS）をパースする。
///
/// 1 行 1 項目・`key=value`。`=` を含まない行や空行は無視する。値に `=` が
/// 含まれても最初の `=` だけで分割する。
BoardSetting parseSettingTxt(List<int> bytes) {
  final text = decodeSjis(bytes);
  final values = <String, String>{};
  for (final rawLine in text.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line.isEmpty) continue;
    final idx = line.indexOf('=');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    if (key.isEmpty) continue;
    values[key] = value;
  }
  return BoardSetting(values: values);
}
