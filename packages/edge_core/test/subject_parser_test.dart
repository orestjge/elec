import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();

void main() {
  group('parseSubjectLine', () {
    test('通常行', () {
      final e = parseSubjectLine('1762103691.dat<>スレのタイトル (246)')!;
      expect(e.key, '1762103691');
      expect(e.title, 'スレのタイトル');
      expect(e.resCount, 246);
      expect(e.capName, isNull);
    });

    test('cap 付き行', () {
      final e = parseSubjectLine('1782551213.dat<>テストやで [bo0x/BWQ★] (5)')!;
      expect(e.key, '1782551213');
      expect(e.title, 'テストやで');
      expect(e.capName, 'bo0x/BWQ');
      expect(e.resCount, 5);
      expect(e.metadent, isNull);
    });

    test('metadent モードでは [xxx★] を metadent に入れ cap は空にする', () {
      final e = parseSubjectLine(
        '1784518182.dat<>あるスレ [B3YfDSAP★] (3)',
        metadent: true,
      )!;
      expect(e.key, '1784518182');
      expect(e.title, 'あるスレ');
      expect(e.resCount, 3);
      expect(e.metadent, 'B3YfDSAP');
      expect(e.capName, isNull);
    });

    test('タイトルに丸括弧が含まれても末尾のレス数を取る', () {
      final e = parseSubjectLine('123.dat<>雑談 (part2) スレ (99)')!;
      expect(e.title, '雑談 (part2) スレ');
      expect(e.resCount, 99);
    });

    test('タイトルに空白を含む', () {
      final e = parseSubjectLine('123.dat<>t  (17)')!;
      expect(e.title, 't ');
      expect(e.resCount, 17);
    });

    test('.dat で終わらない左辺は弾く', () {
      expect(parseSubjectLine('notadat<>x (1)'), isNull);
    });

    test('<> が無い行は弾く', () {
      expect(parseSubjectLine('garbage'), isNull);
    });

    test('スレッド作成時刻をキーから導ける', () {
      final e = parseSubjectLine('1762103691.dat<>x (1)')!;
      expect(
        e.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1762103691 * 1000, isUtc: true),
      );
    });
  });

  group('parseSubject — 全体', () {
    test('実データ形式の複数行をパースする', () {
      final raw =
          '1762103691.dat<>ワッチョイレベル確認★1000 [OmMo0.f5★] (246)\n'
          '1782551213.dat<>テストやで [bo0x/BWQ★] (5)\n'
          '1782309706.dat<>t  [7716ddCQ★] (17)\n';
      final list = parseSubject(_win31j.encode(raw));
      expect(list, hasLength(3));
      expect(list[0].capName, 'OmMo0.f5');
      expect(list[0].title, 'ワッチョイレベル確認★1000');
      expect(list[0].resCount, 246);
      expect(list[2].title, 't ');
    });

    test('空行を飛ばす', () {
      final list = parseSubject(
        _win31j.encode('1.dat<>a (1)\n\n2.dat<>b (2)\n'),
      );
      expect(list.map((e) => e.key), ['1', '2']);
    });
  });
}
