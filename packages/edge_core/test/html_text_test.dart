import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

void main() {
  group('decodeEntities', () {
    test('10 進数値参照（絵文字・国旗）', () {
      // 実データのタイトルに現れた形。127471=🇯 127477=🇵 で日本国旗。
      expect(decodeEntities('&#127471;&#127477;'), '🇯🇵');
      expect(decodeEntities('燃やしちゃメッ！&#128545;'), '燃やしちゃメッ！😡');
    });

    test('波ダッシュ', () {
      expect(decodeEntities('年収53万円&#12316;270万円'), '年収53万円〜270万円');
    });

    test('16 進数値参照', () {
      expect(decodeEntities('&#x1F363;'), '🍣');
      expect(decodeEntities('&#X41;'), 'A');
    });

    test('名前付きエンティティ', () {
      expect(decodeEntities('a&amp;b&lt;c&gt;d&quot;e&apos;f'), 'a&b<c>d"e\'f');
    });

    test('&amp; を二重デコードしない', () {
      // &amp;#65; は「&#65;」というリテラルであって A ではない。
      expect(decodeEntities('&amp;#65;'), '&#65;');
    });

    test('不正な参照はそのまま残す', () {
      expect(decodeEntities('&#xZZ;'), '&#xZZ;');
      expect(decodeEntities('&#1114112;'), '&#1114112;'); // > 0x10FFFF
      expect(decodeEntities('&#55296;'), '&#55296;'); // サロゲート D800
    });

    test('参照が無ければそのまま', () {
      expect(decodeEntities('ふつうのタイトル'), 'ふつうのタイトル');
    });
  });

  group('htmlToText', () {
    test('<br> を改行にする', () {
      expect(htmlToText('a<br>b<br/>c<BR />d'), 'a\nb\nc\nd');
    });

    test('タグを除去する（metadent の <b> など）', () {
      expect(htmlToText('名無し</b>(L20 NKP8)<b>'), '名無し(L20 NKP8)');
    });

    test('タグ除去とエンティティデコードを両方行う', () {
      expect(htmlToText('&lt;script&gt;<br>a&amp;b'), '<script>\na&b');
    });

    test('デコードで生じた < をタグとして食わない', () {
      // 先にタグ除去 → 後でデコードなので < は文字として残る。
      expect(htmlToText('x &lt;b&gt; y'), 'x <b> y');
    });
  });
}
