import 'dart:convert';
import 'dart:io' as io;

import 'package:edge_core/edge_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

/// `package:http`（GET）と dart:io（POST）による [HttpFetcher] / [HttpPoster]
/// の具象実装。
///
/// **接続の IP バージョンを IPv6 優先で決め打ちし、失敗したら IPv4 に落とす**
/// （ブラウザの Happy Eyeballs 相当）。
///
/// なぜ必要か: デュアルスタック環境で dart:io は接続ごとに IPv4/IPv6 を非決定的に
/// 選び、素の POST は一貫して IPv4 に落ちることが実測で分かった。書き込み認証は
/// bbs.cgi の POST 時 IP と `/auth-code`（ブラウザ）の IP 一致を要求する。ブラウザ
/// は IPv6 を優先するので、アプリも IPv6 に寄せる。ただし IPv6 が壊れた回線
/// （AAAA はあるが到達不可）で固定すると全通信が死ぬので、接続失敗時は IPv4 に
/// フォールバックする。こうすればブラウザと同じ挙動になり、どの回線でも動き、
/// かつ両者の IP バージョンも揃う（詳細は PROJECT.md）。
///
/// POST に dart:io を直接使うのは、`package:http` が複数の `Set-Cookie` を
/// カンマ結合して壊すため。cookie を正しく取るには [io.HttpClient] の
/// `response.cookies` が要る。
class HttpClientFetcher implements HttpFetcher, HttpPoster {
  HttpClientFetcher({this.userAgent = defaultUserAgent}) {
    _build();
  }

  /// 専ブラとして識別可能な UA を名乗る（ブラウザ詐称はしない）。
  /// eddist は UA を判定に使う（`dat_routing.rs` の "Xeno" 判定など）。
  static const defaultUserAgent = 'elec/0.1';

  final String userAgent;

  /// 現在優先する IP バージョン。IPv6 で始め、到達不可なら IPv4 へ切り替える。
  io.InternetAddressType _preferred = io.InternetAddressType.IPv6;

  late io.HttpClient _io;
  late http.Client _client;

  void _build() {
    _io = io.HttpClient()..connectionFactory = _connect;
    _client = io_client.IOClient(_io);
  }

  /// ホストを [_preferred] のバージョンで解決して接続する。該当レコードが無ければ
  /// もう一方で解決する（IPv4 のみ / IPv6 のみの回線に対応）。
  ///
  /// connectionFactory を差し替えると HttpClient は TLS 化を肩代わりしなくなる
  /// ため、https では自前で [io.SecureSocket] を返す。`InternetAddress.lookup`
  /// が返すアドレスは `.host` に元のホスト名を保持するので、SNI と証明書検証は
  /// 正しくホスト名に対して行われる。
  Future<io.ConnectionTask<io.Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final port = uri.port == 0
        ? (uri.scheme == 'https' ? 443 : 80)
        : uri.port;
    final other = _preferred == io.InternetAddressType.IPv6
        ? io.InternetAddressType.IPv4
        : io.InternetAddressType.IPv6;
    var addrs = await io.InternetAddress.lookup(uri.host, type: _preferred);
    if (addrs.isEmpty) {
      addrs = await io.InternetAddress.lookup(uri.host, type: other);
    }
    if (addrs.isEmpty) {
      throw const io.SocketException('host did not resolve');
    }
    final addr = addrs.first;
    if (uri.scheme == 'https') {
      return io.SecureSocket.startConnect(addr, port);
    }
    return io.Socket.startConnect(addr, port);
  }

  /// 接続系の失敗（IPv6 到達不可など）なら 1 度だけ IPv4 に切り替えて再試行する。
  Future<T> _withFallback<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      if (_preferred == io.InternetAddressType.IPv6 && _isConnectionError(e)) {
        _preferred = io.InternetAddressType.IPv4;
        // プールした IPv6 接続を捨てて作り直す。
        _client.close();
        _io.close(force: true);
        _build();
        return await op();
      }
      rethrow;
    }
  }

  static bool _isConnectionError(Object e) =>
      e is io.SocketException ||
      e is io.HandshakeException ||
      e is http.ClientException; // IOClient は socket 例外をこれで包む

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) {
    return _withFallback(() async {
      // 3xx を自動で追わない（HttpFetcher の規約）。dat落ち時の過去ログ
      // リダイレクトは DatFetcher 側で Location を見て辿るので、ここで
      // 潰さず 30x と Location をそのまま返す。
      final req = http.Request('GET', url)
        ..followRedirects = false
        ..headers.addAll({'User-Agent': userAgent, ...headers});
      final streamed = await _client.send(req);
      final resp = await http.Response.fromStream(streamed);
      return FetchResponse(
        statusCode: resp.statusCode,
        bodyBytes: resp.bodyBytes,
        // ヘッダのキーは package:http が小文字化済み。FetchResponse の規約に合う。
        headers: resp.headers,
      );
    });
  }

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) {
    return _withFallback(() async {
      final req = await _io.postUrl(url);
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      headers.forEach((k, v) => req.headers.set(k, v));
      // body はパーセントエンコード済み ASCII。
      req.add(ascii.encode(body));
      final resp = await req.close();

      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      final headerMap = <String, String>{};
      resp.headers.forEach((k, v) => headerMap[k.toLowerCase()] = v.join(','));

      return FetchResponse(
        statusCode: resp.statusCode,
        bodyBytes: bytes,
        headers: headerMap,
        setCookies: resp.cookies.map((c) => '${c.name}=${c.value}').toList(),
      );
    });
  }

  void close() {
    _client.close();
    _io.close(force: true);
  }
}
