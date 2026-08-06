/// 本文に貼られたリンク先の OGP を取ってきて、カードの中身にする。
///
/// **端末から直接リンク先を読みに行く。** Twitter や Slack はサーバ側のクローラ
/// （`Twitterbot` など）が投稿時に 1 回だけ取りに行き、解決済みのカードを全読者へ
/// 配る。サイト側も SNS からの流入が欲しいので、それらの UA には応じる。elec は
/// サーバを持たないのでその形は取れず、読む人の端末がそのつど取りに行くことになる。
///
/// つまり次を前提にした「取れたら出す」機能になる。
///  - `elec/0.1` と名乗る（ブラウザ詐称はしない方針）ので、UA で弾くサイトや JS で
///    描くサイトではカードが出ない。出ないのが普通、くらいに思っておく。
///  - リンク先に読者の IP が渡る。画像の自動読み込みで既に起きていることだが、
///    対象が「画像 URL」から**あらゆるリンク**に広がる。だから設定で丸ごと切れる
///    ようにしてある（[ThreadViewSettings.linkPreviews]）。
///
/// 取りに行くときの防御:
///  - 本文は先頭 [_maxBytes] だけ読んで接続を切る。OGP は `<head>` にしか無いのに
///    記事ページの HTML は数 MB あることが珍しくない。
///  - `text/html` 以外は読まない。
///  - 全体に [_timeout] を掛ける。
///  - 同時に走らせるのは [maxConcurrent] 本まで。スレを勢いよくスクロールしても
///    ソケットが一気に開かない。
///  - 結果はプロセス内に覚える。**失敗も覚える**（同じ URL を再描画のたびに
///    叩き直さない）。覚え直したければアプリを開き直す。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;

import 'package:edge_core/edge_core.dart';
import 'package:edge_sjis/edge_sjis.dart';
import 'package:flutter/foundation.dart';
import 'package:jis0208/jis0208.dart';

import 'http_fetcher.dart';

/// カード 1 枚ぶんの中身。
class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.siteName,
    this.title,
    this.description,
    this.imageUrl,
  });

  /// 実際に読めたページ（リダイレクト後）の URL。
  final Uri url;

  /// `og:site_name`。無ければホスト名（`www.` は落とす）。
  final String siteName;

  final String? title;
  final String? description;
  final Uri? imageUrl;

  /// カードとして出す価値があるか。見出しも絵も無いなら URL のままの方がまし。
  bool get isPresentable => title != null || imageUrl != null;
}

/// リンク先の OGP 解決器。UI からは [resolve] を呼ぶだけ。
class LinkPreviews {
  LinkPreviews._();

  /// 読む本文の上限。`<head>` を含むのに十分で、無駄打ちが小さい辺り。
  static const _maxBytes = 128 << 10;

  /// 1 件あたりの制限時間。これを過ぎたら諦めてカードを出さない。
  static const _timeout = Duration(seconds: 8);

  /// 覚えておく件数の上限。長く開きっぱなしでも青天井にしない。
  static const _maxCached = 256;

  /// 同時に走らせる取得の本数。
  static int maxConcurrent = 3;

  /// 通信に使うクライアント。掲示板サーバ向けの [HttpClientFetcher]（IPv6 優先
  /// などの都合を持つ）とは分ける。リンク先は掲示板とは無関係のホストで、
  /// あちらの事情に合わせる理由が無いため。
  static io.HttpClient? _sharedClient;

  static io.HttpClient get _client => _sharedClient ??= io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..maxConnectionsPerHost = 2;

  /// 解決済み（失敗を含む）。Dart の Map は挿入順に並ぶので古いものから捨てられる。
  static final _cache = <String, Future<LinkPreview?>>{};

  /// [url] のカード内容を返す。出せるものが無ければ null。
  static Future<LinkPreview?> resolve(Uri url) {
    final key = url.toString();
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = _gated(() => _resolve(url));
    _cache[key] = future;
    if (_cache.length > _maxCached) _cache.remove(_cache.keys.first);
    return future;
  }

  /// テスト用に通信を差し替える。null に戻すと素のクライアントへ戻る。
  @visibleForTesting
  static set debugClient(io.HttpClient? client) {
    _sharedClient?.close(force: true);
    _sharedClient = client;
  }

  /// テスト間で覚えた結果を捨てる。
  @visibleForTesting
  static void clearCache() => _cache.clear();

  static Future<LinkPreview?> _resolve(Uri url) async {
    try {
      return await _fetch(url).timeout(_timeout);
    } catch (_) {
      // 通信失敗・タイムアウト・想定外の HTML はすべて「カード無し」に倒す。
      // リンクは本文にそのまま残るので、読む側が失うものは無い。
      return null;
    }
  }

  static Future<LinkPreview?> _fetch(Uri url) async {
    final req = await _client.getUrl(url);
    req.headers.set(
      io.HttpHeaders.userAgentHeader,
      HttpClientFetcher.defaultUserAgent,
    );
    req.headers.set(
      io.HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml',
    );
    req.headers.set(io.HttpHeaders.acceptLanguageHeader, 'ja,en;q=0.8');
    // リダイレクトは dart:io に任せる（既定で最大 5 回）。短縮 URL や
    // http→https はこれで足りる。
    final resp = await req.close();
    if (resp.statusCode != 200) {
      await _discard(resp);
      return null;
    }
    final mime = resp.headers.contentType?.mimeType.toLowerCase();
    if (mime != null &&
        mime != 'text/html' &&
        mime != 'application/xhtml+xml') {
      await _discard(resp);
      return null;
    }

    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
      // 上限に達したら break でストリームを解約する（＝接続を切る）。
      if (bytes.length >= _maxBytes) break;
    }
    if (bytes.isEmpty) return null;

