/// dat / subject.txt に含まれる HTML を表示用のプレーンテキストへ変換する。
///
/// パーサ（[parseDat] / [parseSubject]）は名前・本文・タイトルを **HTML 未加工**
/// のまま返す。表示層でこの関数を通して整形する（Slevo の
/// `docs/app/thread-response-list.md` と同じ分離）。
library;

final _brRe = RegExp(r'<br\s*/?>', caseSensitive: false);
final _tagRe = RegExp(r'</?[a-zA-Z][^>]*>');
final _numRefRe = RegExp(r'&#([xX]?)([0-9a-fA-F]+);');

const _namedEntities = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&nbsp;': ' ',
};

/// HTML 数値文字参照と名前付きエンティティをデコードする。
///
/// - `&#127471;` → 🇱（10 進）
/// - `&#x1F363;` → 🍣（16 進）
/// - `&amp; &lt; &gt; &quot; &apos; &nbsp;` を対応文字へ
///
/// タグ（`<br>`、`<b>` 等）はそのまま残す。1 行のタイトル用途を想定。
/// 数値参照を先に処理するので `&amp;` が二重デコードされることはない。
String decodeEntities(String input) {
  var s = input.replaceAllMapped(_numRefRe, (m) {
    final isHex = m.group(1)!.isNotEmpty;
    final code = int.tryParse(m.group(2)!, radix: isHex ? 16 : 10);
    if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
    // サロゲート領域そのものを指す不正な参照は無視。
    if (code >= 0xD800 && code <= 0xDFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
  _namedEntities.forEach((k, v) => s = s.replaceAll(k, v));
  return s;
}

/// HTML を表示用のプレーンテキストにする。本文向け。
///
/// - `<br>` / `<br/>` → 改行
/// - 残りのタグ（`<b>`、`</b>` など）は除去
/// - エンティティをデコード
///
/// タグ除去とエンティティデコードの順序に注意: 先にタグを消してから
/// エンティティを復号する。こうしないと、デコードで生じた `<` を後段の
/// タグ除去が食う事故が起きる。
String htmlToText(String html) {
  var s = html.replaceAll(_brRe, '\n');
  s = s.replaceAll(_tagRe, '');
  return decodeEntities(s);
}
