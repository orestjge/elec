import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:path_provider/path_provider.dart';

/// 書き込みトークンの保存先の抽象。
///
/// いまは平文 JSON ファイル（[FileTokenStorage]）。トークンは認証情報なので、
/// 将来は OS のセキュアストレージ（Keychain / KeyStore）に差し替えたい。
/// その差し替えがこの 1 箇所で済むよう抽象化しておく。
abstract interface class TokenStorage {
  Future<AuthTokens> load();
  Future<void> save(AuthTokens tokens);
  Future<void> clear();
}

/// アプリのサポートディレクトリに JSON で保存する実装。
///
/// **平文**。ローカル端末内なので当面は許容するが、セキュアストレージへの
/// 移行が望ましい（TODO）。
class FileTokenStorage implements TokenStorage {
  /// [directory] を渡すとその場所に保存する（テスト用）。省略時は
  /// `getApplicationSupportDirectory()`。
  FileTokenStorage({Directory? directory}) : _override = directory;

  final Directory? _override;
  static const _fileName = 'elec_auth_tokens.json';

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<AuthTokens> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return AuthTokens.none;
      final json = jsonDecode(await file.readAsString());
      return AuthTokens.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      // 壊れていたら未認証扱いで続行する。
      return AuthTokens.none;
    }
  }

  @override
  Future<void> save(AuthTokens tokens) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(tokens.toJson()));
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (file.existsSync()) await file.delete();
  }
}

/// メモリ保持のみ（テスト・一時利用）。
class MemoryTokenStorage implements TokenStorage {
  AuthTokens _tokens;
  MemoryTokenStorage([this._tokens = AuthTokens.none]);

  @override
  Future<AuthTokens> load() async => _tokens;

  @override
  Future<void> save(AuthTokens tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = AuthTokens.none;
}
