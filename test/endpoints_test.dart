import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('必死チェッカーの URL は k にレスの ID をそのまま渡す', () {
    const endpoints = EdgeEndpoints();
    final url = endpoints.hissi('bdwCNFndK');
    expect(url.host, 'www.kyodemo.net');
    expect(url.path, '/sdemo/b/e_e_liveedge/');
    expect(url.queryParameters['bs'], 'hi');
    expect(url.queryParameters['k'], 'bdwCNFndK');
  });

  group('書き込み先（bbs.cgi）', () {
    test('eddist はそのままの host・guid なし', () {
      const e = EdgeEndpoints(); // 既定＝エッヂ
      expect(e.bbsCgi.host, 'bbs.eddibb.cc');
      expect(e.bbsCgi.path, '/test/bbs.cgi');
      expect(e.bbsCgi.queryParameters.containsKey('guid'), isFalse);
    });

    test('5ch は板 host（.io）に guid=ON を付ける', () {
      final e = EdgeEndpoints.forBoard(
        const Board(
          host: 'nova.5ch.io',
          boardKey: 'livegalileo',
          title: 'x',
          kind: BoardKind.fivech,
        ),
      );
      expect(e.bbsCgi.host, 'nova.5ch.io');
      expect(e.bbsCgi.path, '/test/bbs.cgi');
      expect(e.bbsCgi.queryParameters['guid'], 'ON');
    });

    test('5ch の Referer は read.cgi スレ URL（末尾スラッシュ無し）', () {
      final e = EdgeEndpoints.forBoard(
        const Board(
          host: 'nova.5ch.io',
          boardKey: 'livegalileo',
          title: 'x',
          kind: BoardKind.fivech,
        ),
      );
      expect(
        e.writeReferer(threadKey: '1700000000'),
        'https://nova.5ch.io/test/read.cgi/livegalileo/1700000000',
      );
      expect(e.writeReferer(), 'https://nova.5ch.io/livegalileo/');
    });

    test('5ch は Monazilla の User-Agent、eddist は null', () {
      final fivech = EdgeEndpoints.forBoard(
        const Board(
          host: 'nova.5ch.io',
          boardKey: 'livegalileo',
          title: 'x',
          kind: BoardKind.fivech,
        ),
      );
      expect(fivech.writeUserAgent, startsWith('Monazilla/'));
      const e = EdgeEndpoints();
      expect(e.writeUserAgent, isNull);
      expect(e.writeReferer(threadKey: '1'), isNull);
    });
  });
}