    final html = _decode(bytes, resp.headers.contentType?.charset);
    // リダイレクト後の URL を基準にする（相対 URL の解決と表示ホスト名のため）。
    final pageUrl = _finalUrl(url, resp);
    return _parse(html, pageUrl);
  }

  /// 本文を読まずに接続を手放す。
  ///
  /// `drain` は最後まで受け取ってしまうので使わない。エラーページや PDF が
  /// 数 MB あることもあり、要らないと分かったものを落とし切る意味は無い。
  /// 購読して即解約すると、その先はネットワークから引かずに接続を捨てられる。
  static Future<void> _discard(io.HttpClientResponse resp) async {
    try {
      await resp.listen(null).cancel();
    } catch (_) {}
  }

  /// リダイレクトを辿った先の URL。辿っていなければ [requested] のまま。
  static Uri _finalUrl(Uri requested, io.HttpClientResponse resp) {
    var url = requested;
    for (final redirect in resp.redirects) {
      final location = redirect.location;
      url = url.resolveUri(location);
    }
    return url;
  }

  /// バイト列を文字列にする。日本語サイトは Shift_JIS / EUC-JP がまだ現役なので、
  /// Content-Type の charset →`<meta charset>` の順に見てから読む。
  ///
  /// charset を探すのに一度 latin1 で読むのは、どの符号化でも ASCII 部分だけは
  /// そのまま読めるため（`<meta charset=...>` は ASCII で書かれている）。
  static String _decode(List<int> bytes, String? headerCharset) {
    final charset =
        headerCharset ?? _metaCharset(latin1.decode(bytes, allowInvalid: true));
    return switch (charset?.toLowerCase().trim()) {
      'shift_jis' ||
      'shift-jis' ||
      'sjis' ||
      'x-sjis' ||
      'windows-31j' ||
      'cp932' ||
      'ms_kanji' => decodeSjis(bytes),
      'euc-jp' ||
      'eucjp' ||
      'x-euc-jp' => EucJpDecoder(allowMalformed: true).convert(bytes),
      // それ以外（utf-8、未指定、知らない名前）は UTF-8 として読む。
      _ => utf8.decode(bytes, allowMalformed: true),
    };
  }

  static String? _metaCharset(String head) {
    for (final tag in _metaRe.allMatches(head)) {
      final attrs = _attributes(tag.group(0)!);
      final charset = attrs['charset'];
      if (charset != null && charset.isNotEmpty) return charset;
      if (attrs['http-equiv']?.toLowerCase() == 'content-type') {
        final match = _charsetRe.firstMatch(attrs['content'] ?? '');
        if (match != null) return match.group(1);
      }
    }
    return null;
  }

  static LinkPreview? _parse(String html, Uri pageUrl) {
    // `</head>` までで切る。本文側の `<meta>` や `<title>` を拾わないため。
    final headEnd = html.toLowerCase().indexOf('</head>');
    final head = headEnd < 0 ? html : html.substring(0, headEnd);

    final meta = <String, String>{};
    for (final tag in _metaRe.allMatches(head)) {
      final attrs = _attributes(tag.group(0)!);
      final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
      final content = attrs['content'];
      if (key == null || content == null) continue;
      // 同じ property が複数あれば先に出た方を採る（og の慣習）。
      meta.putIfAbsent(key, () => content);
    }

    String? pick(List<String> keys) {
      for (final key in keys) {
        final value = _clean(meta[key]);
        if (value != null) return value;
      }
      return null;
    }

    final title =
        pick(['og:title', 'twitter:title']) ??
        _clean(_titleRe.firstMatch(head)?.group(1));
    final description = pick([
      'og:description',
      'twitter:description',
      'description',
    ]);
    final rawImage = pick(['og:image', 'og:image:url', 'twitter:image']);
    final image = rawImage == null ? null : _absolute(rawImage, pageUrl);

    final preview = LinkPreview(
      url: pageUrl,
      siteName: pick(['og:site_name']) ?? _hostLabel(pageUrl),
      title: title,
      description: description,
      imageUrl: image,
    );
    return preview.isPresentable ? preview : null;
  }

  /// 属性値を実体参照込みで整える。改行や連続空白は 1 個の空白に潰す
  /// （カードは 1〜2 行に収めるので、元の改行を残しても行が無駄になるだけ）。
  static String? _clean(String? raw) {
    if (raw == null) return null;
    final text = decodeEntities(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  static Uri? _absolute(String raw, Uri base) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    final resolved = uri.hasScheme ? uri : base.resolveUri(uri);
    // 画像として取りに行くので http(s) 以外（data: など）は捨てる。
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    return resolved;
  }

  /// 表示用のホスト名。`www.` は情報が無いので落とす。
  static String _hostLabel(Uri url) {
    final host = url.host.toLowerCase();
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  // ---- 同時実行数の制限 ----

  static int _active = 0;
  static final _waiting = Queue<Completer<void>>();

  static Future<T> _gated<T>(Future<T> Function() op) async {
    if (_active >= maxConcurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _active++;
    try {
      return await op();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

final _metaRe = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
final _titleRe = RegExp(
  r'<title\b[^>]*>([\s\S]*?)</title\s*>',
  caseSensitive: false,
);
final _charsetRe = RegExp(r'charset\s*=\s*([\w-]+)', caseSensitive: false);
final _attrRe = RegExp(
  '''([a-zA-Z_:][\\w:.-]*)\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))''',
);

/// タグ 1 個ぶんの属性を小文字キーの map にする。
Map<String, String> _attributes(String tag) {
  final attrs = <String, String>{};
  for (final m in _attrRe.allMatches(tag)) {
    final value = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    attrs.putIfAbsent(m.group(1)!.toLowerCase(), () => value);
  }
  return attrs;
}
