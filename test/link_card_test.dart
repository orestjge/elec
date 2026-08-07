import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/link_preview.dart';
import 'package:elec/src/net/thread_link.dart';
import 'package:elec/src/ui/link_card.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

/// OGP を返すだけのフェイク。中身は 1 種類でよい。
class _FakeResponse extends Stream<List<int>> implements io.HttpClientResponse {
  _FakeResponse(this.body);
  final List<int> body;

  @override
  int get statusCode => 200;

  @override
  io.HttpHeaders get headers => _FakeHeaders();

  @override
  List<io.RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements io.HttpHeaders {
  @override
  io.ContentType? get contentType =>
      io.ContentType.parse('text/html; charset=utf-8');

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements io.HttpClientRequest {
  _FakeRequest(this._response);
  final _FakeResponse _response;

  @override
  io.HttpHeaders get headers => _FakeHeaders();

  @override
  Future<io.HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements io.HttpClient {
  _FakeClient(this._body);
  final List<int> _body;

  /// 取りに行った回数。設定を切っているときに 0 であることを見る。
  int requests = 0;

  @override
  Future<io.HttpClientRequest> getUrl(Uri url) async {
    requests += 1;
    return _FakeRequest(_FakeResponse(_body));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// スレの dat を返すフェイク。1 レス目だけあれば足りる。
class _FakeDatFetcher implements HttpFetcher {
  _FakeDatFetcher(this._byUrl);
  final Map<String, FetchResponse> _byUrl;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async =>
      _byUrl[url.toString()] ??
      const FetchResponse(statusCode: 404, bodyBytes: []);
}

FetchResponse _datResp(String line) => FetchResponse(
  statusCode: 200,
  bodyBytes: [...Windows31JCodec().encode('$line\n')],
);

const _opLine =
    '名無し<><>2025/11/03(月) 02:14:51.907 ID:abc<> 1 レス目の本文 <>'
    '貼られたスレのタイトル';

Res post(String body) => Res(
  number: 1,
  name: '名無し',
  mail: '',
  dateText: '2025/11/03(月) 02:14:51.907',
  dateTime: null,
  id: 'aaa',
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

void main() {
  const page =
      '<!DOCTYPE html><html><head>'
      '<meta property="og:site_name" content="例のサイト">'
      '<meta property="og:title" content="記事の見出し">'
      '<meta property="og:description" content="記事の要約">'
      '</head><body></body></html>';

  late _FakeClient client;

  setUp(() {
    LinkPreviews.clearCache();
    client = _FakeClient(utf8.encode(page));
    LinkPreviews.debugClient = client;
  });
  tearDown(() {
    LinkPreviews.debugClient = null;
    LinkPreviews.clearCache();
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('取れるまでは URL、取れたらカードに差し替える', (tester) async {
    await tester.pumpWidget(
      wrap(
        LinkCard(
          url: Uri.parse('https://example.com/a.html'),
          raw: 'https://example.com/a.html',
          onTap: (_) {},
        ),
      ),
    );

    // 待っている間は今までどおり URL が出ている。
    expect(find.text('https://example.com/a.html'), findsOneWidget);

    await tester.pumpAndSettle();

    // 取れたらカードになり、URL の文字列は畳まれる。
    expect(find.text('例のサイト'), findsOneWidget);
    expect(find.text('記事の見出し'), findsOneWidget);
    expect(find.text('記事の要約'), findsOneWidget);
    expect(find.text('https://example.com/a.html'), findsNothing);
  });

  testWidgets('カードにできなければ URL のまま', (tester) async {
    LinkPreviews.debugClient = _FakeClient(
      utf8.encode('<html><head></head><body>OGP なし</body></html>'),
    );

    await tester.pumpWidget(
      wrap(
        LinkCard(
          url: Uri.parse('https://example.com/a.html'),
          raw: 'https://example.com/a.html',
          onTap: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('https://example.com/a.html'), findsOneWidget);
  });

  testWidgets('カードをタップするとその URL が返る', (tester) async {
    final tapped = <Uri>[];
    await tester.pumpWidget(
      wrap(
        LinkCard(
          url: Uri.parse('https://example.com/a.html'),
          raw: 'https://example.com/a.html',
          onTap: tapped.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('記事の見出し'));
    expect(tapped, [Uri.parse('https://example.com/a.html')]);
  });

  testWidgets('切っていればリンク先へ取りに行かない', (tester) async {
    await tester.pumpWidget(
      wrap(
        LinkCard(
          url: Uri.parse('https://example.com/a.html'),
          raw: 'https://example.com/a.html',
          onTap: (_) {},
          enabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.requests, 0);
    expect(find.text('https://example.com/a.html'), findsOneWidget);
  });

  testWidgets('レスの中でも、行を単独で占める URL がカードになる', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: post('これ読んで<br>https://example.com/a.html'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
          linkPreviews: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('これ読んで', findRichText: true), findsOneWidget);
    expect(find.text('記事の見出し'), findsOneWidget);
  });

  testWidgets('設定を渡さないレスでは取りに行かない', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostItem(
          res: post('これ読んで<br>https://example.com/a.html'),
          idCount: 1,
          idOrdinal: 1,
          onTapId: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.requests, 0);
    expect(find.byType(LinkCard), findsNothing);
    expect(
      find.textContaining('https://example.com/a.html', findRichText: true),
      findsOneWidget,
    );
  });

  group('スレのカード', () {
    const url = 'https://bbs.eddibb.cc/liveedge/1700000000';
    const dat = 'https://bbs.eddibb.cc/liveedge/dat/1700000000.dat';
    const kako =
        'https://bbs.eddibb.cc/liveedge/kako/1700/17000/1700000000.dat';

    void install(Map<String, FetchResponse> byUrl) {
      ThreadLinks.debugFetcher = _FakeDatFetcher(byUrl);
      ThreadLinks.boards = () => const [Board.eddibb];
    }

    setUp(() {
      ThreadLinks.clearCache();
      install({dat: _datResp(_opLine)});
    });
    tearDown(() {
      ThreadLinks.debugFetcher = null;
      ThreadLinks.boards = () => const [];
      ThreadLinks.clearCache();
    });

    testWidgets('スレ URL は板名とスレタイのカードになる', (tester) async {
      await tester.pumpWidget(
        wrap(LinkCard(url: Uri.parse(url), raw: url, onTap: (_) {})),
      );
      await tester.pumpAndSettle();

      expect(find.text('エッヂ'), findsOneWidget);
      expect(find.text('貼られたスレのタイトル'), findsOneWidget);
      expect(find.text('1 レス目の本文'), findsOneWidget);
      expect(find.text(url), findsNothing);
      // スレタイは dat から取るので、リンク先の HTML は読まない。
      expect(client.requests, 0);
    });

    testWidgets('dat落ちなら札を添える', (tester) async {
      install({kako: _datResp(_opLine)});

      await tester.pumpWidget(
        wrap(LinkCard(url: Uri.parse(url), raw: url, onTap: (_) {})),
      );
      await tester.pumpAndSettle();

      expect(find.text('貼られたスレのタイトル'), findsOneWidget);
      expect(find.text('dat落ち'), findsOneWidget);
    });

    testWidgets('スレが見つからなければ URL のまま', (tester) async {
      install(const {});

      await tester.pumpWidget(
        wrap(LinkCard(url: Uri.parse(url), raw: url, onTap: (_) {})),
      );
      await tester.pumpAndSettle();

      expect(find.text(url), findsOneWidget);
    });

    testWidgets('OGP を切っていてもスレのカードは出る', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostItem(
            res: post('このスレ見て<br>$url'),
            idCount: 1,
            idOrdinal: 1,
            onTapId: (_) {},
            // 設定で OGP を切っている状態。
            linkPreviews: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('貼られたスレのタイトル'), findsOneWidget);
      expect(client.requests, 0);
    });

    testWidgets('カードをタップするとその URL が返る', (tester) async {
      final tapped = <Uri>[];
      await tester.pumpWidget(
        wrap(LinkCard(url: Uri.parse(url), raw: url, onTap: tapped.add)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('貼られたスレのタイトル'));
      expect(tapped, [Uri.parse(url)]);
    });
  });
}
