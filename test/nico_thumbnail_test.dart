import 'dart:convert';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/nico_thumbnail.dart';
import 'package:flutter_test/flutter_test.dart';

/// getthumbinfo の応答を差し込むフェイク。呼ばれた URL を記録する。
class _FakeFetcher implements HttpFetcher {
  _FakeFetcher(this.response);
  final FetchResponse response;
  final List<Uri> requested = [];

  @override
  Future<FetchResponse> get(Uri url, {Map<String, String> headers = const {}}) {
    requested.add(url);
    return Future.value(response);
  }
}

FetchResponse _xml(String body) =>
    FetchResponse(statusCode: 200, bodyBytes: utf8.encode(body));

void main() {
  setUp(NicoThumbnails.clearCache);

  test('getthumbinfo の thumbnail_url を返す', () async {
    NicoThumbnails.fetcher = _FakeFetcher(
      _xml(
        '<nicovideo_thumb_response status="ok"><thumb>'
        '<thumbnail_url>https://nicovideo.cdn.nimg.jp/thumbnails/9/9</thumbnail_url>'
        '</thumb></nicovideo_thumb_response>',
      ),
    );

    final url = await NicoThumbnails.resolve('sm9');
    expect(url, Uri.parse('https://nicovideo.cdn.nimg.jp/thumbnails/9/9'));
  });

  test('正しい getthumbinfo エンドポイントを叩く', () async {
    final fetcher = _FakeFetcher(_xml('<nicovideo_thumb_response/>'));
    NicoThumbnails.fetcher = fetcher;

    await NicoThumbnails.resolve('sm38048362');
    expect(
      fetcher.requested.single,
      Uri.parse('https://ext.nicovideo.jp/api/getthumbinfo/sm38048362'),
    );
  });

  test('thumbnail_url が無ければ null', () async {
    NicoThumbnails.fetcher = _FakeFetcher(
      _xml(
        '<nicovideo_thumb_response status="fail"><error>'
        '<code>DELETED</code></error></nicovideo_thumb_response>',
      ),
    );
    expect(await NicoThumbnails.resolve('sm1'), isNull);
  });

  test('成功結果はキャッシュし、2 回目は再取得しない', () async {
    final fetcher = _FakeFetcher(
      _xml('<thumbnail_url>https://x/y</thumbnail_url>'),
    );
    NicoThumbnails.fetcher = fetcher;

    await NicoThumbnails.resolve('sm9');
    await NicoThumbnails.resolve('sm9');
    expect(fetcher.requested.length, 1);
  });

  test('取れた URL は cached で待たずに引ける', () async {
    NicoThumbnails.fetcher = _FakeFetcher(
      _xml('<thumbnail_url>https://x/y</thumbnail_url>'),
    );

    expect(NicoThumbnails.cached('sm9'), isNull);
    await NicoThumbnails.resolve('sm9');
    // 行を作り直しても無地の再生カードに戻らないのはこれ。
    expect(NicoThumbnails.cached('sm9'), Uri.parse('https://x/y'));
  });

  test('失敗も覚えて、叩き直さない', () async {
    // resolve は build から呼ばれる＝スクロール中は毎フレーム通る。
    final fetcher = _FakeFetcher(
      _xml('<nicovideo_thumb_response status="fail"/>'),
    );
    NicoThumbnails.fetcher = fetcher;

    await NicoThumbnails.resolve('sm1');
    await NicoThumbnails.resolve('sm1');
    await NicoThumbnails.resolve('sm1');
    expect(fetcher.requested.length, 1);
    expect(NicoThumbnails.cached('sm1'), isNull);
  });
}
