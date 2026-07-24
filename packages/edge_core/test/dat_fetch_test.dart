import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();

List<int> datLine(String s) => [..._win31j.encode(s), 0x0A];

/// 決められた応答を順に返すフェイク。実ネットワーク不要。
class FakeFetcher implements HttpFetcher {
  FakeFetcher(this._responses);
  final List<FetchResponse> _responses;
  final List<Map<String, String>> requests = [];
  final List<Uri> urls = [];
  int _i = 0;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(headers);
    urls.add(url);
    return _responses[_i++];
  }
}

FetchResponse ok(List<int> body, {String? lastModified}) => FetchResponse(
  statusCode: 200,
  bodyBytes: body,
  headers: {if (lastModified != null) 'last-modified': lastModified},
);

FetchResponse partial(List<int> body, {String? lastModified}) => FetchResponse(
  statusCode: 206,
  bodyBytes: body,
  headers: {if (lastModified != null) 'last-modified': lastModified},
);

FetchResponse redirect(String location, {int status = 302}) => FetchResponse(
  statusCode: status,
  bodyBytes: const [],
  headers: {'location': location},
);

void main() {
  final res1 = datLine('名無し<><>d ID:a<> いち <>スレタイ');
  final res2 = datLine('名無し<><>d ID:b<> にい <>');
  final res3 = datLine('名無し<><>d ID:c<> さん <>');

  group('初回取得', () {
    test('全文を取得してパースする', () async {
      final f = FakeFetcher([
        ok([...res1, ...res2], lastModified: 'LM1'),
      ]);
      final r = await DatFetcher(f).fetch(Uri.parse('http://x/dat'));

      expect(r.status, DatFetchStatus.initial);
      expect(r.newRes, hasLength(2));
      expect(r.state.res.first.threadTitle, 'スレタイ');
      expect(r.state.lastModified, 'LM1');
      // 初回は Range を付けない。
      expect(f.requests.single.containsKey('Range'), isFalse);
    });

    test('404 は notFound', () async {
      final f = FakeFetcher([
        const FetchResponse(statusCode: 404, bodyBytes: []),
      ]);
      final r = await DatFetcher(f).fetch(Uri.parse('http://x/dat'));
      expect(r.status, DatFetchStatus.notFound);
    });

    test('dat落ち: 302 で過去ログ(kako)へ辿って取得し pastLog を立てる', () async {
      final f = FakeFetcher([
        redirect('/liveedge/kako/1784/17845/1784559955.dat'),
        ok([...res1, ...res2], lastModified: 'LM1'),
      ]);
      final r = await DatFetcher(f).fetch(
        Uri.parse('https://bbs.eddibb.cc/liveedge/dat/1784559955.dat'),
      );

      expect(r.status, DatFetchStatus.pastLog);
      expect(r.state.pastLog, isTrue);
      expect(r.state.res, hasLength(2));
      expect(r.state.res.first.threadTitle, 'スレタイ');
      // 相対 Location を元 URL に対して解決して取りに行く。
      expect(
        f.urls.last,
        Uri.parse(
          'https://bbs.eddibb.cc/liveedge/kako/1784/17845/1784559955.dat',
        ),
      );
    });

    test('ホスト移設: kako でない 308 は透過追従して現行扱い', () async {
      // 5ch の .net → .io のようなホスト移設。pastLog は立てない。
      final f = FakeFetcher([
        redirect('https://mi.5ch.io/news4vip/dat/1700000000.dat', status: 308),
        ok([...res1, ...res2], lastModified: 'LM1'),
      ]);
      final r = await DatFetcher(f).fetch(
        Uri.parse('https://mi.5ch.net/news4vip/dat/1700000000.dat'),
      );

      expect(r.status, DatFetchStatus.initial);
      expect(r.state.pastLog, isFalse);
      expect(r.state.res, hasLength(2));
      expect(
        f.urls.last,
        Uri.parse('https://mi.5ch.io/news4vip/dat/1700000000.dat'),
      );
    });

    test('dat落ち: 過去ログも 404 なら notFound', () async {
      final f = FakeFetcher([
        redirect('/liveedge/kako/1700/17000/1700000000.dat'),
        const FetchResponse(statusCode: 404, bodyBytes: []),
      ]);
      final r = await DatFetcher(f).fetch(
        Uri.parse('https://bbs.eddibb.cc/liveedge/dat/1700000000.dat'),
      );
      expect(r.status, DatFetchStatus.notFound);
      expect(r.state.pastLog, isFalse);
    });
  });

  group('差分取得', () {
    test('206 で新着を追記する', () async {
      final full = [...res1, ...res2];
      final f = FakeFetcher([
        ok(full, lastModified: 'LM1'),
        // Range: bytes=(N-1)- なので、末尾 1 バイト + 新レス を返す
        partial([full.last, ...res3], lastModified: 'LM2'),
      ]);
      final fetcher = DatFetcher(f);

      final first = await fetcher.fetch(Uri.parse('http://x/dat'));
      final second = await fetcher.fetch(
        Uri.parse('http://x/dat'),
        prev: first.state,
      );

      expect(second.status, DatFetchStatus.appended);
      expect(second.newRes, hasLength(1));
      expect(second.newRes.single.number, 3); // 番号が続く
      expect(second.newRes.single.body, 'さん');
      expect(second.state.res, hasLength(3));

      // 2 回目は Range と If-Modified-Since を送る。
      final req = f.requests[1];
      expect(req['Range'], 'bytes=${full.length - 1}-');
      expect(req['If-Modified-Since'], 'LM1');
    });

    test('304 は変化なし', () async {
      final f = FakeFetcher([
        ok([...res1], lastModified: 'LM1'),
        const FetchResponse(statusCode: 304, bodyBytes: []),
      ]);
      final fetcher = DatFetcher(f);
      final first = await fetcher.fetch(Uri.parse('http://x/dat'));
      final second = await fetcher.fetch(
        Uri.parse('http://x/dat'),
        prev: first.state,
      );

      expect(second.status, DatFetchStatus.notModified);
      expect(second.newRes, isEmpty);
      expect(second.state.res, hasLength(1));
    });

    test('先頭バイト不一致（あぼーん）で全再取得する', () async {
      final full = [...res1, ...res2];
      // res2 があぼーんに置き換わった dat
      final rewritten = [...res1, ...datLine('あぼーん<>あぼーん<><> あぼーん <>')];
      final f = FakeFetcher([
        ok(full, lastModified: 'LM1'),
        // 先頭バイトが保持データ末尾と食い違う（0x00 を先頭に）
        partial([0x00, 0x99], lastModified: 'LM2'),
        // 再取得に対する全文
        ok(rewritten, lastModified: 'LM3'),
      ]);
      final fetcher = DatFetcher(f);
      final first = await fetcher.fetch(Uri.parse('http://x/dat'));
      final second = await fetcher.fetch(
        Uri.parse('http://x/dat'),
        prev: first.state,
      );

      expect(second.status, DatFetchStatus.refetched);
      expect(second.state.res, hasLength(2));
      expect(second.state.res[1].isAbone, isTrue);
      expect(f.requests, hasLength(3)); // Range + 全再取得
    });

    test('新着 0 の 206（末尾バイトのみ）は変化なし', () async {
      final full = [...res1];
      final f = FakeFetcher([
        ok(full, lastModified: 'LM1'),
        partial([full.last], lastModified: 'LM2'), // 追記分なし
      ]);
      final fetcher = DatFetcher(f);
      final first = await fetcher.fetch(Uri.parse('http://x/dat'));
      final second = await fetcher.fetch(
        Uri.parse('http://x/dat'),
        prev: first.state,
      );

      expect(second.status, DatFetchStatus.notModified);
      expect(second.newRes, isEmpty);
    });

    test('200（サーバが Range 無視）は置き換え扱い', () async {
      final f = FakeFetcher([
        ok([...res1], lastModified: 'LM1'),
        ok([...res1, ...res2], lastModified: 'LM2'),
      ]);
      final fetcher = DatFetcher(f);
      final first = await fetcher.fetch(Uri.parse('http://x/dat'));
      final second = await fetcher.fetch(
        Uri.parse('http://x/dat'),
        prev: first.state,
      );

      expect(second.status, DatFetchStatus.refetched);
      expect(second.state.res, hasLength(2));
    });
  });
}
