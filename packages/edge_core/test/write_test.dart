import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

final _win31j = Windows31JCodec();
List<int> sjis(String s) => _win31j.encode(s);

final _eucJp = EucJpEncoder();
List<int> eucJp(String s) => _eucJp.convert(s);

/// 実サーバ（jbbs.shitaraba.net）が返したエラーページ。EUC-JP・`2ch_X:error`
/// つきで、見出しは `<title>` と本文の 2 箇所に出る。
List<int> shitarabaErrorBody(String message) => eucJp(
  '<!DOCTYPE html>\n<html lang="ja">\n<head>\n'
  '<meta charset="EUC-JP">\n<title>ERROR!!</title>\n</head>\n'
  '<body bgcolor="#FFFFFF">\n<!-- 2ch_X:error -->\n'
  '<table width="100%" border="1"><tr><td><b>\n'
  'ERROR!!\n<br>\n<br>\n$message\n</b></td></tr></table>\n'
  '<hr size="1">\n<div align="right">'
  '<a href="http://rentalbbs.shitaraba.com/">したらば掲示板 (無料レンタル)</a>'
  '</div>\n</body>\n</html>',
);

/// したらばの成功ページ（5ch と同じ `2ch_X:true` マーカーを吐く）。
List<int> shitarabaSuccessBody() => eucJp(
  '<html><!-- 2ch_X:true --><head><title>書きこみました。</title></head>'
  '<body>書きこみました。</body></html>',
);

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

List<int> successBody() => sjis(
  '<html><!-- 2ch_X:true --><title>書きこみました</title>'
  '<body>書きこみました</body></html>',
);

List<int> rejectBody(String tag, String msg) => sjis(
  '<html><!-- 2ch_X:error -->'
  '<meta name="error_code" content="E-$tag">'
  '<body>エラー！<br>$msg</body></html>',
);

List<int> authUrlOnlyBody() => sjis(
  '<html><head><title>ERROR</title></head>'
  '<body>authentication required<br>'
  'https://bbs.punipuni.eu/auth-code?token=abc.</body></html>',
);

List<int> legacyErrorBody() => sjis(
  '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">'
  '<html><body>ERROR!<br>'
  '<!--nobanner--><!-- 2ch_X:error -->'
  'ERROR: 書き込みに必要なレベルが足りていません。</body></html>',
);

