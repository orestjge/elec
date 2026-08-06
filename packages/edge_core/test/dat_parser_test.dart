import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();

/// dat 1 行を SJIS バイト列にして返すヘルパ（末尾 LF 付き）。
/// 本番コードではなくフィクスチャ生成用。
List<int> datLine(String s) => [..._win31j.encode(s), 0x0A];
List<int> eucDatLine(String s) => [...EucJpCodec().encode(s), 0x0A];

void main() {
  group('parseDatLine — 通常レス', () {
    test('名前・日付・ID・本文・タイトルを分解する', () {
      final res = parseDatLine(
        '名無し<>sage<>2025/11/03(月) 02:14:51.907 ID:abcXYZ<> 本文だよ <>スレタイ',
        1,
      );
      expect(res.number, 1);
      expect(res.name, '名無し');
      expect(res.mail, 'sage');
      expect(res.dateText, '2025/11/03(月) 02:14:51.907');
      expect(res.id, 'abcXYZ');
      expect(res.beId, isNull);
      expect(res.body, '本文だよ'); // 前後スペース除去
      expect(res.threadTitle, 'スレタイ');
      expect(res.kind, ResKind.normal);
      // 分解する前の日付欄も残す。日付と ID の間隔は分解後の値から復元できず、
      // 掲示板の `投稿日:…` 表記はこの欄をそのまま置いたものなので取っておく。
      expect(res.rawDateField, '2025/11/03(月) 02:14:51.907 ID:abcXYZ');
    });

    test('BE 付きでも日付欄をひと続きのまま残す', () {
      final res = parseDatLine(
        '名無し<><>2025/11/03(月) 02:14:51.907 ID:abcXYZ BE:123-abcd<> 本文 <>',
        1,
      );
      expect(res.id, 'abcXYZ');
      expect(res.beId, '123-abcd');
      expect(
        res.rawDateField,
        '2025/11/03(月) 02:14:51.907 ID:abcXYZ BE:123-abcd',
      );
    });

    test('本文自身の前後空白は 1 文字だけ剥がす', () {
      // dat 上は `<>  x  <>`。規約スペース 1 つ分だけ剥がし、残りは本文。
      final res = parseDatLine('n<><>d ID:i<>  x  <>', 1);
      expect(res.body, ' x '); // 内側の空白は保持
    });

    test('BE: を拾う（5ch 互換）', () {
      final res = parseDatLine(
        'n<><>2025/11/03(月) 02:14:51.907 ID:aaa BE:123-abcd<> b <>',
        1,
      );
      expect(res.id, 'aaa');
      expect(res.beId, '123-abcd');
    });

    test('日付を JST として UTC 瞬間に変換する', () {
      final res = parseDatLine(
        'n<><>2025/11/03(月) 02:14:51.907 ID:x<> b <>',
        1,
      );
      // JST 02:14:51.907 -> UTC 前日 17:14:51.907
      expect(res.dateTime, DateTime.utc(2025, 11, 2, 17, 14, 51, 907));
    });

    test('本文の <br> や HTML は加工しない（表示層の責務）', () {
      final res = parseDatLine('n<><>d ID:i<> a<br>b&amp;c <>', 1);
      expect(res.body, 'a<br>b&amp;c');
    });
  });

  group('parseDatLine — 特殊レス', () {
    test('あぼーん', () {
      final res = parseDatLine('あぼーん<>あぼーん<><> あぼーん <>スレタイ', 5);
      expect(res.kind, ResKind.abone);
      expect(res.isAbone, isTrue);
      expect(res.id, isNull);
      expect(res.dateText, isEmpty);
      expect(res.body, 'あぼーん');
      expect(res.threadTitle, 'スレタイ');
    });

    test('1001（1000 超え）', () {
      final res = parseDatLine(
        '1001<><>Over 1000 Thread<>このスレッドは1000を超えました。<>',
        1001,
      );
      expect(res.kind, ResKind.over1000);
      expect(res.id, isNull);
      expect(res.body, 'このスレッドは1000を超えました。');
    });
  });

  group('parseDat — バイト列全体', () {
    test('番号を 1 から順に振る', () {
      final bytes = [
        ...datLine('a<><>d ID:1<> x <>t'),
        ...datLine('b<><>d ID:2<> y <>'),
      ];
      final res = parseDat(bytes);
      expect(res.map((r) => r.number), [1, 2]);
      expect(res[0].threadTitle, 't');
      expect(res[1].threadTitle, isNull);
    });

    test('startNumber で途中から番号を振れる（差分取得用）', () {
      final res = parseDat(datLine('a<><>d ID:1<> x <>'), startNumber: 51);
      expect(res.single.number, 51);
    });

    test('マルチバイト境界で切れた末尾は無視する', () {
      final full = datLine('あいうえお<><>d ID:1<> body <>');
      // 最後の 1 バイトを削る = 不完全な行
      final truncated = full.sublist(0, full.length - 1);
      expect(parseDat(truncated), isEmpty);
    });

    test('したらばの EUC-JP dat をパースする', () {
      // 実物（rawmode.cgi）の並び: 番号<>名前<>メール<>日付<>本文<>スレタイ<>ID
      final res = parseDat(
        eucDatLine(
          '1<>名無しの紋さん<>sage<>2024/09/02(月) 04:37:47<>'
          '避難所に次スレを立てました<br>元スレ<>日本語スレ<>',
        ),
        encoding: BbsTextEncoding.eucJp,
        format: DatFormat.shitaraba,
      );
      expect(res.single.number, 1);
      expect(res.single.name, '名無しの紋さん');
      expect(res.single.mail, 'sage');
      expect(res.single.dateText, '2024/09/02(月) 04:37:47');
      expect(res.single.body, '避難所に次スレを立てました<br>元スレ');
      expect(res.single.threadTitle, '日本語スレ');
      expect(res.single.id, isNull); // ID 非表示の板は最終フィールドが空
    });

    test('したらばのレス番号は行位置ではなく行頭の値を使う', () {
      // 削除されたレスは行ごと落ちるので、連番を振ると以降が全部ずれる。
      final res = parseDat(
        [
          ...eucDatLine('690<>名無し<>sage<>2026/01/16(金) 21:07:04<>あ<><>'),
          ...eucDatLine('692<>名無し<><>2026/01/23(金) 22:26:39<>い<><>ID:xyz'),
        ],
        encoding: BbsTextEncoding.eucJp,
        format: DatFormat.shitaraba,
      );
      expect(res.map((r) => r.number), [690, 692]);
      expect(res[1].id, 'xyz'); // `ID:` 接頭辞は剥がす
      expect(res[0].dateTime, DateTime.utc(2026, 1, 16, 12, 7, 4));
    });
  });

  group('実データ（experiment 板の dat）', () {
    late List<int> bytes;
    setUpAll(() {
      bytes = File('test/fixtures/experiment_sample.dat').readAsBytesSync();
    });

    test('4 レスを取得する', () {
      final res = parseDat(bytes);
      expect(res, hasLength(4));
    });

    test('1 レス目: metadent 付き名前・タイトル・本文', () {
      final r = parseDat(bytes).first;
      // 名前は HTML 未加工。metadent が </b>(L20 ...)<b> として残る。
      expect(r.name, startsWith('ポッドの名無し'));
      expect(r.name, contains('</b>(L20'));
      expect(r.id, '0.fNwf8r5');
      expect(r.threadTitle, 'ワッチョイレベル確認★1000');
      expect(r.dateText, '2025/11/03(月) 02:14:51.907');
      expect(r.body, startsWith('!metadent:vvv - configured'));
      expect(r.body, contains('<br>')); // 本文の改行は <br> のまま
    });

    test('2 レス目: 短い本文の前後スペースが剥がれている', () {
      final r = parseDat(bytes)[1];
      expect(r.body, 'test');
      expect(r.number, 2);
    });

    test('全レスの ID が取れている', () {
      for (final r in parseDat(bytes)) {
        expect(r.id, isNotNull, reason: 'res ${r.number}');
      }
    });
  });
}
