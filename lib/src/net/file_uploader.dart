import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 任意ファイルを外部のアップロードサービスへ投稿する。
///
/// 画像専用の [ImageUploader] とは別系統。返り値は共有可能な URL。
abstract interface class FileUploader {
  Future<Uri> upload({required Uint8List bytes, required String filename});
}

/// catbox.moe の匿名アップロード API へファイルを投稿する。
///
/// 保存は永続的で、成功時のレスポンスは本文にファイル URL が 1 行入る
/// プレーンテキスト。
class CatboxUploader implements FileUploader {
  const CatboxUploader({
    http.Client? client,
    this.endpoint = const String.fromEnvironment(
      'CATBOX_UPLOAD_ENDPOINT',
      defaultValue: 'https://catbox.moe/user/api.php',
    ),
  }) : _client = client;

  final String endpoint;
  final http.Client? _client;

  @override
  Future<Uri> upload({
    required Uint8List bytes,
    required String filename,
  }) async {
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final req = http.MultipartRequest('POST', Uri.parse(endpoint))
        ..fields['reqtype'] = 'fileupload'
        ..files.add(
          http.MultipartFile.fromBytes(
            'fileToUpload',
            bytes,
            filename: filename.isEmpty ? 'file' : filename,
          ),
        );
      final streamed = await client.send(req);
      final resp = await http.Response.fromStream(streamed);
      final body = resp.body.trim();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw FileUploadException(
          body.isNotEmpty
              ? 'catbox がアップロードを拒否しました: $body'
              : 'catbox がアップロードを拒否しました (${resp.statusCode})',
        );
      }
      final url = Uri.tryParse(body);
      if (body.isEmpty || url == null || !url.isAbsolute) {
        throw FileUploadException('catbox の応答が URL ではありません: $body');
      }
      return url;
    } on FileUploadException {
      rethrow;
    } catch (e) {
      throw FileUploadException('ファイルのアップロードに失敗しました: $e');
    } finally {
      if (shouldClose) client.close();
    }
  }
}

/// uguu.se の匿名アップロード API へファイルを投稿する。
///
/// 保存は一時的（数時間〜数日で消える）。成功時のレスポンスは
/// `{"success":true,"files":[{"url":...}]}` の JSON。
class UguuUploader implements FileUploader {
  const UguuUploader({
    http.Client? client,
    this.endpoint = const String.fromEnvironment(
      'UGUU_UPLOAD_ENDPOINT',
      defaultValue: 'https://uguu.se/upload',
    ),
  }) : _client = client;

  final String endpoint;
  final http.Client? _client;

  @override
  Future<Uri> upload({
    required Uint8List bytes,
    required String filename,
  }) async {
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final req = http.MultipartRequest('POST', Uri.parse(endpoint))
        ..files.add(
          http.MultipartFile.fromBytes(
            'files[]',
            bytes,
            filename: filename.isEmpty ? 'file' : filename,
          ),
        );
      final streamed = await client.send(req);
      final resp = await http.Response.fromStream(streamed);
      final decoded = jsonDecode(resp.body);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw FileUploadException(_errorMessage(decoded, resp.statusCode));
      }
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        throw FileUploadException(_errorMessage(decoded, resp.statusCode));
      }
      final files = decoded['files'];
      final first = files is List && files.isNotEmpty ? files.first : null;
      final url = first is Map<String, dynamic> ? first['url'] : null;
      if (url is! String || url.isEmpty) {
        throw const FileUploadException('uguu の応答にファイル URL がありません');
      }
      return Uri.parse(url);
    } on FileUploadException {
      rethrow;
    } catch (e) {
      throw FileUploadException('ファイルのアップロードに失敗しました: $e');
    } finally {
      if (shouldClose) client.close();
    }
  }

  static String _errorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<String, dynamic>) {
      final description = decoded['description'];
      if (description is String && description.isNotEmpty) return description;
    }
    return 'uguu がアップロードを拒否しました ($statusCode)';
  }
}

class FileUploadException implements Exception {
  const FileUploadException(this.message);
  final String message;

  @override
  String toString() => message;
}
