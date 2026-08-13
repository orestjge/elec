import 'package:edge_sjis/edge_sjis.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();

void main() {
  group('decodeSjis', () {
    test('全角カタカナと漢字', () {
      // "スレタイ例 (123)"
      final bytes = [
        0x83, 0x58, 0x83, 0x8c, 0x83, 0x5e, 0x83, 0x43, 0x97, 0xe1, //
        0x20, 0x28, 0x31, 0x32, 0x33, 0x29,
      ];
      expect(decodeSjis(bytes), 'スレタイ例 (123)');
    });

    test('半角カナ', () {
      expect(decodeSjis([0xb6, 0xc0, 0xb6, 0xc5]), 'ｶﾀｶﾅ');
    });

    test('NEC特殊文字 (丸数字)', () {
      expect(decodeSjis([0x87, 0x40]), '①');
    });

    test('0x8160 は U+FF5E (全角チルダ) になる', () {
      // CP932 の割り当て。JIS X 0208 では U+301C だが、ブラウザ・サーバとも
      // CP932 系なのでこちらが正しい。
      expect(decodeSjis([0x81, 0x60]).runes.first, 0xFF5E);
    });

    test('破損バイトでスレ全体を落とさない', () {
      // 末尾が lead byte だけで切れている
      final broken = [..._win31j.encode('あい'), 0x82];
      expect(() => decodeSjis(broken), returnsNormally);
      expect(decodeSjis(broken), startsWith('あい'));
      expect(
        () => decodeSjis(broken, allowMalformed: false),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('encodeFormValue — edge-sender で実際に書き込みが通った値', () {
    // ../edge-sender の bbs_manager.py が投稿に成功した payload。
    // ここが崩れたら書き込みは通らないと考えてよい。
    test('submit=書き込む', () {
      expect(encodeFormValue('書き込む'), '%8F%91%82%AB%8D%9E%82%DE');
    });

    test('MESSAGE=みんないる', () {
      expect(encodeFormValue('みんないる'), '%82%DD%82%F1%82%C8%82%A2%82%E9');
    });

    test('みんないる〜 — 波ダッシュは数値文字参照になる', () {
      // ブラウザは U+301C を CP932 で表現できず &#12316; として送る。
      // edge-sender の curl にも %26%2312316%3B として現れている。
      expect(
        encodeFormValue('みんないる〜'),
        '%82%DD%82%F1%82%C8%82%A2%82%E9%26%2312316%3B',
      );
    });
  });

  group('encodeFormValue — CP932 の境界', () {
    test('U+FF5E 全角チルダは 0x8160 にエンコードできる', () {
      expect(encodeFormValue('～'), '%81%60');
    });

    test('U+301C 波ダッシュは表現できない', () {
      expect(encodeFormValue('〜'), '%26%2312316%3B');
    });

    test('丸数字は NEC特殊文字として通る', () {
      expect(encodeFormValue('①'), '%87%40');
    });

    test('絵文字は数値文字参照になる (サロゲートペアを壊さない)', () {
      expect(encodeFormValue('🍣'), '%26%23127843%3B');
    });

    test('サロゲートペアの漢字も同様', () {
      expect(encodeFormValue('𠮷'), '%26%23134071%3B');
    });

    test('? そのものは数値文字参照にならない', () {
      // 表現不能の検出に 0x3F を使っているため、本物の ? を誤判定しないこと。
      expect(encodeFormValue('?'), '%3F');
    });
  });

  group('encodeFormValue — フォームの規約', () {
    test('unreserved は素通し', () {
      expect(encodeFormValue('abcXYZ019-_.*~'), 'abcXYZ019-_.*~');
    });

    test('半角スペースは +', () {
      expect(encodeFormValue('a b'), 'a+b');
    });

    test('改行は CRLF', () {
      // サーバが \r を削除し \n を <br> に変換する。
      expect(encodeFormValue('a\nb'), 'a%0D%0Ab');
      expect(encodeFormValue('a\r\nb'), 'a%0D%0Ab');
    });

    test('HTML エスケープはしない (サーバ側の責務)', () {
      expect(encodeFormValue('<b>'), '%3Cb%3E');
    });
  });

  group('encodeFormBody', () {
    test('bbs.cgi のボディを組み立てる', () {
      final body = encodeFormBody({
        'submit': '書き込む',
        'mail': '',
        'FROM': '',
        'MESSAGE': 'みんないる',
        'bbs': 'liveedge',
        'key': '1749045135',
      });
      expect(
        body,
        'submit=%8F%91%82%AB%8D%9E%82%DE&mail=&FROM=&'
        'MESSAGE=%82%DD%82%F1%82%C8%82%A2%82%E9&bbs=liveedge&key=1749045135',
      );
    });
  });

  group('splitDatLines — Range 差分取得', () {
    List<int> datLine(String s) => [..._win31j.encode(s), 0x0A];

    test('完全な行だけを返し、不完全な末尾は捨てる', () {
      final partial = _win31j.encode('名無し<><>2026/07/17 ID:ghi<>かきく');
      final dat = [
        ...datLine('名無し<>sage<>2026/07/17 ID:abc<>あいうえお<>スレタイ'),
        ...datLine('名無し<><>2026/07/17 ID:def<>①～②<>'),
        // 3行目はマルチバイト文字の途中で切れている
        ...partial.sublist(0, partial.length - 1),
      ];

      final lines = splitDatLines(dat);
      expect(lines, hasLength(2));
      expect(decodeSjis(lines[0]).split('<>')[3], 'あいうえお');
      expect(decodeSjis(lines[1]).split('<>')[3], '①～②');
    });

    test('マルチバイト文字の途中に LF は現れない', () {
      // trail byte は 0x40-0x7E / 0x80-0xFC なので 0x0A にはならない。
      // 全角文字を並べても、LF は行区切りとしてのみ出現する。
      final bytes = _win31j.encode('あいうえお漢字①～');
      expect(bytes.contains(0x0A), isFalse);
      expect(splitDatLines(bytes), isEmpty); // LF が無ければ完全な行は0
    });

    test('空行を保持する', () {
      final dat = [...datLine('a'), 0x0A, ...datLine('b')];
      expect(splitDatLines(dat).map(decodeSjis), ['a', '', 'b']);
    });

    test('差分の追記でバイト列を結合してから分割すれば壊れない', () {
      final full = [...datLine('あいうえお'), ...datLine('かきくけこ')];
      // Range 取得のようにマルチバイト文字の途中で分割する
      final head = full.sublist(0, 5);
      final tail = full.sublist(5);
      expect(splitDatLines([...head, ...tail]).map(decodeSjis), [
        'あいうえお',
        'かきくけこ',
      ]);
    });
  });

  group('isEncodable', () {
    test('CP932 にある文字', () {
      for (final ch in ['あ', '書', '①', '～', 'a', '?', 'ｶ']) {
        expect(isEncodable(ch), isTrue, reason: ch);
      }
    });

    test('CP932 に無い文字', () {
      for (final ch in ['〜', '🍣', '𠮷', '—']) {
        expect(isEncodable(ch), isFalse, reason: ch);
      }
    });
  });

  group('EUC-JP（したらば）', () {
    const eucJp = BbsTextEncoding.eucJp;

    test('漢字・かなを EUC-JP のバイト列でエンコードする', () {
      expect(
        encodeFormValue('書き込む', encoding: eucJp),
        '%BD%F1%A4%AD%B9%FE%A4%E0',
      );
    });

    test('半角カナは 0x8E 付きの 2 バイト', () {
      expect(encodeFormValue('ｶ', encoding: eucJp), '%8E%B6');
    });

    test('フォームの規約は Windows-31J と同じ', () {
      expect(encodeFormValue('a b', encoding: eucJp), 'a+b');
      expect(encodeFormValue('a\r\nb', encoding: eucJp), 'a%0D%0Ab');
      expect(
        encodeFormValue('abcXYZ019-_.*~', encoding: eucJp),
        'abcXYZ019-_.*~',
      );
    });

    test('EUC-JP に無い文字は数値文字参照になる', () {
      expect(encodeFormValue('🍣', encoding: eucJp), '%26%23127843%3B');
      expect(encodeFormValue('𠮷', encoding: eucJp), '%26%23134071%3B');
      // 表現できる・できないの境目は Windows-31J と揃っている（jis0208 が
      // どちらも WHATWG の変換表で引くため）。`〜` U+301C は両方とも無い。
      expect(isEncodable('〜', encoding: eucJp), isFalse);
      expect(isEncodable('～', encoding: eucJp), isTrue);
    });

    test('decodeBbsText は文字コードで読み分ける', () {
      final bytes = EucJpEncoder().convert('あいうえお');
      expect(decodeBbsText(bytes, eucJp), 'あいうえお');
      expect(decodeBbsText(bytes, BbsTextEncoding.sjis), isNot('あいうえお'));
    });
  });
}
