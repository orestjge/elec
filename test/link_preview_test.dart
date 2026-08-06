import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:elec/src/net/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

/// 本文を小分けに流すフェイク応答。どこまで流れたかを [delivered] で見られる。
class _FakeResponse extends Stream<List<int>> implements io.HttpClientResponse {
  _FakeResponse(
    this.body, {
    this.statusCode = 200,
    String contentType = 'text/html; charset=utf-8',
    this.redirects = const [],
  }) : headers = _FakeHeaders(contentType);

  final List<int> body;

  @override
  final int statusCode;

  @override
  final _FakeHeaders headers;

  @override
  final List<io.RedirectInfo> redirects;

  /// 呼び出し側へ実際に渡ったバイト数。上限で切っていれば本文より小さい。
  int delivered = 0;

  /// 1 回の chunk のバイト数。分割して流し、途中解約を再現する。
  static const _chunk = 16 << 10;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < body.length; i += _chunk) {
        final end = (i + _chunk).clamp(0, body.length);
        final chunk = body.sublist(i, end);
        delivered += chunk.length;
        yield chunk;
      }
    }

    return chunks().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements io.HttpHeaders {
  _FakeHeaders(this._contentType);
  final String _contentType;

  @override
  io.ContentType? get contentType => io.ContentType.parse(_contentType);

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements io.HttpClientRequest {
  _FakeRequest(this._response);
  final _FakeResponse _response;

  @override
  final io.HttpHeaders headers = _FakeHeaders('text/html');

  @override
  Future<io.HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements io.HttpClient {
  _FakeClient(this._response);
  final _FakeResponse _response;

  /// 取りに行った回数。キャッシュが効いているかを見る。
  int requests = 0;

  @override
  Future<io.HttpClientRequest> getUrl(Uri url) async {
    requests += 1;
    return _FakeRequest(_response);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRedirect implements io.RedirectInfo {
  _FakeRedirect(this.location);
  @override
  final Uri location;
  @override
  int get statusCode => 301;
  @override
  String get method => 'GET';
}

/// [head] を `<head>` に入れた最小の HTML。
String html(String head) =>
    '<!DOCTYPE html><html><head>$head</head>'
    '<body><p>本文</p></body></html>';

void main() {
  final url = Uri.parse('https://example.com/article/1');

  _FakeClient install(
    List<int> body, {
    int statusCode = 200,
    String contentType = 'text/html; charset=utf-8',
    List<io.RedirectInfo> redirects = const [],
  }) {
    final client = _FakeClient(
      _FakeResponse(
        body,
        statusCode: statusCode,
        contentType: contentType,
        redirects: redirects,
      ),
    );
    LinkPreviews.debugClient = client;
    return client;
  }

  setUp(LinkPreviews.clearCache);
  tearDown(() {
    LinkPreviews.debugClient = null;
    LinkPreviews.clearCache();
  });

  test('og:title / og:description / og:image を読む', () async {
    install(
      utf8.encode(
        html(
          '<meta property="og:site_name" content="例のサイト">'
          '<meta property="og:title" content="記事の見出し">'
          '<meta property="og:description" content="記事の\n要約">'
          '<meta property="og:image" content="https://img.example.com/a.jpg">',
        ),
      ),
    );

    final preview = await LinkPreviews.resolve(url);

    expect(preview!.siteName, '例のサイト');
    expect(preview.title, '記事の見出し');
    // 改行は 1 個の空白に潰してカードの行を無駄にしない。
    expect(preview.description, '記事の 要約');
    expect(preview.imageUrl, Uri.parse('https://img.example.com/a.jpg'));
  });

  test('属性の順序・引用符・実体参照に振り回されない', () async {
    install(utf8.encode(html("<meta content='A &amp; B' property=og:title>")));

    final preview = await LinkPreviews.resolve(url);
    expect(preview!.title, 'A & B');
  });

  test('相対パスの og:image はページ URL で解決する', () async {
    install(
      utf8.encode(
        html(
          '<meta property="og:title" content="見出し">'
          '<meta property="og:image" content="/img/a.jpg">',
        ),
      ),
    );

    final preview = await LinkPreviews.resolve(url);
    expect(preview!.imageUrl, Uri.parse('https://example.com/img/a.jpg'));
  });

  test('og:site_name が無ければホスト名を出す（www. は落とす）', () async {
    install(utf8.encode(html('<title>ただの見出し</title>')));

    final preview = await LinkPreviews.resolve(
      Uri.parse('https://www.example.com/'),
    );
    expect(preview!.siteName, 'example.com');
    // OGP が無ければ <title> で代替する。
    expect(preview.title, 'ただの見出し');
  });

  test('Shift_JIS のページでも見出しが化けない', () async {
    final page = html(
      '<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS">'
      '<meta property="og:title" content="日本語の見出し">',
    );
    install(
      Windows31JCodec().encode(page),
      // charset をヘッダで返さないサイトを想定し、meta から拾わせる。
      contentType: 'text/html',
    );

    final preview = await LinkPreviews.resolve(url);
    expect(preview!.title, '日本語の見出し');
  });

  test('EUC-JP のページでも見出しが化けない', () async {
    final page = html(
      '<meta charset="EUC-JP">'
      '<meta property="og:title" content="日本語の見出し">',
    );
    install(EucJpCodec().encode(page), contentType: 'text/html');

    final preview = await LinkPreviews.resolve(url);
    expect(preview!.title, '日本語の見出し');
  });

  test('リダイレクト先を基準に相対 URL とホスト名を解決する', () async {
    install(
      utf8.encode(
        html(
          '<meta property="og:title" content="見出し">'
          '<meta property="og:image" content="a.jpg">',
        ),
      ),
      redirects: [_FakeRedirect(Uri.parse('https://moved.example.net/x/y'))],
    );

    final preview = await LinkPreviews.resolve(url);
    expect(preview!.url, Uri.parse('https://moved.example.net/x/y'));
    expect(preview.siteName, 'moved.example.net');
    expect(preview.imageUrl, Uri.parse('https://moved.example.net/x/a.jpg'));
  });

  test('見出しも絵も無ければカードを出さない', () async {
    install(utf8.encode(html('<meta name="viewport" content="width=100">')));
    expect(await LinkPreviews.resolve(url), isNull);
  });

  /// 落とし切ったら困る大きさの中身（4MiB 相当）。
  List<int> bigBody() => utf8.encode('あ' * (2 << 20));

  test('200 以外は本文を落とし切らない', () async {
    final client = install(bigBody(), statusCode: 403);

    expect(await LinkPreviews.resolve(url), isNull);
    expect(client._response.delivered, lessThan(64 << 10));
  });

  test('HTML でなければ本文を落とし切らない', () async {
    final client = install(bigBody(), contentType: 'application/pdf');

    expect(await LinkPreviews.resolve(url), isNull);
    expect(client._response.delivered, lessThan(64 << 10));
  });

  test('巨大なページは先頭だけ読んで接続を切る', () async {
    // <head> の後ろに 4MB の本文をぶら下げる。全部読んだら遅いし通信の無駄。
    final page =
        '<!DOCTYPE html><html><head>'
        '<meta property="og:title" content="見出し">'
        '</head><body>${'あ' * (2 << 20)}</body></html>';
    final client = install(utf8.encode(page));

    final preview = await LinkPreviews.resolve(url);

    expect(preview!.title, '見出し');
    expect(client._response.body.length, greaterThan(1 << 20));
    // 128KiB を少し超えたところ（chunk 単位）で切っている。
    expect(client._response.delivered, lessThan(160 << 10));
  });

  test('同じ URL は取り直さない。失敗も覚える', () async {
    final client = install(utf8.encode(html('<title>見出し</title>')));

    await LinkPreviews.resolve(url);
    await LinkPreviews.resolve(url);
    expect(client.requests, 1);

    LinkPreviews.clearCache();
    final failing = install(utf8.encode(html('')), statusCode: 500);
    expect(await LinkPreviews.resolve(url), isNull);
    expect(await LinkPreviews.resolve(url), isNull);
    expect(failing.requests, 1);
  });
}
