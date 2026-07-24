import 'dart:convert';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/board_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

/// URL ごとに決められた応答を返すフェイク。リダイレクト追従も検証できるよう
/// URL をキーにする。
class MapFetcher implements HttpFetcher {
  MapFetcher(this._byUrl);
  final Map<String, FetchResponse> _byUrl;
  final List<Uri> requested = [];

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requested.add(url);
    return _byUrl[url.toString()] ??
        const FetchResponse(statusCode: 404, bodyBytes: []);
  }
}

/// 本物のスレ一覧に見えるバイト列（`.dat<>` を含む）。
FetchResponse subjectResp() => FetchResponse(
  statusCode: 200,
  bodyBytes: ascii.encode('1700000000.dat<>test thread (5)\n'),
);

/// itest のようなインターフェースの HTML ページ（スレ一覧ではない）。
FetchResponse htmlResp() => FetchResponse(
  statusCode: 200,
  bodyBytes: ascii.encode('<!DOCTYPE html><html><body>interface</body></html>'),
  headers: const {'content-type': 'text/html; charset=UTF-8'},
);

FetchResponse settingResp(String text) =>
    FetchResponse(statusCode: 200, bodyBytes: Windows31JCodec().encode(text));

FetchResponse bbsmenuResp(String boardKey, String host, String boardName) =>
    FetchResponse(
      statusCode: 200,
      bodyBytes: utf8.encode(
        jsonEncode({
          'menu_list': [
            {
              'category_content': [
                {
                  'directory_name': boardKey,
                  'board_name': boardName,
                  'url': 'https://$host/$boardKey/',
                },
              ],
            },
          ],
        }),
      ),
    );

void main() {
  test('初期状態はエッヂ 1 件・選択もエッヂ', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    expect(store.boards, [Board.eddibb]);
    expect(store.current, Board.eddibb);
  });

  test('5ch の URL を追加すると kind=fivech で追加され選択される', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      'https://mi.5ch.net/news4vip/subject.txt': subjectResp(),
      'https://mi.5ch.net/news4vip/SETTING.TXT': settingResp(
        'BBS_TITLE=ニュー速VIP\nBBS_NONAME_NAME=以下、名無し\n',
      ),
    });

    final board = await store.addFromUrl(
      'https://mi.5ch.net/news4vip/',
      fetcher: f,
    );

    expect(board.host, 'mi.5ch.net');
    expect(board.boardKey, 'news4vip');
    expect(board.title, 'ニュー速VIP');
    expect(board.defaultName, '以下、名無し');
    expect(board.kind, BoardKind.fivech);
    expect(store.boards, contains(board));
    expect(store.current, board);
  });

  test('subject.txt の 308 でホストを .io に正規化する', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      'https://mi.5ch.net/news4vip/subject.txt': const FetchResponse(
        statusCode: 308,
        bodyBytes: [],
        headers: {'location': 'https://mi.5ch.io/news4vip/subject.txt'},
      ),
      'https://mi.5ch.io/news4vip/subject.txt': subjectResp(),
      'https://mi.5ch.io/news4vip/SETTING.TXT': settingResp('BBS_TITLE=VIP\n'),
    });

    final board = await store.addFromUrl(
      'https://mi.5ch.net/news4vip/',
      fetcher: f,
    );

    expect(board.host, 'mi.5ch.io');
    expect(board.title, 'VIP');
  });

  test('itest/subback の URL は BBSMENU で実サーバを解決して追加する', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      // インターフェースホストは 200 だが HTML（スレ一覧ではない）→ 弾く。
      'https://itest.5ch.io/livegalileo/subject.txt': htmlResp(),
      // BBSMENU で実サーバ nova.5ch.io を解決。
      'https://menu.5ch.net/bbsmenu.json': bbsmenuResp(
        'livegalileo',
        'nova.5ch.io',
        'なんでも実況G',
      ),
      'https://nova.5ch.io/livegalileo/subject.txt': subjectResp(),
      // SETTING.TXT は 404（既定）→ 板名は BBSMENU の board_name を使う。
    });

    final board = await store.addFromUrl(
      'https://itest.5ch.io/subback/livegalileo',
      fetcher: f,
    );

    expect(board.host, 'nova.5ch.io');
    expect(board.boardKey, 'livegalileo');
    expect(board.title, 'なんでも実況G');
    expect(board.kind, BoardKind.fivech);
  });

  test('エッヂのホストなら kind=eddist', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      'https://bbs.eddibb.cc/experiment/subject.txt': subjectResp(),
      'https://bbs.eddibb.cc/experiment/SETTING.TXT': settingResp(
        'BBS_TITLE=試験板\n',
      ),
    });
    final board = await store.addFromUrl(
      'https://bbs.eddibb.cc/experiment/',
      fetcher: f,
    );
    expect(board.kind, BoardKind.eddist);
    expect(board.title, '試験板');
  });

  test('板の URL でなければ BoardAddException', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    expect(
      () => store.addFromUrl('https://example.com/', fetcher: MapFetcher({})),
      throwsA(isA<BoardAddException>()),
    );
  });

  test('subject.txt が本物でなければ BoardAddException', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    // 非 5ch ホストで HTML が返るだけ → BBSMENU も引かず失敗。
    final f = MapFetcher({'https://example.org/none/subject.txt': htmlResp()});
    expect(
      () => store.addFromUrl('https://example.org/none/', fetcher: f),
      throwsA(isA<BoardAddException>()),
    );
  });

  test('SETTING.TXT が取れなくても boardKey をタイトルに追加できる', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      'https://mi.5ch.net/news4vip/subject.txt': subjectResp(),
      // SETTING.TXT は 404（既定）。5ch ホストなので BBSMENU も引くが未収録。
    });
    final board = await store.addFromUrl(
      'https://mi.5ch.net/news4vip/',
      fetcher: f,
    );
    expect(board.title, 'news4vip');
  });

  test('エッヂは削除できない・他板は削除でき現在板が移る', () async {
    final store = BoardStore(MemoryBoardStorage());
    await store.load();
    final f = MapFetcher({
      'https://mi.5ch.net/news4vip/subject.txt': subjectResp(),
      'https://mi.5ch.net/news4vip/SETTING.TXT': settingResp('BBS_TITLE=VIP\n'),
    });
    final board = await store.addFromUrl(
      'https://mi.5ch.net/news4vip/',
      fetcher: f,
    );
    expect(store.current, board);

    await store.remove(Board.eddibb.id); // 無視される
    expect(store.boards, contains(Board.eddibb));

    await store.remove(board.id);
    expect(store.boards, isNot(contains(board)));
    expect(store.current, Board.eddibb);
  });

  test('永続化した板一覧を再読込できる', () async {
    final storage = MemoryBoardStorage();
    final store = BoardStore(storage);
    await store.load();
    final f = MapFetcher({
      'https://mi.5ch.net/news4vip/subject.txt': subjectResp(),
      'https://mi.5ch.net/news4vip/SETTING.TXT': settingResp('BBS_TITLE=VIP\n'),
    });
    await store.addFromUrl('https://mi.5ch.net/news4vip/', fetcher: f);

    final reloaded = BoardStore(storage);
    await reloaded.load();
    expect(
      reloaded.boards.map((b) => b.id),
      containsAll([Board.eddibb.id, 'mi.5ch.net/news4vip']),
    );
    expect(reloaded.current.id, 'mi.5ch.net/news4vip');
  });
}
