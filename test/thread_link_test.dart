import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/thread_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

/// URL ごとに決められた応答を返すフェイク。30x 追従と Range 要求を検証できる
/// よう、URL とヘッダを控える。
class MapFetcher implements HttpFetcher {
  MapFetcher(this._byUrl);
  final Map<String, FetchResponse> _byUrl;
  final List<Uri> requested = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requested.add(url);
    this.headers.add(headers);
    return _byUrl[url.toString()] ??
        const FetchResponse(statusCode: 404, bodyBytes: []);
  }
}

List<int> sjisDat(String line) => [...Windows31JCodec().encode(line), 0x0A];
List<int> eucDat(String line) => [...EucJpCodec().encode(line), 0x0A];

FetchResponse datResp(String line) =>
    FetchResponse(statusCode: 200, bodyBytes: sjisDat(line));

FetchResponse redirect(String location) => FetchResponse(
  statusCode: 302,
  bodyBytes: const [],
  headers: {'location': location},
);

const notFound = FetchResponse(statusCode: 404, bodyBytes: []);

/// 1 レス目の行（5ch 互換）。`name<>mail<>date<>body<>title`。
const opLine =
    '名無し<><>2025/11/03(月) 02:14:51.907 ID:abc<> 本文の<br>一行目 <>'
    'テスト用のスレタイ';

const fivech = Board(
  host: 'mi.5ch.io',
  boardKey: 'news4vip',
  title: 'ニュー速VIP',
);

const shitaraba = Board(
  host: 'jbbs.shitaraba.net',
  boardKey: 'game/12345',
  title: 'したらばの板',
  kind: BoardKind.shitaraba,
);

