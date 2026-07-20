import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();
List<int> sjis(String s) => _win31j.encode(s);

/// 実サーバ（experiment 板）が返した未認証レスポンスの本文を再現。
List<int> unauthBody(String code) => sjis(
  '<html><!-- 2ch_X:error -->\n'
  '<head>\n'
  '<meta name="error_code" content="E-Unauthenticated">\n'
  '<title>ＥＲＲＯＲ</title></head>\n'
  '<body>エラー！<br>\n'
  "認証コード'$code'を用いて、以下のURLから認証を行ってください \n"
  ' https://bbs.eddibb.cc/auth-code</body></html>',
);

List<int> successBody() =>
    sjis('<html><!-- 2ch_X:true --><title>書きこみました</title>'
        '<body>書きこみました</body></html>');

List<int> rejectBody(String tag, String msg) => sjis(
  '<html><!-- 2ch_X:error -->'
  '<meta name="error_code" content="E-$tag">'
  '<body>エラー！<br>$msg</body></html>',
);

class FakePoster implements HttpPoster {
  FakePoster(this.response);
  final FetchResponse response;
  Uri? url;
  Map<String, String>? headers;
  String? body;

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    this.url = url;
    this.headers = headers;
    this.body = body;
    return response;
  }
}

void main() {
  final bbsCgi = Uri.parse('https://bbs.eddibb.cc/test/bbs.cgi');

  group('AuthTokens', () {
    test('cookieHeader を組む', () {
      const t = AuthTokens(edgeToken: 'E', tinkerToken: 'T');
      expect(t.cookieHeader, 'edge-token=E; tinker-token=T');
    });

    test('トークンが無ければ cookieHeader は null', () {
      expect(AuthTokens.none.cookieHeader, isNull);
    });

    test('Set-Cookie から更新する', () {
      final t = AuthTokens.none.updatedFrom([
        'edge-token=abc123; HttpOnly; Path=/; Max-Age=31536000',
        'tinker-token=jwt.value.here; Path=/',
      ]);
      expect(t.edgeToken, 'abc123');
      expect(t.tinkerToken, 'jwt.value.here');
    });

    test('既存トークンは Set-Cookie に無ければ保持', () {
      const prev = AuthTokens(edgeToken: 'E', tinkerToken: 'T');
      final t = prev.updatedFrom(['tinker-token=NEW']);
      expect(t.edgeToken, 'E'); // 据え置き
      expect(t.tinkerToken, 'NEW');
    });

    test('JSON 往復', () {
      const t = AuthTokens(edgeToken: 'E', tinkerToken: 'T');
      final back = AuthTokens.fromJson(t.toJson());
      expect(back.edgeToken, 'E');
      expect(back.tinkerToken, 'T');
      // 空も往復できる。
      final empty = AuthTokens.fromJson(AuthTokens.none.toJson());
      expect(empty.hasEdgeToken, isFalse);
    });
  });

  group('buildBbsCgiBody', () {
    test('edge-sender と同じ順・エンコード', () {
      final body = buildBbsCgiBody(
        board: 'liveedge',
        threadKey: '1749045135',
        message: 'みんないる',
      );
      expect(
        body,
        'submit=%8F%91%82%AB%8D%9E%82%DE&mail=&FROM=&'
        'MESSAGE=%82%DD%82%F1%82%C8%82%A2%82%E9&bbs=liveedge&key=1749045135',
      );
    });
  });

  group('buildBbsCgiThreadBody', () {
    test('新規スレッド作成のフィールド', () {
      final body = buildBbsCgiThreadBody(
        board: 'liveedge',
        title: 'テストスレ',
        message: '本文',
      );
      // submit=新規スレッド作成、subject 有り、key 無し。
      expect(body, startsWith('submit='));
      expect(body, contains('&bbs=liveedge'));
      expect(body, isNot(contains('key=')));
      // subject / MESSAGE がエンコードされて入っている（空でない）。
      expect(RegExp(r'&subject=%[0-9A-F]').hasMatch(body), isTrue);
      expect(RegExp(r'MESSAGE=%[0-9A-F]').hasMatch(body), isTrue);
    });

    test('レス本文の submit とは異なる', () {
      final thread = buildBbsCgiThreadBody(
        board: 'x',
        title: 't',
        message: 'm',
      );
      final res = buildBbsCgiBody(board: 'x', threadKey: '1', message: 'm');
      final threadSubmit = thread.split('&').first;
      final resSubmit = res.split('&').first;
      expect(threadSubmit, isNot(resSubmit));
    });
  });

  group('parseBbsCgiResult', () {
    test('成功', () {
      final r = parseBbsCgiResult(200, successBody());
      expect(r, isA<PostAccepted>());
      expect((r as PostAccepted).resNum, isNull);
    });

    test('成功: x-resnum があればレス番号を載せる', () {
      final r = parseBbsCgiResult(
        200,
        successBody(),
        headers: const {'x-resnum': '42'},
      );
      expect(r, isA<PostAccepted>());
      expect((r as PostAccepted).resNum, 42);
    });

    test('成功: x-resnum が数値でなければ null', () {
      final r = parseBbsCgiResult(
        200,
        successBody(),
        headers: const {'x-resnum': 'nan'},
      );
      expect((r as PostAccepted).resNum, isNull);
    });

    test('未認証: コードと URL を取り出す', () {
      final r = parseBbsCgiResult(200, unauthBody('016227'));
      expect(r, isA<PostNeedsAuth>());
      r as PostNeedsAuth;
      expect(r.authCode, '016227');
      expect(r.authUrl.toString(), 'https://bbs.eddibb.cc/auth-code');
    });

    test('その他エラー: タグとメッセージ', () {
      final r = parseBbsCgiResult(
        200,
        rejectBody('TooManyCreatingRes', '短期間に書き込みすぎです'),
      );
      expect(r, isA<PostRejected>());
      r as PostRejected;
      expect(r.errorCode, 'TooManyCreatingRes');
      expect(r.message, contains('短期間に書き込みすぎです'));
    });
  });

  group('BbsWriter', () {
    test('未認証応答で edge-token を回収し PostNeedsAuth を返す', () async {
      final poster = FakePoster(
        FetchResponse(
          statusCode: 200,
          bodyBytes: unauthBody('016227'),
          setCookies: const [
            'edge-token=deadbeefdeadbeefdeadbeefdeadbeef; HttpOnly; Path=/',
          ],
        ),
      );
      final result = await BbsWriter(poster).post(
        bbsCgi: bbsCgi,
        board: 'experiment',
        threadKey: '1762103691',
        message: 'テスト',
      );

      expect(result.outcome, isA<PostNeedsAuth>());
      // 未認証でも edge-token は回収して次回に使う。
      expect(result.tokens.edgeToken, 'deadbeefdeadbeefdeadbeefdeadbeef');
      // 初回は Cookie ヘッダ無し。
      expect(poster.headers!.containsKey('Cookie'), isFalse);
    });

    test('トークン保持時は Cookie を送り、成功で tinker を更新', () async {
      final poster = FakePoster(
        FetchResponse(
          statusCode: 200,
          bodyBytes: successBody(),
          setCookies: const ['tinker-token=updated.jwt'],
        ),
      );
      final result = await BbsWriter(poster).post(
        bbsCgi: bbsCgi,
        board: 'liveedge',
        threadKey: '123',
        message: 'やあ',
        tokens: const AuthTokens(edgeToken: 'E1', tinkerToken: 'T1'),
      );

      expect(result.outcome, isA<PostAccepted>());
      expect(poster.headers!['Cookie'], 'edge-token=E1; tinker-token=T1');
      expect(result.tokens.edgeToken, 'E1');
      expect(result.tokens.tinkerToken, 'updated.jwt'); // 更新された
    });

    test('成功応答の x-resnum ヘッダをレス番号として返す', () async {
      final poster = FakePoster(
        FetchResponse(
          statusCode: 200,
          bodyBytes: successBody(),
          headers: const {'x-resnum': '7'},
        ),
      );
      final result = await BbsWriter(poster).post(
        bbsCgi: bbsCgi,
        board: 'liveedge',
        threadKey: '123',
        message: 'やあ',
      );

      expect(result.outcome, isA<PostAccepted>());
      expect((result.outcome as PostAccepted).resNum, 7);
    });
  });
}
