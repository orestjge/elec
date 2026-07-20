import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

abstract interface class ImageUploader {
  bool get configured;
  Future<Uri> upload(XFile file);
}

/// Imgur の匿名アップロード API へ画像を投稿する。
class ImgurUploader implements ImageUploader {
  const ImgurUploader({
    required this.clientId,
    http.Client? client,
    this.endpoint = const String.fromEnvironment(
      'IMGUR_UPLOAD_ENDPOINT',
      defaultValue: 'https://api.imgur.com/3/image',
    ),
  }) : _client = client;

  /// Imgur API の Client-ID。通常は
  /// `--dart-define=IMGUR_CLIENT_ID=...` で渡す。
  final String clientId;
  final String endpoint;
  final http.Client? _client;

  @override
  bool get configured => clientId.trim().isNotEmpty;

  @override
  Future<Uri> upload(XFile file) async {
    if (!configured) {
      throw const ImgurUploadException('Imgur Client ID が設定されていません');
    }

    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final bytes = await file.readAsBytes();
      final req = http.MultipartRequest('POST', Uri.parse(endpoint))
        ..headers['Authorization'] = 'Client-ID ${clientId.trim()}'
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            bytes,
            filename: file.name.isEmpty ? 'image' : file.name,
          ),
        );
      final streamed = await client.send(req);
      final resp = await http.Response.fromStream(streamed);
      final decoded = jsonDecode(resp.body);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ImgurUploadException(_errorMessage(decoded, resp.statusCode));
      }
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        throw ImgurUploadException(_errorMessage(decoded, resp.statusCode));
      }
      final data = decoded['data'];
      final link = data is Map<String, dynamic> ? data['link'] : null;
      if (link is! String || link.isEmpty) {
        throw const ImgurUploadException('Imgur の応答に画像URLがありません');
      }
      return Uri.parse(link);
    } on ImgurUploadException {
      rethrow;
    } catch (e) {
      throw ImgurUploadException('画像アップロードに失敗しました: $e');
    } finally {
      if (shouldClose) client.close();
    }
  }

  static String _errorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is Map<String, dynamic>) {
        final error = data['error'];
        if (error is String && error.isNotEmpty) return error;
      }
      final error = decoded['error'];
      if (error is String && error.isNotEmpty) return error;
    }
    return 'Imgur がアップロードを拒否しました ($statusCode)';
  }
}

class ImgBbUploader implements ImageUploader {
  const ImgBbUploader({
    required this.apiKey,
    http.Client? client,
    this.endpoint = const String.fromEnvironment(
      'IMGBB_UPLOAD_ENDPOINT',
      defaultValue: 'https://api.imgbb.com/1/upload',
    ),
  }) : _client = client;

  final String apiKey;
  final String endpoint;
  final http.Client? _client;

  @override
  bool get configured => apiKey.trim().isNotEmpty;

  @override
  Future<Uri> upload(XFile file) async {
    if (!configured) {
      throw const ImgurUploadException('ImgBB API Key が設定されていません');
    }

    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final bytes = await file.readAsBytes();
      final req = http.MultipartRequest('POST', Uri.parse(endpoint))
        ..fields['key'] = apiKey.trim()
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            bytes,
            filename: file.name.isEmpty ? 'image' : file.name,
          ),
        );
      final streamed = await client.send(req);
      final resp = await http.Response.fromStream(streamed);
      final decoded = jsonDecode(resp.body);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ImgurUploadException(
          _imgbbErrorMessage(decoded, resp.statusCode),
        );
      }
      final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
      final url = data is Map<String, dynamic> ? data['url'] : null;
      if (url is! String || url.isEmpty) {
        throw const ImgurUploadException('ImgBB の応答に画像URLがありません');
      }
      return Uri.parse(url);
    } on ImgurUploadException {
      rethrow;
    } catch (e) {
      throw ImgurUploadException('画像アップロードに失敗しました: $e');
    } finally {
      if (shouldClose) client.close();
    }
  }

  static String _imgbbErrorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    }
    return 'ImgBB がアップロードを拒否しました ($statusCode)';
  }
}

class ImgurUploadException implements Exception {
  const ImgurUploadException(this.message);
  final String message;

  @override
  String toString() => message;
}