void main() {
  late MapFetcher fetcher;

  void install(Map<String, FetchResponse> byUrl, {List<Board>? boards}) {
    fetcher = MapFetcher(byUrl);
    ThreadLinks.debugFetcher = fetcher;
    ThreadLinks.boards = () => boards ?? const [Board.eddibb, fivech];
  }

  setUp(() {
    ThreadLinks.clearCache();
    install(const {});
  });

  tearDown(() {
    ThreadLinks.debugFetcher = null;
    ThreadLinks.boards = () => const [];
    ThreadLinks.clearCache();
  });

  ThreadLinkTarget? target(String url) => ThreadLinks.targetOf(Uri.parse(url));

  group('targetOf', () {
    test('知っている板のスレ URL を板に結び付ける', () {
      final found = target('https://bbs.eddibb.cc/liveedge/1700000000');
      expect(found?.board, Board.eddibb);
      expect(found?.threadKey, '1700000000');
    });

    test('read.cgi 形式・レス指定付きも同じスレとして扱う', () {
      final found = target(
        'https://bbs.eddibb.cc/test/read.cgi/liveedge/1700000000/50',
      );
      expect(found?.threadKey, '1700000000');
      expect(found?.ref.resSpec, '50');
    });

    test('5ch は貼られたホストが違っても板キーで結び付ける', () {
      // 板一覧は `.io` で持っているが、本文には `.net` の URL が貼られる。
      final found = target(
        'https://mi.5ch.net/test/read.cgi/news4vip/1700000000/',
      );
      expect(found?.board, fivech);
    });

    test('知らないホスト・知らない板は対象にしない', () {
      expect(target('https://example.com/liveedge/1700000000'), isNull);
      expect(target('https://bbs.eddibb.cc/other/1700000000'), isNull);
    });

    test('スレ URL でなければ対象にしない', () {
      expect(target('https://bbs.eddibb.cc/liveedge/'), isNull);
      expect(target('https://example.com/a.html'), isNull);
    });

    test('板一覧に無い板のスレは対象にしない（通信もしない）', () {
      install(const {}, boards: const []);
      expect(target('https://bbs.eddibb.cc/liveedge/1700000000'), isNull);
      expect(fetcher.requested, isEmpty);
    });
  });

  group('resolve', () {
    test('dat の先頭からスレタイと 1 レス目の冒頭を取る', () async {
      install({
        'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat': datResp(opLine),
      });
      final info = await ThreadLinks.resolve(
        target('https://bbs.eddibb.cc/liveedge/1700000000')!,
      );

      expect(info?.title, 'テスト用のスレタイ');
      // `<br>` は改行に、改行と連続空白は 1 個の空白へ潰す。
      expect(info?.excerpt, '本文の 一行目');
      expect(info?.pastLog, isFalse);
      expect(info?.board, Board.eddibb);
    });

    test('先頭だけを Range で読む', () async {
      install({
        'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat': datResp(opLine),
      });
      await ThreadLinks.resolve(
        target('https://bbs.eddibb.cc/liveedge/1700000000')!,
      );

      expect(fetcher.headers.single['Range'], 'bytes=0-${32 * 1024 - 1}');
    });

    test('過去ログへ飛ばされたら dat落ちとして辿る', () async {
      install({
        'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat': redirect(
          'https://bbs.eddibb.cc/liveedge/kako/1700/17000/1700000000.dat',
        ),
        'https://bbs.eddibb.cc/liveedge/kako/1700/17000/1700000000.dat':
            datResp(opLine),
      });
      final info = await ThreadLinks.resolve(
        target('https://bbs.eddibb.cc/liveedge/1700000000')!,
      );

      expect(info?.title, 'テスト用のスレタイ');
      expect(info?.pastLog, isTrue);
    });

    test('現行 dat が 404 なら過去ログの置き場を直接見る', () async {
      install({
        'https://mi.5ch.io/news4vip/dat/1700000000.dat': notFound,
        'https://mi.5ch.io/news4vip/kako/1700/17000/1700000000.dat': datResp(
          opLine,
        ),
      });
      final info = await ThreadLinks.resolve(
        target('https://mi.5ch.net/test/read.cgi/news4vip/1700000000/')!,
      );

      expect(info?.title, 'テスト用のスレタイ');
      expect(info?.pastLog, isTrue);
      // 板一覧が持つホスト（`.io`）で取りに行く。
      expect(fetcher.requested.first.host, 'mi.5ch.io');
    });

    test('過去ログにも無ければカードを出さない', () async {
      install(const {});
      final info = await ThreadLinks.resolve(
        target('https://bbs.eddibb.cc/liveedge/1700000000')!,
      );

      expect(info, isNull);
      // 現行 dat と過去ログの 2 回で諦める。
      expect(fetcher.requested, hasLength(2));
    });

    test('したらばは rawmode で 1 レス目だけを名指しする', () async {
      install({
        'https://jbbs.shitaraba.net/bbs/rawmode.cgi/game/12345/1700000000/1':
            FetchResponse(
              statusCode: 200,
              bodyBytes: eucDat(
                '1<>名無し<><>2025/11/03(月) 02:14:51<>したらばの本文<>'
                'したらばのスレタイ<>ID:abc',
              ),
            ),
      }, boards: const [shitaraba]);

      final info = await ThreadLinks.resolve(
        target(
          'https://jbbs.shitaraba.net/bbs/read.cgi/game/12345/1700000000/',
        )!,
      );

      expect(info?.title, 'したらばのスレタイ');
      expect(info?.excerpt, 'したらばの本文');
      // rawmode は Range ではなく URL でレス範囲を指定する。
      expect(fetcher.headers.single, isEmpty);
    });

    test('一度取った結果は覚えて取り直さない（失敗も）', () async {
      install({
        'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat': datResp(opLine),
      });
      final ref = target('https://bbs.eddibb.cc/liveedge/1700000000')!;
      await ThreadLinks.resolve(ref);
      await ThreadLinks.resolve(ref);

      expect(fetcher.requested, hasLength(1));
    });

    test('取れたスレタイは待たずに引ける', () async {
      install({
        'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat': datResp(opLine),
      });
      final ref = target('https://bbs.eddibb.cc/liveedge/1700000000')!;
      expect(ThreadLinks.cachedTitle(ref), isNull);

      await ThreadLinks.resolve(ref);

      expect(ThreadLinks.cachedTitle(ref), 'テスト用のスレタイ');
    });
  });
}
