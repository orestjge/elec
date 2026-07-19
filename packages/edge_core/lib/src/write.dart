import 'package:edge_sjis/edge_sjis.dart';

import 'html_text.dart';
import 'http.dart';

/// 書き込みに使う cookie（edge-token と tinker-token）。
///
/// - edge-token: 認証済みトークン。認証フローで有効化される。
/// - tinker-token: 書き込みごとに更新される JWT（level 等）。**保存して毎回
///   送らないと level が上がらない**（[[tinker-token の永続化]]）。
class AuthTokens {
  const AuthTokens({this.edgeToken, this.tinkerToken});

  static const none = AuthTokens();

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
    edgeToken: json['edge'] as String?,
    tinkerToken: json['tinker'] as String?,
  );

  final String? edgeToken;
  final String? tinkerToken;

  bool get hasEdgeToken => edgeToken != null;

  Map<String, dynamic> toJson() => {'edge': edgeToken, 'tinker': tinkerToken};

  /// `Cookie` ヘッダ値。トークンが無ければ null。
  String? get cookieHeader {
    final parts = [
      if (edgeToken != null) 'edge-token=$edgeToken',
      if (tinkerToken != null) 'tinker-token=$tinkerToken',
    ];
    return parts.isEmpty ? null : parts.join('; ');
  }

  /// 応答の `Set-Cookie`（`name=value` 形式のリスト）で更新した新しい値を返す。
  AuthTokens updatedFrom(List<String> setCookies) {
    var edge = edgeToken;
    var tinker = tinkerToken;
    for (final c in setCookies) {
      final m = RegExp(r'^\s*([^=;]+)=([^;]*)').firstMatch(c);
      if (m == null) continue;
      final name = m.group(1)!.trim();
      final value = m.group(2)!.trim();
      if (name == 'edge-token') edge = value;
      if (name == 'tinker-token' || name == 'tinker') tinker = value;
    }
    return AuthTokens(edgeToken: edge, tinkerToken: tinker);
  }
}

/// bbs.cgi の POST ボディを組み立てる。
///
/// フィールド順・名前はブラウザのフォーム送信に合わせる
/// （`../edge-sender` の実績値と同じ）。本文は SJIS でパーセントエンコード。
String buildBbsCgiBody({
  required String board,
  required String threadKey,
  required String message,
  String name = '',
  String mail = '',
}) {
  return encodeFormBody({
    'submit': '書き込む',
    'mail': mail,
    'FROM': name,
    'MESSAGE': message,
    'bbs': board,
    'key': threadKey,
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
}) {
  return encodeFormBody({
    'submit': '新規スレッド作成',
    'subject': title,
    'mail': mail,
    'FROM': name,
    'MESSAGE': message,
    'bbs': board,
  });
}

/// bbs.cgi の応答の判定結果。
sealed class BbsCgiResult {
  const BbsCgiResult();
}

/// 書き込み成功（`<!-- 2ch_X:true -->`）。
class PostAccepted extends BbsCgiResult {
  const PostAccepted();
}

/// 未認証。[authCode] を [authUrl] で入力して認証する必要がある。
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

final _errorCodeRe = RegExp(r'name="error_code"\s+content="E-([^"]+)"');
final _authCodeRe = RegExp(r"認証コード'([^']+)'");
final _authUrlRe = RegExp(r'(https?://[^\s<]+/auth-code)');

/// bbs.cgi の応答（SJIS バイト列）を判定する。
///
/// **HTTP ステータスでは判定できない**（多くが 200）。本文のマーカーで見る。
/// - 成功: `<!-- 2ch_X:true -->`
/// - 失敗: `<meta name="error_code" content="E-{tag}">`
BbsCgiResult parseBbsCgiResult(int status, List<int> bodyBytes) {
  final body = decodeSjis(bodyBytes);
  if (body.contains('2ch_X:true')) return const PostAccepted();

  final code = _errorCodeRe.firstMatch(body)?.group(1) ?? 'Unknown';
  if (code == 'Unauthenticated') {
    final authCode = _authCodeRe.firstMatch(body)?.group(1) ?? '';
    final url = _authUrlRe.firstMatch(body)?.group(1);
    return PostNeedsAuth(
      authCode: authCode,
      authUrl: Uri.parse(url ?? 'https://bbs.eddibb.cc/auth-code'),
    );
  }
  return PostRejected(errorCode: code, message: _errorMessage(body));
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
  Future<WriteResult> post({
    required Uri bbsCgi,
    required String board,
    required String threadKey,
    required String message,
    String name = '',
    String mail = '',
    AuthTokens tokens = AuthTokens.none,
  }) {
    return _send(
      bbsCgi,
      buildBbsCgiBody(
        board: board,
        threadKey: threadKey,
        message: message,
        name: name,
        mail: mail,
      ),
      tokens,
    );
  }

  /// 新規スレッド作成。
  Future<WriteResult> createThread({
    required Uri bbsCgi,
    required String board,
    required String title,
    required String message,
    String name = '',
    String mail = '',
    AuthTokens tokens = AuthTokens.none,
  }) {
    return _send(
      bbsCgi,
      buildBbsCgiThreadBody(
        board: board,
        title: title,
        message: message,
        name: name,
        mail: mail,
      ),
      tokens,
    );
  }

  Future<WriteResult> _send(Uri bbsCgi, String body, AuthTokens tokens) async {
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      if (tokens.cookieHeader != null) 'Cookie': tokens.cookieHeader!,
    };
    final resp = await poster.post(bbsCgi, headers: headers, body: body);
    return WriteResult(
      outcome: parseBbsCgiResult(resp.statusCode, resp.bodyBytes),
      tokens: tokens.updatedFrom(resp.setCookies),
    );
  }
}
