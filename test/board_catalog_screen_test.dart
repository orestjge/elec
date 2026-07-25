import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/board_catalog.dart';
import 'package:elec/src/ui/board_catalog_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Board board(String host, String key) =>
    Board(host: host, boardKey: key, title: key);

void main() {
  test('取得元は 5ch＋板を持っているホストごとに 1 つ', () {
    final sources = BoardCatalogScreen.sourcesFor([
      Board.eddibb,
      board('mi.5ch.net', 'news4vip'),
      board('nova.5ch.io', 'livegalileo'),
      board('bbs.punipuni.eu', 'vaporeon'),
      board('bbs.punipuni.eu', 'leafeon'),
    ]);

    // 5ch は BBSMENU が全サーバを網羅するので個別ホストは並べない。
    // 同じサーバの複数板もタブは 1 つ。
    expect(sources.map((s) => s.label), ['5ch', 'エッヂ', 'bbs.punipuni.eu']);
    expect(sources.first.kind, BoardCatalogSourceKind.fivechMenu);
    expect(sources[1].host, Board.eddibbHost);
  });
}
