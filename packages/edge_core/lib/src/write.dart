import 'package:edge_sjis/edge_sjis.dart';

import 'html_text.dart';
import 'http.dart';

/// 書き込みに使う **ホスト単位の Cookie 束**。
///
/// eddist は `edge-token`（認証済みトークン）と `tinker-token`（書き込みごとに
/// 更新される JWT＝level。**保存して毎回送らないと level が上がらない**、
/// [[tinker-token の永続化]]）を使う。5ch は `MonaTicket`（どんぐり）等を使う。
/// どちらも「サーバの `Set-Cookie` を保存して毎回送り返す」だけなので、特定の
/// 名前に縛らず**任意の Cookie を汎用に保持**する。edge/tinker はよく使うので
/// 便宜アクセサを残す。
class AuthTokens {
  const AuthTokens([this.cookies = const {}]);

  static const none = AuthTokens();

  /// eddist 用の便宜コンストラクタ。挿入順を edge→tinker に固定する。
  factory AuthTokens.eddist({String? edgeToken, String? tinkerToken}) =>
      AuthTokens({
        if (edgeToken != null) 'edge-token': edgeToken,
        if (tinkerToken != null) 'tinker-token': tinkerToken,
      });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    // 旧単一ファイル形式 {edge, tinker} を移行して読む。
    if (json.containsKey('edge') || json.containsKey('tinker')) {
      return AuthTokens.eddist(
        edgeToken: json['edge'] as String?,
        tinkerToken: json['tinker'] as String?,
      );
    }
    final cookies = <String, String>{};
    json.forEach((k, v) {
      if (v is String) cookies[k] = v;
    });
    return AuthTokens(cookies);
  }

  /// Cookie 名 → 値。挿入順を保つ（`cookieHeader` の並びを安定させるため）。
  final Map<String, String> cookies;

  String? operator [](String name) => cookies[name];

  String? get edgeToken => cookies['edge-token'];
  String? get tinkerToken => cookies['tinker-token'];
  bool get hasEdgeToken => edgeToken != null;
  bool get isEmpty => cookies.isEmpty;

  /// 保存形式は素の `{name: value}` マップ。
  Map<String, dynamic> toJson() => Map<String, String>.of(cookies);

  /// `Cookie` ヘッダ値。Cookie が無ければ null。
  String? get cookieHeader => cookies.isEmpty
      ? null
      : cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 応答の `Set-Cookie` で更新した新しい値を返す。
  ///
  /// 通常は `name=value` を上書き保存する。**`Max-Age<=0` または過去の `Expires`**
  /// を持つ Cookie は削除する（5ch の「Broken MonaTicket」再植え直しに必要）。
  /// [now] は失効判定の基準時刻（テスト用。既定は現在時刻）。
  AuthTokens updatedFrom(List<String> setCookies, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final next = Map<String, String>.of(cookies);
    for (final c in setCookies) {
      final parsed = _parseSetCookie(c);
      if (parsed == null) continue;
      if (parsed.isExpired(at)) {
        next.remove(parsed.name);
      } else {
        next[parsed.name] = parsed.value;
      }
    }
    return AuthTokens(next);
  }
}

class _ParsedCookie {
  _ParsedCookie(this.name, this.value, this.maxAge, this.expires);
  final String name;
  final String value;
  final int? maxAge;
  final DateTime? expires;

  bool isExpired(DateTime now) {
    if (maxAge != null && maxAge! <= 0) return true;
    if (expires != null && expires!.isBefore(now)) return true;
    return false;
  }
}

_ParsedCookie? _parseSetCookie(String setCookie) {
  final parts = setCookie.split(';');
  final nv = RegExp(r'^\s*([^=;]+)=(.*)$').firstMatch(parts.first);
  if (nv == null) return null;
  final name = nv.group(1)!.trim();
  if (name.isEmpty) return null;
  final value = nv.group(2)!.trim();
  int? maxAge;
  DateTime? expires;
  for (var i = 1; i < parts.length; i++) {
    final attr = parts[i].trim();
    final eq = attr.indexOf('=');
    final key = (eq >= 0 ? attr.substring(0, eq) : attr).toLowerCase();
    final av = eq >= 0 ? attr.substring(eq + 1).trim() : '';
    if (key == 'max-age') maxAge = int.tryParse(av);
    if (key == 'expires') expires = _parseHttpDate(av);
  }
  return _ParsedCookie(name, value, maxAge, expires);
}

