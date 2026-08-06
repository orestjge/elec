/// dat に入っている HTML を、そのまま効かせて表示するための span 化。
///
/// dat の各項目は「ブラウザに流し込めばそう見える」HTML として書かれている。
/// `<br>` の改行、ワッチョイの `</b>…<b>`、`>>1` や URL の `<a href=…>`、
/// `&gt;` のような実体参照——これらは掲示板を素のブラウザで見たときの見た目を
/// 作るためのもので、マークアップが文字として並ぶのが正しい姿ではない。
///
/// 「レスを生のまま見る」はアプリの整形（サムネイル・OGP カード・AA フォント）を
/// 通さずに見るための窓なので、**アプリの解釈は挟まないが、掲示板そのものの
/// 見え方には合わせる**。ここはその変換だけを担う。
library;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

/// 開き/閉じタグ 1 個。`<>`（項目の区切り）はタグ名が無いので当たらない。
final _tagRe = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>');

/// [html] を、タグを効かせた span 列にする。
///
/// 効かせるのは dat に実際に現れるものだけ。知らないタグは落とす（効かせられない
/// ものをマークアップのまま出すと、それだけが浮いて読みにくいため）。閉じ忘れや
/// 入れ子の乱れがあっても崩れないよう、種類ごとの数で持つ。
///
/// **[html] は項目 1 つぶんを渡すこと。** dat の項目は CGI がそれぞれ別に組み立て
/// るので、装飾は項目をまたがない。名前欄の末尾に閉じられない `<b>` が来る
/// （ワッチョイの `名無し</b>(L20 xxxx)<b>`）のがその典型で、行ごと渡すと本文まで
/// 太字になってしまう。
List<InlineSpan> datHtmlSpans(String html, {required Color linkColor}) {
  final spans = <InlineSpan>[];
  var bold = 0;
  var italic = 0;
  var underline = 0;
  var strike = 0;
  var link = 0;

  TextStyle? styleNow() {
    final decorations = <TextDecoration>[
      if (underline > 0 || link > 0) TextDecoration.underline,
      if (strike > 0) TextDecoration.lineThrough,
    ];
    if (bold == 0 && italic == 0 && link == 0 && decorations.isEmpty) {
      return null;
    }
    return TextStyle(
      fontWeight: bold > 0 ? FontWeight.bold : null,
      fontStyle: italic > 0 ? FontStyle.italic : null,
      color: link > 0 ? linkColor : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      decorationColor: link > 0 ? linkColor : null,
    );
  }

  void addText(String raw) {
    if (raw.isEmpty) return;
    spans.add(TextSpan(text: decodeEntities(raw), style: styleNow()));
  }

  /// 閉じタグが開きより多くても 0 で止める。dat には対応の取れない閉じタグが
  /// 普通に入っている（ワッチョイの先頭の `</b>`）。
  int step(int depth, bool closing) =>
      closing ? (depth > 0 ? depth - 1 : 0) : depth + 1;

  var last = 0;
  for (final m in _tagRe.allMatches(html)) {
    addText(html.substring(last, m.start));
    last = m.end;
    final closing = m.group(1)!.isNotEmpty;
    switch (m.group(2)!.toLowerCase()) {
      case 'br' || 'hr':
        if (!closing) spans.add(const TextSpan(text: '\n'));
      case 'b' || 'strong':
        bold = step(bold, closing);
      case 'i' || 'em':
        italic = step(italic, closing);
      case 'u':
        underline = step(underline, closing);
      case 's' || 'strike' || 'del':
        strike = step(strike, closing);
      case 'a':
        link = step(link, closing);
    }
  }
  addText(html.substring(last));
  return spans;
}