List<int> legacySuccessWithChallengeBody() => sjis(
  '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">'
  '<html><body>'
  '書きこみました。<br>'
  '書きこみました。<br>'
  '画面を切り替える'
  '<script>'
  "(function(){window.__CF\$cv={params:{r:'a20446e4ec767897'}};})();"
  '</script>'
  '</body></html>',
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

/// 呼び出しごとに順に応答を返し、各リクエストを記録する（二段階 POST 検証用）。
class QueuePoster implements HttpPoster {
  QueuePoster(this._responses);
  final List<FetchResponse> _responses;
  final List<({Map<String, String> headers, String body})> calls = [];
  int _i = 0;

  @override
  Future<FetchResponse> post(
    Uri url, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    calls.add((headers: headers, body: body));
    return _responses[_i++];
  }
}

/// 5ch の「書き込み確認」ページ（どんぐり/クッキー）。hidden フォーム付き。
List<int> confirmBody5ch() => sjis(
  '<html><!-- 2ch_X:cookie --><head><title>書き込み確認</title></head>\n'
  '<body>書き込み確認<br>\n'
  '<form method="POST" action="../test/bbs.cgi">\n'
  '<input type="hidden" name="bbs" value="news4vip">\n'
  '<input type="hidden" name="key" value="1700000000">\n'
  '<input type="hidden" name="time" value="1700000001">\n'
  '<input type="hidden" name="FROM" value="">\n'
  '<input type="hidden" name="mail" value="">\n'
  '<input type="hidden" name="MESSAGE" value="&lt;test&gt;">\n'
  '<input type="hidden" name="hash" value="abc123">\n'
  '<input type="submit" value="上記全てを承諾して書き込む">\n'
  '</form></body></html>',
);

/// 5ch の成功ページ。
List<int> success5ch() => sjis(
  '<html><!-- 2ch_X:true --><head><title>書きこみました</title></head>'
  '<body>書きこみました</body></html>',
);

void main() {
  final bbsCgi = Uri.parse('https://bbs.eddibb.cc/test/bbs.cgi');

  group('AuthTokens', () {
    test('cookieHeader を組む', () {
      final t = AuthTokens.eddist(edgeToken: 'E', tinkerToken: 'T');
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
      final prev = AuthTokens.eddist(edgeToken: 'E', tinkerToken: 'T');
      final t = prev.updatedFrom(['tinker-token=NEW']);
      expect(t.edgeToken, 'E'); // 据え置き
      expect(t.tinkerToken, 'NEW');
    });

    test('任意の Cookie（MonaTicket 等）も保持・送出する', () {
      final t = AuthTokens.none.updatedFrom([
        'MonaTicket=abc.def; Path=/; Max-Age=8640000',
        'other=x; Path=/',
      ]);
      expect(t['MonaTicket'], 'abc.def');
      expect(t.cookieHeader, contains('MonaTicket=abc.def'));
      expect(t.cookieHeader, contains('other=x'));
    });

    test('Max-Age=0 の Set-Cookie は削除する（Broken MonaTicket 再植え）', () {
      final prev = AuthTokens.none.updatedFrom(['MonaTicket=abc; Max-Age=100']);
      expect(prev['MonaTicket'], 'abc');
      final t = prev.updatedFrom(['MonaTicket=deleted; Max-Age=0']);
      expect(t['MonaTicket'], isNull);
    });

    test('過去 Expires の Set-Cookie は削除する', () {
      final prev = AuthTokens.none.updatedFrom(['MonaTicket=abc']);
      final t = prev.updatedFrom([
        'MonaTicket=x; Expires=Thu, 01-Jan-1970 00:00:00 GMT',
      ], now: DateTime.utc(2026, 1, 1));
      expect(t['MonaTicket'], isNull);
    });

    test('未来 Expires は保持する', () {
      final t = AuthTokens.none.updatedFrom([
        'MonaTicket=keep; Expires=Wed, 09 Jun 2100 10:18:14 GMT',
      ], now: DateTime.utc(2026, 1, 1));
      expect(t['MonaTicket'], 'keep');
    });

    test('JSON 往復（素の Cookie マップ）', () {
      final t = AuthTokens.eddist(edgeToken: 'E', tinkerToken: 'T');
      final back = AuthTokens.fromJson(t.toJson());
      expect(back.edgeToken, 'E');
      expect(back.tinkerToken, 'T');
      // 空も往復できる。
      final empty = AuthTokens.fromJson(AuthTokens.none.toJson());
      expect(empty.hasEdgeToken, isFalse);
    });

    test('旧形式 {edge, tinker} も読める（移行）', () {
      final back = AuthTokens.fromJson({'edge': 'E', 'tinker': 'T'});
      expect(back.edgeToken, 'E');
      expect(back.tinkerToken, 'T');
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

  group('buildBbsCgiBody time（5ch）', () {
    test('time を渡すと time フィールドが入る', () {
      final body = buildBbsCgiBody(
        board: 'news4vip',
        threadKey: '1700000000',
        message: 'x',
        time: '1700000001',
      );
      expect(body, contains('&time=1700000001'));
    });

    test('time が null なら time フィールドは無い（eddist 従来どおり）', () {
      final body = buildBbsCgiBody(
        board: 'liveedge',
        threadKey: '1',
        message: 'x',
      );
      expect(body, isNot(contains('time=')));
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

    test('成功: 0ch系の書きこみましたページも成功扱いにする', () {
      final r = parseBbsCgiResult(200, legacySuccessWithChallengeBody());
      expect(r, isA<PostAccepted>());
    });

    test('未認証: コードと URL を取り出す', () {
      final r = parseBbsCgiResult(200, unauthBody('016227'));
      expect(r, isA<PostNeedsAuth>());
      r as PostNeedsAuth;
      expect(r.authCode, '016227');
      expect(r.authUrl.toString(), 'https://bbs.eddibb.cc/auth-code');
    });

    test('未認証: authentication required の URL-only 応答を取り出す', () {
      final r = parseBbsCgiResult(200, authUrlOnlyBody());
      expect(r, isA<PostNeedsAuth>());
      r as PostNeedsAuth;
      expect(r.authCode, isEmpty);
      expect(
        r.authUrl.toString(),
        'https://bbs.punipuni.eu/auth-code?token=abc',
      );
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

    test('その他エラー: doctype とコメントはメッセージから除く', () {
      final r = parseBbsCgiResult(200, legacyErrorBody());
      expect(r, isA<PostRejected>());
      final message = (r as PostRejected).message;
      expect(message, contains('書き込みに必要なレベル'));
      expect(message, isNot(contains('DOCTYPE')));
      expect(message, isNot(contains('2ch_X')));
      expect(message, isNot(contains('nobanner')));
    });

    test('3xx（landing へのリダイレクト）は Redirect エラーにする', () {
      final r = parseBbsCgiResult(302, sjis('<html>Found</html>'));
      expect(r, isA<PostRejected>());
      expect((r as PostRejected).errorCode, 'Redirect');
    });

    test('5ch 書き込み確認（2ch_X:cookie）は PostNeedsConfirm', () {
      final r = parseBbsCgiResult(200, confirmBody5ch());
      expect(r, isA<PostNeedsConfirm>());
      final fields = (r as PostNeedsConfirm).hiddenFields;
      expect(fields['bbs'], 'news4vip');
      expect(fields['key'], '1700000000');
      expect(fields['hash'], 'abc123');
      // HTML エンティティは復号される。
      expect(fields['MESSAGE'], '<test>');
      // submit（type=submit）は hidden ではないので拾わない。
      expect(fields.containsKey('submit'), isFalse);
    });
  });

  group('extractHiddenFields', () {
    test('属性順・引用符の揺れに耐える', () {
      final fields = extractHiddenFields(
        "<input value='v1' type='hidden' name='a'>"
        '<input name="b" type="hidden" value="x&amp;y">'
        '<input type=hidden name=c value=z>',
      );
      expect(fields['a'], 'v1');
      expect(fields['b'], 'x&y');
      expect(fields['c'], 'z');
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
        tokens: AuthTokens.eddist(edgeToken: 'E1', tinkerToken: 'T1'),
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

  group('BbsWriter 5ch 二段階 POST', () {
    final bbs5ch = Uri.parse('https://mi.5ch.io/test/bbs.cgi');
    const referer = 'https://mi.5ch.io/test/read.cgi/news4vip/1700000000/';

    test('確認ページを受けたら hidden を詰め直して自動再送し成功する', () async {
      final poster = QueuePoster([
        // Phase1: 確認ページ＋ MonaTicket 発行。
        FetchResponse(
          statusCode: 200,
          bodyBytes: confirmBody5ch(),
          setCookies: const ['MonaTicket=planted.jwt; Path=/; Max-Age=8640000'],
        ),
        // Phase2: 成功。
        FetchResponse(statusCode: 200, bodyBytes: success5ch()),
      ]);

      final result = await BbsWriter(poster).post(
        bbsCgi: bbs5ch,
        board: 'news4vip',
        threadKey: '1700000000',
        message: '<test>',
        referer: referer,
      );

      expect(result.outcome, isA<PostAccepted>());
      expect(poster.calls, hasLength(2));

      // 両フェーズで Referer を送る。
      expect(poster.calls[0].headers['Referer'], referer);
      expect(poster.calls[1].headers['Referer'], referer);

      // Phase1 で発行された MonaTicket を Phase2 の Cookie で送り返す。
      expect(
        poster.calls[1].headers['Cookie'],
        contains('MonaTicket=planted.jwt'),
      );

      // Phase2 の body は承諾 submit ＋ hidden 詰め直し。
      final body2 = poster.calls[1].body;
      expect(body2, contains('bbs=news4vip'));
      expect(body2, contains('key=1700000000'));
      expect(body2, contains('hash=abc123'));
      expect(
        body2,
        isNot(contains('submit=%8F%91%82%AB%8D%9E%82%DE')),
      ); // 「書き込む」ではない

      // MonaTicket が保持される。
      expect(result.tokens['MonaTicket'], 'planted.jwt');
    });

    test('確認が 2 回続いても無限ループせず結果を返す', () async {
      final poster = QueuePoster([
        FetchResponse(statusCode: 200, bodyBytes: confirmBody5ch()),
        FetchResponse(statusCode: 200, bodyBytes: confirmBody5ch()),
      ]);
      final result = await BbsWriter(poster).post(
        bbsCgi: bbs5ch,
        board: 'news4vip',
        threadKey: '1700000000',
        message: 'x',
        referer: referer,
      );
      // 2 回で打ち切り、最後の確認結果をそのまま返す（成功にはならない）。
      expect(poster.calls, hasLength(2));
      expect(result.outcome, isA<PostNeedsConfirm>());
    });
  });

  group('したらば（write.cgi）', () {
    final writeCgi = Uri.parse(
      'https://jbbs.shitaraba.net/bbs/write.cgi/otaku/18550/1700000000/',
    );

    test('レスの body は大文字フィールド・EUC-JP', () {
      final body = buildShitarabaBody(
        dir: 'otaku',
        bbs: '18550',
        threadKey: '1700000000',
        message: 'みんないる',
        time: '1700000001',
      );
      expect(
        body,
        'submit=%BD%F1%A4%AD%B9%FE%A4%E0&NAME=&MAIL=&'
        'MESSAGE=%A4%DF%A4%F3%A4%CA%A4%A4%A4%EB&'
        'DIR=otaku&BBS=18550&KEY=1700000000&TIME=1700000001',
      );
    });

    test('スレ立ての body は SUBJECT を持ち KEY を持たない', () {
      final body = buildShitarabaThreadBody(
        dir: 'otaku',
        bbs: '18550',
        title: 'テストスレ',
        message: '本文',
        time: '1700000001',
      );
      expect(
        body,
        'submit=%BF%B7%B5%AC%BD%F1%A4%AD%B9%FE%A4%DF&'
        'SUBJECT=%A5%C6%A5%B9%A5%C8%A5%B9%A5%EC&NAME=&MAIL=&'
        'MESSAGE=%CB%DC%CA%B8&DIR=otaku&BBS=18550&TIME=1700000001',
      );
      expect(body, isNot(contains('KEY=')));
    });

    test('EUC-JP に無い文字は数値文字参照になる', () {
      final body = buildShitarabaBody(
        dir: 'otaku',
        bbs: '18550',
        threadKey: '1',
        message: '🍣',
      );
      expect(body, contains('MESSAGE=%26%23127843%3B'));
    });

    test('BbsWriter が板キーを DIR / BBS に割る', () async {
      final poster = FakePoster(
        FetchResponse(statusCode: 200, bodyBytes: shitarabaSuccessBody()),
      );
      final result = await BbsWriter(poster, dialect: BbsDialect.shitaraba)
          .post(
            bbsCgi: writeCgi,
            board: 'otaku/18550',
            threadKey: '1700000000',
            message: 'x',
            time: '1700000001',
          );
      expect(result.outcome, isA<PostAccepted>());
      expect(poster.url, writeCgi);
      expect(poster.body, contains('DIR=otaku'));
      expect(poster.body, contains('BBS=18550'));
      expect(poster.body, contains('KEY=1700000000'));
    });

    test('スレ立ても板キーを割る', () async {
      final poster = FakePoster(
        FetchResponse(statusCode: 200, bodyBytes: shitarabaSuccessBody()),
      );
      await BbsWriter(poster, dialect: BbsDialect.shitaraba).createThread(
        bbsCgi: Uri.parse(
          'https://jbbs.shitaraba.net/bbs/write.cgi/otaku/18550/new/',
        ),
        board: 'otaku/18550',
        title: 't',
        message: 'm',
      );
      expect(poster.body, contains('DIR=otaku'));
      expect(poster.body, contains('BBS=18550'));
      expect(poster.body, isNot(contains('KEY=')));
    });

    test('EUC-JP のエラーページを化けずに読む', () {
      final r = parseBbsCgiResult(
        404,
        shitarabaErrorBody('該当スレッドは存在しません'),
        encoding: BbsTextEncoding.eucJp,
      );
      expect(r, isA<PostRejected>());
      final message = (r as PostRejected).message;
      expect(message, '該当スレッドは存在しません');
    });

    test('SJIS として読むと化けるので encoding を渡し忘れない', () {
      final r = parseBbsCgiResult(404, shitarabaErrorBody('該当スレッドは存在しません'));
      expect((r as PostRejected).message, isNot(contains('該当スレッド')));
    });
  });
}
