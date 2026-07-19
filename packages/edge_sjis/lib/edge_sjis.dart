/// エッヂ (eddist) / 5ch 互換掲示板のワイヤフォーマットは Windows-31J (CP932)。
///
/// dart:convert に Shift_JIS は無いため jis0208 の [Windows31JCodec] を使う。
/// **charset パッケージを使ってはいけない** — 詳細は README.md。
library;

import 'package:jis0208/jis0208.dart';

/// 破損バイトで例外を投げる版。完全性が保証された入力にのみ使う。
final _strict = Windows31JCodec();

final _decoderLenient = Windows31JDecoder(allowMalformed: true);

/// パーセントエンコードせず素通しできる文字。
///
/// application/x-www-form-urlencoded の unreserved 集合。
/// `~` は CP932 で表現できない U+301C と紛らわしいが、ここでは ASCII の
/// チルダ (U+007E) なのでそのまま通してよい。
final _unreserved = RegExp(r'^[A-Za-z0-9\-_.*~]$');

/// Windows-31J のバイト列を文字列にデコードする。
///
/// [allowMalformed] が true なら、壊れたバイトは置換文字になる。dat には
/// 稀に不正なバイトが混ざるため、**表示用のデコードでは true を推奨**する。
/// 1 バイトの破損でスレッド全体の描画を落とさないため。
String decodeSjis(List<int> bytes, {bool allowMalformed = true}) =>
    allowMalformed ? _decoderLenient.convert(bytes) : _strict.decode(bytes);

/// Windows-31J のバイト列を LF で分割し、**完全な行だけ**を返す。
///
/// Range による差分取得ではバイト境界がマルチバイト文字の途中に落ちるため、
/// チャンクを個別にデコードすると必ず壊れる。バイト列のまま結合・分割し、
/// 完全な行だけをデコードすること。
///
/// LF 分割が安全なのは、Windows-31J の trail byte が 0x40-0x7E / 0x80-0xFC で、
/// 0x0A がどちらの範囲にも入らないため。つまり文字の途中に LF は現れない。
///
/// 末尾の不完全な行は捨てられる (次の差分取得で届く)。呼び出し側はバイト列
/// 全体を保持し続け、追記のたびに再分割すればよい。
List<List<int>> splitDatLines(List<int> bytes) {
  final lines = <List<int>>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0A) {
      lines.add(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  return lines;
}

/// [ch] が Windows-31J で表現できるか。
///
/// 表現できない文字 (`〜` U+301C、絵文字、`𠮷` などのサロゲートペア) は
/// [encodeFormValue] で数値文字参照に変換される。入力欄で事前に警告を出す
/// 用途にも使える。
bool isEncodable(String ch) =>
    !_isReplacedWithQuestionMark(_strict.encode(ch), ch);

/// jis0208 のエンコーダは表現できない文字を**例外を投げずに** `?` (0x3F) へ
/// 置き換える。これを検出する唯一の方法が、結果が単一の 0x3F でありながら
/// 入力が `?` そのものではない、という判定。
bool _isReplacedWithQuestionMark(List<int> bytes, String ch) =>
    bytes.length == 1 && bytes[0] == 0x3F && ch != '?';

/// bbs.cgi の application/x-www-form-urlencoded な値をエンコードする。
///
/// **Windows31JCodec.encode() を直接呼ばず、必ずこの関数を通すこと。**
/// 直接呼ぶと `〜` や絵文字が無警告で `?` に化ける。
///
/// ブラウザのフォーム送信を再現する。
/// - Windows-31J で表現できない文字は数値文字参照 `&#NNNNN;` にする
/// - 半角スペースは `+`
/// - 改行は CRLF (`%0D%0A`)
///
/// サーバ側 (`eddist-server/src/domain/utils.rs` の `sanitize_base`) が
/// `\r` を削除し `\n` を `<br>` に変換し、`< > " '` をエスケープする。
/// **したがってクライアント側で HTML エスケープしてはいけない。**
String encodeFormValue(String value) {
  final out = StringBuffer();
  // UTF-16 code unit ではなく runes で回す。サロゲートペア (絵文字など) が
  // 半分ずつ処理されて壊れるのを防ぐため。
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);

    if (_unreserved.hasMatch(ch)) {
      out.write(ch);
      continue;
    }
    if (ch == ' ') {
      out.write('+');
      continue;
    }
    if (ch == '\n') {
      out.write('%0D%0A');
      continue;
    }
    if (ch == '\r') {
      continue; // \r\n は上の \n 側で CRLF として出力済み
    }

    final bytes = _strict.encode(ch);
    if (_isReplacedWithQuestionMark(bytes, ch)) {
      // 表現不能 -> 数値文字参照。digits は unreserved なので素通しできる。
      // サーバは ASCII を指す数値文字参照を無効化する (XSS 対策) が、
      // ASCII は必ず CP932 で表現できるためここに来ることはない。
      out.write('%26%23$rune%3B');
      continue;
    }
    for (final b in bytes) {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// bbs.cgi のリクエストボディを組み立てる。
///
/// キーの順序は渡された [fields] の順序を保つ。
String encodeFormBody(Map<String, String> fields) => fields.entries
    .map((e) => '${encodeFormValue(e.key)}=${encodeFormValue(e.value)}')
    .join('&');
