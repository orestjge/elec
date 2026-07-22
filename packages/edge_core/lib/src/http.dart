/// HTTP GET の抽象。
///
/// この層をネットワーク実装から切り離すための最小インターフェース。差分取得
/// ロジック（[fetchDatDiff]）はこれ越しにしか通信しないので、実ネットワーク
/// なしで（フェイクを差して）テストできる。
///
/// 具体実装（`package:http` など）はアプリ配線層で用意し、この純 Dart 層には
/// 持ち込まない。
abstract interface class HttpFetcher {
  /// [url] に GET する。[headers] はリクエストヘッダ。
  ///
  /// 実装は 3xx を自動で追わず、そのまま返すことが望ましい（過去ログの
  /// リダイレクトをこちらで扱うため）。
  Future<FetchResponse> get(Uri url, {Map<String, String> headers});
}

/// フォーム POST の抽象（bbs.cgi 書き込み用）。
///
/// GET と分けてあるのは、読み取り系のフェイク実装（テスト）に POST を
/// 強制しないため。具体実装（[HttpFetcher] と同じクラス）は両方を実装する。
abstract interface class HttpPoster {
  /// [url] に `application/x-www-form-urlencoded` で POST する。
  ///
  /// [body] は既にパーセントエンコード済みの文字列。応答の `Set-Cookie` は
  /// [FetchResponse.setCookies] に入れて返すこと（cookie 管理に使う）。
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers,
    required String body,
  });
}

/// [HttpFetcher.get] の応答。ボディは**バイト列のまま**扱う（SJIS を
/// 文字列に早期デコードすると Range 境界で壊れるため）。
class FetchResponse {
  const FetchResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.headers = const {},
    this.setCookies = const [],
    this.remoteIpVersion,
  });

  final int statusCode;
  final List<int> bodyBytes;

  /// レスポンスヘッダ。キーは小文字に正規化して渡すこと。
  final Map<String, String> headers;

  /// `Set-Cookie` の値（`name=value` 形式）。複数 cookie を潰さないため、
  /// ヘッダマップとは別にリストで持つ。
  final List<String> setCookies;

  /// この通信で使った IP バージョン（`'IPv4'` / `'IPv6'`）。書き込み認証の
  /// 切り分け診断に使う。実装が分からない場合は null。
  final String? remoteIpVersion;

  String? header(String name) => headers[name.toLowerCase()];
}
