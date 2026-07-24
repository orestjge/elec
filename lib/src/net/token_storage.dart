import 'dart:convert';
import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:path_provider/path_provider.dart';

import 'board.dart';

/// 書き込み Cookie（ホスト単位）の保存先の抽象。
///
/// eddist は edge/tinker、5ch は MonaTicket（どんぐり）等を、**ホストごと**に
/// 保持する。いまは平文 JSON ファイル（[FileTokenStorage]）。認証情報なので将来は
/// OS のセキュアストレージ（Keychain / KeyStore）に差し替えたい。その差し替えが
/// この 1 箇所で済むよう抽象化しておく。
abstract interface class TokenStorage {
  Future<Map<String, AuthTokens>> load();
  Future<void> save(Map<String, AuthTokens> byHost);
  Future<void> clear();
}

/// アプリのサポートディレクトリに JSON で保存する実装。
///
/// 形式は `{host: {cookieName: value}}`。**平文**。ローカル端末内なので当面は
/// 許容するが、セキュアストレージへの移行が望ましい（TODO）。
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
  Future<Map<String, AuthTokens>> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return {};
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return {};
      // 旧形式（単一の {edge, tinker}）はエッヂのホストに移行する。
      if (json.containsKey('edge') || json.containsKey('tinker')) {
        return {Board.eddibbHost: AuthTokens.fromJson(json)};
      }
      final result = <String, AuthTokens>{};
      json.forEach((host, value) {
        if (value is Map<String, dynamic>) {
          result[host] = AuthTokens.fromJson(value);
        }
      });
      return result;
    } catch (_) {
      // 壊れていたら未認証扱いで続行する。
      return {};
    }
  }

  @override
  Future<void> save(Map<String, AuthTokens> byHost) async {
    final file = await _file();
    final json = <String, dynamic>{};
    byHost.forEach((host, tokens) {
      if (!tokens.isEmpty) json[host] = tokens.toJson();
    });
    await file.writeAsString(jsonEncode(json));
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (file.existsSync()) await file.delete();
  }
}

/// メモリ保持のみ（テスト・一時利用）。
class MemoryTokenStorage implements TokenStorage {
  MemoryTokenStorage([Map<String, AuthTokens>? initial])
    : _byHost = {...?initial};
  Map<String, AuthTokens> _byHost;

  @override
  Future<Map<String, AuthTokens>> load() async => Map.of(_byHost);

  @override
  Future<void> save(Map<String, AuthTokens> byHost) async =>
      _byHost = Map.of(byHost);

  @override
  Future<void> clear() async => _byHost = {};
}