const _httpMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// HTTP-date（`Wdy, DD Mon YYYY HH:MM:SS GMT` / `DD-Mon-YY`）を UTC で解く。
/// dart:io に依存しないための最小実装。解けなければ null。
DateTime? _parseHttpDate(String s) {
  final m = RegExp(
    r'(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})[ ]+(\d{1,2}):(\d{1,2}):(\d{1,2})',
  ).firstMatch(s);
  int normYear(int y) => y < 100 ? (y >= 70 ? 1900 + y : 2000 + y) : y;
  if (m != null) {
    final mon = _httpMonths[m.group(2)!.toLowerCase()];
    if (mon == null) return null;
    return DateTime.utc(
      normYear(int.parse(m.group(3)!)),
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
  final d = RegExp(r'(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})').firstMatch(s);
  if (d == null) return null;
  final mon = _httpMonths[d.group(2)!.toLowerCase()];
  if (mon == null) return null;
  return DateTime.utc(
    normYear(int.parse(d.group(3)!)),
    mon,
    int.parse(d.group(1)!),
  );
}

/// bbs.cgi の POST ボディを組み立てる。
///
/// フィールド順・名前はブラウザのフォーム送信に合わせる
/// （`../edge-sender` の実績値と同じ）。本文は SJIS でパーセントエンコード。
/// [time] は 5ch が要求する投稿時刻（UNIX 秒。Slevo が付ける）。eddist は不要
/// （null なら付けない＝従来の body のまま）。
String buildBbsCgiBody({
  required String board,
  required String threadKey,
  required String message,
  String name = '',
  String mail = '',
  String? time,
}) {
  return encodeFormBody({
    'submit': '書き込む',
    'mail': mail,
    'FROM': name,
    'MESSAGE': message,
    'bbs': board,
    'key': threadKey,
    if (time != null) 'time': time,
  });
}

/// bbs.cgi の新規スレッド作成の POST ボディを組み立てる。
///
/// 応答書き込みとの違いは `submit=新規スレッド作成`、`subject`（スレタイ）を
/// 持ち、`key` を持たないこと（`eddist-server/src/routes/bbs_cgi.rs`）。
String buildBbsCgiThreadBody({
  required String board,
  required String title,
  required String message,
  String name = '',
  String mail = '',
  String? time,
}) {
  return encodeFormBody({
    'submit': '新規スレッド作成',
    'subject': title,
    'mail': mail,
    'FROM': name,
    'MESSAGE': message,
    if (time != null) 'time': time,
    'bbs': board,
  });
}

/// bbs.cgi の応答の判定結果。
sealed class BbsCgiResult {
  const BbsCgiResult();
}

/// 書き込み成功（`<!-- 2ch_X:true -->`）。
class PostAccepted extends BbsCgiResult {
  const PostAccepted({this.resNum});

  /// 書き込んだレスの番号。サーバが `x-resnum` ヘッダで返したときのみ入る。
  /// スレ立てや、ヘッダを返さないサーバでは null。
  final int? resNum;
}

/// 未認証。[authUrl] をブラウザで開いて認証する必要がある。
///
/// eddist は [authCode] を認証ページで入力する。ぷにぷに等、URL を開くだけの
/// 互換掲示板では空文字になる。
class PostNeedsAuth extends BbsCgiResult {
  const PostNeedsAuth({required this.authCode, required this.authUrl});
  final String authCode;
  final Uri authUrl;
}

/// その他のエラー。[errorCode] は `E-` を除いたタグ（例: `TooManyCreatingRes`）。
class PostRejected extends BbsCgiResult {
  const PostRejected({required this.errorCode, required this.message});
  final String errorCode;
  final String message;
}

/// 5ch の「書き込み確認」ページ（`<!-- 2ch_X:cookie -->` / `check`）。
///
/// どんぐり（クッキー）確認。フォームの hidden を詰め直して `submit=上記全てを
/// 承諾して書き込む` で再送すると通る。[BbsWriter] が自動で再送するので、通常は
/// UI に露出しない。
class PostNeedsConfirm extends BbsCgiResult {
  const PostNeedsConfirm({required this.hiddenFields});

  /// 確認フォームの hidden `<input>`（HTML エンティティは復号済み）。
  final Map<String, String> hiddenFields;
}

final _errorCodeRe = RegExp(r'name="error_code"\s+content="E-([^"]+)"');
final _authCodeRe = RegExp(r"認証コード'([^']+)'");
final _authUrlRe = RegExp(r'''https?://[^\s<>"']+''');
final _twoChXRe = RegExp(r'2ch_X:(\w+)');
final _hiddenInputRe = RegExp(
  r'''<input\b[^>]*\btype\s*=\s*["']?hidden["']?[^>]*>''',
  caseSensitive: false,
);

/// bbs.cgi の応答（SJIS バイト列）を判定する。
///
/// **HTTP ステータスでは判定できない**（多くが 200）。本文のマーカーで見る。
/// - 成功: `<!-- 2ch_X:true -->`
/// - eddist 未認証: `<meta name="error_code" content="E-Unauthenticated">`
/// - 5ch 確認（どんぐり/クッキー）: `<!-- 2ch_X:cookie -->` / `check` ＋ hidden フォーム
/// - 失敗: それ以外（eddist は error_code タグ、5ch は `2ch_X:error`/`false`）
///
/// [headers] を渡すと、成功時に `x-resnum`（サーバが返す書き込んだレス番号）を
/// [PostAccepted.resNum] に載せる。キーは小文字で引く。
BbsCgiResult parseBbsCgiResult(
  int status,
  List<int> bodyBytes, {
  Map<String, String> headers = const {},
}) {
  final body = decodeSjis(bodyBytes);
  final marker = _twoChXRe.firstMatch(body)?.group(1);
  if (marker == 'true' ||
      body.contains('2ch_X:true') ||
      (marker != 'error' && _looksAccepted(body))) {
    return PostAccepted(resNum: int.tryParse(headers['x-resnum'] ?? ''));
  }

  // 書き込み POST が 30x（landing へのリダイレクト等）。成功でも確認でもない。
  // 5ch は書き込みを `.net` ホストで受けるので、`.io` に投げると 302 で landing
  // に飛ばされる。ここまで来たら板の状態がおかしいので明示的に知らせる。
  if (status >= 300 && status < 400) {
    return PostRejected(
      errorCode: 'Redirect',
      message: '書き込み先がリダイレクトされました（$status）。板が移転・閉鎖した可能性があります',
    );
  }

  final code = _errorCodeRe.firstMatch(body)?.group(1) ?? 'Unknown';
  if (code == 'Unauthenticated') {
    final authCode = _authCodeRe.firstMatch(body)?.group(1) ?? '';
    final url = _firstUrl(body);
    return PostNeedsAuth(
      authCode: authCode,
      authUrl: Uri.parse(url ?? 'https://bbs.eddibb.cc/auth-code'),
    );
  }

  final authUrl = _authUrlFromBody(body);
  if (authUrl != null) {
    return PostNeedsAuth(authCode: '', authUrl: authUrl);
  }

  // 5ch の書き込み確認（どんぐり/クッキー）。hidden を詰め直して再送する。
  if (marker == 'cookie' || marker == 'check' || body.contains('書き込み確認')) {
    return PostNeedsConfirm(hiddenFields: extractHiddenFields(body));
  }

  return PostRejected(errorCode: code, message: _errorMessage(body));
}

Uri? _authUrlFromBody(String body) {
  final text = htmlToText(body).toLowerCase();
  final looksLikeAuth =
      text.contains('authentication required') ||
      text.contains('authentification required') ||
      text.contains('unauthenticated') ||
      text.contains('認証');
  if (!looksLikeAuth) return null;
  final url = _firstUrl(body) ?? _firstUrl(text);
  return url == null ? null : Uri.tryParse(url);
}

String? _firstUrl(String text) {
  final raw = _authUrlRe.firstMatch(text)?.group(0);
  if (raw == null) return null;
  return raw.replaceFirst(RegExp(r'''[)\].,。、;:]+$'''), '');
}

bool _looksAccepted(String body) {
  final text = htmlToText(body);
  return RegExp(r'書き(?:こ|込)みました').hasMatch(text) &&
      !text.contains('エラー') &&
      !text.contains('ERROR');
}

/// HTML から hidden `<input>` の `name` → `value` を取り出す（エンティティ復号済み）。
/// 5ch の書き込み確認フォームを Phase 2 で詰め直すのに使う。
Map<String, String> extractHiddenFields(String html) {
  final result = <String, String>{};
  for (final m in _hiddenInputRe.allMatches(html)) {
    final tag = m.group(0)!;
    final name = _attr(tag, 'name');
    if (name == null || name.isEmpty) continue;
    result[name] = decodeEntities(_attr(tag, 'value') ?? '');
  }
  return result;
}

String? _attr(String tag, String attr) {
  final quoted = RegExp(
    '\\b$attr\\s*=\\s*'
    r'''(["'])(.*?)\1''',
    caseSensitive: false,
  ).firstMatch(tag);
  if (quoted != null) return quoted.group(2);
  final bare = RegExp(
    '\\b$attr\\s*=\\s*'
    r'([^\s">]+)',
    caseSensitive: false,
  ).firstMatch(tag);
  return bare?.group(1);
}

/// エラー本文から利用者向けメッセージを取り出す。`エラー！` の後ろを拾う。
String _errorMessage(String body) {
  final text = htmlToText(body);
  final idx = text.indexOf('エラー！');
  final rest = idx >= 0 ? text.substring(idx + 'エラー！'.length) : text;
  return rest.trim().replaceAll(RegExp(r'\n{2,}'), '\n');
}

/// 1 回の書き込み結果と、更新後のトークン。
class WriteResult {
  const WriteResult({required this.outcome, required this.tokens});
  final BbsCgiResult outcome;

  /// 応答の Set-Cookie を反映したトークン。次回に持ち回すこと。
  final AuthTokens tokens;
}

/// bbs.cgi への書き込み（レス・スレ立て）を行う。純ロジックで、通信は
/// [HttpPoster] 越し。
class BbsWriter {
  const BbsWriter(this.poster);
  final HttpPoster poster;

  /// スレッドへのレス書き込み。
  ///
  /// [referer] は 5ch がレス投稿に要求する read.cgi のスレ URL。eddist では不要
  /// （null）。
  Future<WriteResult> post({
    required Uri bbsCgi,
    required String board,
    required String threadKey,
    required String message,
    String name = '',
    String mail = '',
    AuthTokens tokens = AuthTokens.none,
    String? referer,
    String? time,
    String? userAgent,
  }) {
    return _send(
      bbsCgi,
      buildBbsCgiBody(
        board: board,
        threadKey: threadKey,
        message: message,
        name: name,
        mail: mail,
        time: time,
      ),
      tokens,
      referer: referer,
      userAgent: userAgent,
    );
  }

  /// 新規スレッド作成。[referer] は 5ch では板 URL。
  Future<WriteResult> createThread({
    required Uri bbsCgi,
    required String board,
    required String title,
    required String message,
    String name = '',
    String mail = '',
    AuthTokens tokens = AuthTokens.none,
    String? referer,
    String? time,
    String? userAgent,
  }) {
    return _send(
      bbsCgi,
      buildBbsCgiThreadBody(
        board: board,
        title: title,
        message: message,
        name: name,
        mail: mail,
        time: time,
      ),
      tokens,
      referer: referer,
      userAgent: userAgent,
    );
  }

  Future<WriteResult> _send(
    Uri bbsCgi,
    String body,
    AuthTokens tokens, {
    String? referer,
    String? userAgent,
  }) async {
    var current = tokens;
    var resp = await _post(bbsCgi, body, current, referer, userAgent);
    current = current.updatedFrom(resp.setCookies);
    var outcome = parseBbsCgiResult(
      resp.statusCode,
      resp.bodyBytes,
      headers: resp.headers,
    );

    // 5ch の書き込み確認（どんぐり/クッキー）は hidden を詰め直して 1 回だけ
    // 自動再送する。MonaTicket は上の updatedFrom で既にジャーへ入っている。
    if (outcome is PostNeedsConfirm) {
      final confirmBody = encodeFormBody({
        ...outcome.hiddenFields,
        'submit': '上記全てを承諾して書き込む',
      });
      resp = await _post(bbsCgi, confirmBody, current, referer, userAgent);
      current = current.updatedFrom(resp.setCookies);
      outcome = parseBbsCgiResult(
        resp.statusCode,
        resp.bodyBytes,
        headers: resp.headers,
      );
    }

    return WriteResult(outcome: outcome, tokens: current);
  }

  Future<FetchResponse> _post(
    Uri bbsCgi,
    String body,
    AuthTokens tokens,
    String? referer,
    String? userAgent,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      if (tokens.cookieHeader != null) 'Cookie': tokens.cookieHeader!,
      if (referer != null) 'Referer': referer,
      if (userAgent != null) 'User-Agent': userAgent,
    };
    return poster.post(bbsCgi, headers: headers, body: body);
  }
}
