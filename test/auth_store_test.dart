import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/auth_store.dart';
import 'package:elec/src/net/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthStore + MemoryTokenStorage', () {
    test('setTokens で保持し isAuthenticated が立つ', () async {
      final store = AuthStore(MemoryTokenStorage());
      expect(store.isAuthenticated, isFalse);
      await store.setTokens(
        AuthTokens.eddist(edgeToken: 'E', tinkerToken: 'T'),
      );
      expect(store.isAuthenticated, isTrue);
      expect(store.tokens.edgeToken, 'E');
    });

    test('clear で破棄する', () async {
      final store = AuthStore(MemoryTokenStorage());
      await store.setTokens(AuthTokens.eddist(edgeToken: 'E'));
      await store.clear();
      expect(store.isAuthenticated, isFalse);
    });

    test('ホスト単位で Cookie を分けて保持する', () async {
      final store = AuthStore(MemoryTokenStorage());
      await store.setTokensFor(
        'mi.5ch.io',
        AuthTokens.none.updatedFrom(['MonaTicket=abc']),
      );
      await store.setTokensFor(
        'bbs.eddibb.cc',
        AuthTokens.eddist(edgeToken: 'E'),
      );
      // 別ホストの Cookie は混ざらない。
      expect(store.tokensFor('mi.5ch.io')['MonaTicket'], 'abc');
      expect(store.tokensFor('mi.5ch.io').edgeToken, isNull);
      expect(store.tokensFor('bbs.eddibb.cc').edgeToken, 'E');
      expect(store.tokensFor('nova.5ch.io').isEmpty, isTrue);
    });
  });

  group('FileTokenStorage 永続化（一時ディレクトリ）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('elec_tok'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('保存 → 別インスタンスで読み込めて一致する', () async {
      final a = AuthStore(FileTokenStorage(directory: dir));
      await a.setTokens(
        AuthTokens.eddist(edgeToken: 'edge1', tinkerToken: 'jwt1'),
      );

      // 「再起動」を模して別ストアで読み直す。
      final b = AuthStore(FileTokenStorage(directory: dir));
      await b.load();
      expect(b.tokens.edgeToken, 'edge1');
      expect(b.tokens.tinkerToken, 'jwt1');
    });

    test('未保存なら未認証で読み込む', () async {
      final store = AuthStore(FileTokenStorage(directory: dir));
      await store.load();
      expect(store.isAuthenticated, isFalse);
    });

    test('clear 後は読み込んでも未認証', () async {
      final storage = FileTokenStorage(directory: dir);
      final a = AuthStore(storage);
      await a.setTokens(AuthTokens.eddist(edgeToken: 'x'));
      await a.clear();

      final b = AuthStore(FileTokenStorage(directory: dir));
      await b.load();
      expect(b.isAuthenticated, isFalse);
    });

    test('旧形式 {edge, tinker} のファイルを移行して読む', () async {
      // 旧バージョンが書いた単一トークンファイルを用意する。
      File(
        '${dir.path}/elec_auth_tokens.json',
      ).writeAsStringSync('{"edge":"oldedge","tinker":"oldtinker"}');
      final store = AuthStore(FileTokenStorage(directory: dir));
      await store.load();
      // エッヂのホストの Cookie として復元される。
      expect(store.tokens.edgeToken, 'oldedge');
      expect(store.tokens.tinkerToken, 'oldtinker');
    });
  });
}
