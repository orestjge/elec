import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();
List<int> sjis(String s) => _win31j.encode(s);
List<int> eucJp(String s) => EucJpCodec().encode(s);

class FakeFetcher implements HttpFetcher {
  FakeFetcher(this._responses);
  final List<FetchResponse> _responses;
  final List<Map<String, String>> requests = [];
  int _i = 0;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(headers);
    return _responses[_i++];
  }
}

void main() {
  final url = Uri.parse('https://x/liveedge/subject.txt');

  test('初回は If-Modified-Since を付けず全取得する', () async {
    final f = FakeFetcher([
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis('1.dat<>あ (10)\n2.dat<>い (20)\n'),
        headers: {'last-modified': 'LM1'},
      ),
    ]);
    final r = await SubjectFetcher(f).fetch(url);

    expect(r.notModified, isFalse);
    expect(r.state.threads, hasLength(2));
    expect(r.state.lastModified, 'LM1');
    expect(f.requests.single.containsKey('If-Modified-Since'), isFalse);
  });

  test('2 回目は If-Modified-Since を送り、304 なら前回を保つ', () async {
    final f = FakeFetcher([
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis('1.dat<>あ (10)\n'),
        headers: {'last-modified': 'LM1'},
      ),
      const FetchResponse(statusCode: 304, bodyBytes: []),
    ]);
    final fetcher = SubjectFetcher(f);
    final first = await fetcher.fetch(url);
    final second = await fetcher.fetch(url, prev: first.state);

    expect(second.notModified, isTrue);
    expect(identical(second.state, first.state), isTrue);
    expect(f.requests[1]['If-Modified-Since'], 'LM1');
  });

  test('変化があれば 200 で更新する', () async {
    final f = FakeFetcher([
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis('1.dat<>あ (10)\n'),
        headers: {'last-modified': 'LM1'},
      ),
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis('1.dat<>あ (12)\n2.dat<>い (3)\n'),
        headers: {'last-modified': 'LM2'},
      ),
    ]);
    final fetcher = SubjectFetcher(f);
    final first = await fetcher.fetch(url);
    final second = await fetcher.fetch(url, prev: first.state);

    expect(second.notModified, isFalse);
    expect(second.state.threads, hasLength(2));
    expect(second.state.threads.first.resCount, 12);
    expect(second.state.lastModified, 'LM2');
  });

  test('308 リダイレクト（.net→.io）を透過追従する', () async {
    final f = FakeFetcher([
      FetchResponse(
        statusCode: 308,
        bodyBytes: const [],
        headers: {'location': 'https://mi.5ch.io/news4vip/subject.txt'},
      ),
      FetchResponse(
        statusCode: 200,
        bodyBytes: sjis('1.dat<>あ (10)\n'),
        headers: {'last-modified': 'LM1'},
      ),
    ]);
    final r = await SubjectFetcher(
      f,
    ).fetch(Uri.parse('https://mi.5ch.net/news4vip/subject.txt'));

    expect(r.notModified, isFalse);
    expect(r.state.threads, hasLength(1));
    expect(r.state.lastModified, 'LM1');
  });

  test('200 以外・304 以外は例外', () async {
    final f = FakeFetcher([
      const FetchResponse(statusCode: 500, bodyBytes: []),
    ]);
    expect(
      () => SubjectFetcher(f).fetch(url),
      throwsA(isA<HttpFetchException>()),
    );
  });

  test('EUC-JP subject を取得してパースする', () async {
    final f = FakeFetcher([
      FetchResponse(
        statusCode: 200,
        bodyBytes: eucJp('1700000000.cgi,日本語スレ(10)\n'),
      ),
    ]);
    final r = await SubjectFetcher(
      f,
      encoding: BbsTextEncoding.eucJp,
    ).fetch(url);

    expect(r.state.threads.single.title, '日本語スレ');
    expect(r.state.threads.single.resCount, 10);
  });
}
