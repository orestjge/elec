import 'package:edge_sjis/edge_sjis.dart';

import 'models.dart';
import 'subject_parser.dart' show BbsTextEncoding, decodeBbsText;

/// dat の日付+ID 欄をパースするための正規表現。
///
/// 例: `2025/11/03(月) 02:14:51.907 ID:0.fNwf8r5 BE:123-abcd`
/// - 日付部分（曜日込み、ミリ秒任意）
/// - `ID:xxx`（任意）
/// - `BE:xxx`（任意、5ch 互換のため）
final _dateRe = RegExp(
  r'^(\d{4}/\d{2}/\d{2}\([^)]*\)\s\d{2}:\d{2}:\d{2}(?:\.\d+)?)',
);
final _idRe = RegExp(r'ID:([^\s]+)');
final _beRe = RegExp(r'BE:([^\s]+)');

/// dat の行フォーマット。掲示板の系統でフィールドの並びが違う。
enum DatFormat {
  /// 5ch / eddist の dat。`name<>mail<>date ID:id<>body<>title`。
  fivech,

  /// したらば（`rawmode.cgi`）。`番号<>name<>mail<>date<>body<>title<>id`。
  shitaraba,
}

/// dat 全体（SJIS バイト列）をパースして [Res] のリストにする。
///
/// **バイト列を直接渡すこと。** チャンクごとに文字列へデコードしてから結合
/// すると、Range のバイト境界がマルチバイト文字を割って壊れる。内部で
/// [splitDatLines] により完全な行だけを取り出し、行単位でデコードする。
///
/// [startNumber] は最初の行に振るレス番号（差分取得で途中から渡すとき用、
/// 既定 1）。したらばは行頭にレス番号を持つのでそちらを優先する。
List<Res> parseDat(
  List<int> datBytes, {
  int startNumber = 1,
  BbsTextEncoding encoding = BbsTextEncoding.sjis,
  DatFormat format = DatFormat.fivech,
}) {
  final lines = splitDatLines(datBytes);
  final result = <Res>[];
  for (var i = 0; i < lines.length; i++) {
    final line = decodeBbsText(lines[i], encoding);
    result.add(
      format == DatFormat.shitaraba
          ? parseShitarabaDatLine(line, startNumber + i)
          : parseDatLine(line, startNumber + i),
    );
  }
  return result;
}

/// デコード済みの dat 1 行をパースする。
///
/// 行の形式（`eddist-core/src/domain/res.rs`）:
/// - 通常: `name<>mail<>date ID:id<> body <>title`
/// - あぼーん: `あぼーん<>あぼーん<><> あぼーん <>title`
/// - 1001: `1001<><>Over 1000 Thread<>body<>`
Res parseDatLine(String line, int number) {
  // 末尾の改行は splitDatLines で落ちているが、念のため。
  final parts = line.replaceAll('\r', '').split('<>');

  String field(int i) => i < parts.length ? parts[i] : '';

  final name = field(0);
  final mail = field(1);
  final dateField = field(2);
  final rawBody = field(3);
  final title = parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null;

  // 本文は dat 上で前後を 1 スペースずつで囲まれる（`<> {body} <>`）。
  // その規約分だけを剥がす。trim() だと本文自身の前後空白まで消えてしまう。
  final body = _stripBodyPadding(rawBody);

  // 種別判定。あぼーんと 1001 は特徴的な固定フィールドで見分ける。
  final ResKind kind;
  if (name == 'あぼーん' && mail == 'あぼーん') {
    kind = ResKind.abone;
  } else if (name == '1001' && dateField == 'Over 1000 Thread') {
    kind = ResKind.over1000;
  } else {
    kind = ResKind.normal;
  }

  String? id;
  String? beId;
  String dateText = dateField;
  DateTime? dateTime;
  if (kind == ResKind.normal) {
    id = _idRe.firstMatch(dateField)?.group(1);
    beId = _beRe.firstMatch(dateField)?.group(1);
    final dateMatch = _dateRe.firstMatch(dateField);
    if (dateMatch != null) {
      dateText = dateMatch.group(1)!;
      dateTime = _parseJstDate(dateText);
    }
  } else {
    // abone / 1001 は日付欄を日付として扱わない。
    dateText = kind == ResKind.abone ? '' : dateField;
  }

  return Res(
    number: number,
    name: name,
    mail: mail,
    dateText: dateText,
    dateTime: dateTime,
    id: id,
    beId: beId,
    body: body,
    kind: kind,
    threadTitle: title,
    rawDateField: dateField,
  );
}

/// したらば（`rawmode.cgi`）の 1 行をパースする。
///
/// 行の形式: `番号<>名前<>メール<>日付<>本文<>スレタイ<>ID`
///
/// 5ch / eddist との違いは 3 点:
/// - **行頭にレス番号がある**。削除されたレスは行ごと消えて番号が飛ぶので、
///   行位置ではなくこの値を使う（[fallbackNumber] は番号が読めないとき用）。
/// - 日付欄に `ID:` を含まない。ID は最終フィールドで、ID 非表示の板では空。
/// - 本文は `<> {body} <>` のスペース詰めをしない。
Res parseShitarabaDatLine(String line, int fallbackNumber) {
  final parts = line.replaceAll('\r', '').split('<>');

  String field(int i) => i < parts.length ? parts[i] : '';

  final dateField = field(3);
  final title = field(5);
  // ID 欄は板の設定で `ID:xxx` と素の `xxx` の両方があり得る。
  final rawId = field(6).trim();
  final id = rawId.startsWith('ID:') ? rawId.substring(3) : rawId;

  return Res(
    number: int.tryParse(field(0).trim()) ?? fallbackNumber,
    name: field(1),
    mail: field(2),
    dateText: _dateRe.firstMatch(dateField)?.group(1) ?? dateField,
    dateTime: _parseJstDate(dateField),
    id: id.isEmpty ? null : id,
    beId: null,
    body: field(4),
    kind: ResKind.normal,
    threadTitle: title.isEmpty ? null : title,
    // したらばの日付欄は ID を含まない（ID は最終フィールド）。
    rawDateField: dateField,
  );
}

/// `<> {body} <>` の規約による前後 1 スペースだけを剥がす。
String _stripBodyPadding(String raw) {
  var s = raw;
  if (s.startsWith(' ')) s = s.substring(1);
  if (s.endsWith(' ')) s = s.substring(0, s.length - 1);
  return s;
}

final _dateParseRe = RegExp(
  r'^(\d{4})/(\d{2})/(\d{2})\([^)]*\)\s(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?',
);

/// `2025/11/03(月) 02:14:51.907` を UTC の瞬間に変換する。
///
/// dat の時刻は JST（UTC+9）表記。曜日は無視し、9 時間引いて UTC に直す。
DateTime? _parseJstDate(String text) {
  final m = _dateParseRe.firstMatch(text);
  if (m == null) return null;
  final ms = m.group(7);
  final jst = DateTime.utc(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
    ms == null ? 0 : int.parse(ms.padRight(3, '0').substring(0, 3)),
  );
  return jst.subtract(const Duration(hours: 9));
}
