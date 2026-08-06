import 'package:elec/src/ui/dat_html.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _link = Color(0xFF0000FF);

List<InlineSpan> spans(String html) => datHtmlSpans(html, linkColor: _link);

/// 効かせた後に見える文字。
String plain(String html) => TextSpan(children: spans(html)).toPlainText();

/// [text] を含む span に当たっているスタイル。
TextStyle? styleOf(String html, String text) {
  for (final span in spans(html)) {
    if (span is TextSpan && span.text == text) return span.style;
  }
  throw StateError('span "$text" was not found');
}

void main() {
  test('<br> は改行になる', () {
    expect(plain('これ見て<br>つづき'), 'これ見て\nつづき');
    expect(plain('a<BR />b'), 'a\nb');
  });

  test('実体参照は戻す', () {
    expect(plain('&gt;&gt;1 &amp; &quot;引用&quot;'), '>>1 & "引用"');
  });

  test('<b> は太字になり、閉じたら戻る', () {
    expect(styleOf('<b>太い</b>ふつう', '太い')?.fontWeight, FontWeight.bold);
    expect(styleOf('<b>太い</b>ふつう', 'ふつう')?.fontWeight, isNull);
  });

  test('ワッチョイの先頭の </b> は無かったことにする', () {
    // 名前欄は `名無し</b>(L20 xxxx)<b>` の形で届く。開いていない閉じタグに
    // 引きずられて後ろが崩れないこと、タグ自体は文字として残らないこと。
    const name = 'エッヂの名無し</b>(L20 5clL-4hXU)<b>';
    expect(plain(name), 'エッヂの名無し(L20 5clL-4hXU)');
    expect(styleOf(name, 'エッヂの名無し')?.fontWeight, isNull);
  });

  test('<a> は文字だけ残してリンク色にする', () {
    const anchor =
        '<a href="../test/read.cgi/x/1/1" rel="noopener">&gt;&gt;1</a> だね';
    expect(plain(anchor), '>>1 だね');
    final style = styleOf(anchor, '>>1');
    expect(style?.color, _link);
    expect(style?.decoration, TextDecoration.underline);
    expect(styleOf(anchor, ' だね')?.color, isNull);
  });

  test('知らないタグは落とす', () {
    // 効かせられないものをマークアップのまま出すと、そこだけ浮いて読みにくい。
    expect(plain('<span class="x">中身</span>は残す'), '中身は残す');
  });

  test('項目の区切り <> はタグではないのでそのまま残る', () {
    // 呼び出し側は項目ごとに渡すが、万一混ざっても消えないことを見る。
    expect(plain('名無し<><>2025/11/03'), '名無し<><>2025/11/03');
  });
}
