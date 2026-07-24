import 'package:edge_core/edge_core.dart';

import 'board.dart';
import 'token_storage.dart';

/// 書き込み用 Cookie（edge/tinker・MonaTicket 等）の保管。**ホスト単位**。
///
/// eddist は edge-token/tinker-token、5ch は MonaTicket（どんぐり）を使うが、
/// いずれも「サーバの Set-Cookie を保存して毎回送り返す」だけ。ホストをまたいで
/// Cookie を送らないよう、ホストごとに [AuthTokens] を持つ。tinker-token を毎回
/// 持ち回さないと level が上がらないので、永続化は書き込み体験に直結する。
class AuthStore {
  AuthStore(this._storage);

  /// アプリ全体で共有するインスタンス。起動時に [load] を呼ぶこと（`main`）。
  static final AuthStore shared = AuthStore(FileTokenStorage());

  final TokenStorage _storage;

  final Map<String, AuthTokens> _byHost = {};

  /// 保存済み Cookie を読み込む。起動時に一度呼ぶ。
  Future<void> load() async {
    _byHost
      ..clear()
      ..addAll(await _storage.load());
  }

  /// [host] の Cookie。無ければ空。
  AuthTokens tokensFor(String host) => _byHost[host] ?? AuthTokens.none;

  /// [host] の Cookie を更新して永続化する。
  Future<void> setTokensFor(String host, AuthTokens tokens) async {
    _byHost[host] = tokens;
    await _storage.save(_byHost);
  }

  /// エッヂ（既定ホスト）の Cookie。旧 API 互換。
  AuthTokens get tokens => tokensFor(Board.eddibbHost);

  /// エッヂ（既定ホスト）が認証済みか。旧 API 互換。
  bool get isAuthenticated => tokens.hasEdgeToken;

  /// エッヂ（既定ホスト）の Cookie を更新する。旧 API 互換。
  Future<void> setTokens(AuthTokens tokens) =>
      setTokensFor(Board.eddibbHost, tokens);

  /// すべてのホストの認証を破棄する（ログアウト相当）。
  Future<void> clear() async {
    _byHost.clear();
    await _storage.clear();
  }
}
