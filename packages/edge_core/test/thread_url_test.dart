import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

void main() {
  ThreadRef? parse(String url) => parseThreadUrl(Uri.parse(url));

  group('parseThreadUrl', () {
    test('read.cgi 形式（末尾スラッシュ）', () {
      final r = parse(
        'https://bbs.eddibb.cc/test/read.cgi/liveedge/1784559955/',
      );
      expect(r?.board, 'liveedge');
      expect(r?.threadKey, '1784559955');
      expect(r?.resSpec, isNull);
    });

    test('read.cgi 形式（位置指定つき）', () {
      final r = parse(
        'https://bbs.eddibb.cc/test/read.cgi/liveedge/1784559955/l50',
      );
      expect(r?.board, 'liveedge');
      expect(r?.threadKey, '1784559955');
      expect(r?.resSpec, 'l50');
    });

    test('正規 URL 形式', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/1784559955');
      expect(r?.board, 'liveedge');
      expect(r?.threadKey, '1784559955');
    });

    test('dat 直リンク', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/dat/1784559955.dat');
      expect(r?.board, 'liveedge');
      expect(r?.threadKey, '1784559955');
    });

    test('過去ログ kako dat', () {
      final r = parse(
        'https://bbs.eddibb.cc/liveedge/kako/1784/17845/1784559955.dat',
      );
      expect(r?.board, 'liveedge');
      expect(r?.threadKey, '1784559955');
    });

    test('板一覧 URL はスレではない', () {
      expect(parse('https://bbs.eddibb.cc/liveedge/'), isNull);
      expect(parse('https://bbs.eddibb.cc/liveedge'), isNull);
    });

    test('数字でないスレキーは弾く', () {
      expect(parse('https://bbs.eddibb.cc/liveedge/abcdef'), isNull);
    });

    test('無関係な URL は null', () {
      expect(parse('https://example.com/foo/bar'), isNull);
      expect(parse('https://bbs.eddibb.cc/'), isNull);
      expect(parse('https://bbs.eddibb.cc/auth-code'), isNull);
    });

    test('他板でも解析はする（ホスト・板の照合は呼び出し側）', () {
      final r = parse(
        'https://bbs.eddibb.cc/test/read.cgi/experiment/1700000000/',
      );
      expect(r?.board, 'experiment');
      expect(r?.threadKey, '1700000000');
    });

    test('したらば read.cgi 形式', () {
      final r = parse(
        'https://jbbs.shitaraba.net/bbs/read.cgi/otaku/18550/1700000000/l50',
      );
      expect(r?.board, 'otaku/18550');
      expect(r?.threadKey, '1700000000');
      expect(r?.resSpec, 'l50');
    });

    test('したらば rawmode 形式', () {
      final r = parse(
        'https://jbbs.shitaraba.net/bbs/rawmode.cgi/otaku/18550/1700000000/',
      );
      expect(r?.board, 'otaku/18550');
      expect(r?.threadKey, '1700000000');
    });
  });
}
