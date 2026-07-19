import 'package:edge_core/edge_core.dart';

import 'token_storage.dart';

/// 書き込み用トークン（edge-token / tinker-token）の保管。
///
/// [TokenStorage] に永続化する。tinker-token を毎回持ち回さないと level が
/// 上がらないので、永続化は書き込み体験に直結する。
class AuthStore {
  AuthStore(this._storage);

  /// アプリ全体で共有するインスタンス。トークンは板/スレをまたいで共有する。
  /// 起動時に [load] を呼ぶこと（`main`）。
  static final AuthStore shared = AuthStore(FileTokenStorage());

  final TokenStorage _storage;

  AuthTokens _tokens = AuthTokens.none;
  AuthTokens get tokens => _tokens;

  bool get isAuthenticated => _tokens.hasEdgeToken;

  /// 保存済みトークンを読み込む。起動時に一度呼ぶ。
  Future<void> load() async {
    _tokens = await _storage.load();
  }

  /// トークンを更新して永続化する。
  Future<void> setTokens(AuthTokens tokens) async {
    _tokens = tokens;
    await _storage.save(tokens);
  }

  /// 認証を破棄する（ログアウト相当）。
  Future<void> clear() async {
    _tokens = AuthTokens.none;
    await _storage.clear();
  }
}
