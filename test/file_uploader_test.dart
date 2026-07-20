import 'dart:convert';
import 'dart:typed_data';

import 'package:elec/src/net/file_uploader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  group('CatboxUploader', () {
    test('本文の URL をそのまま返す', () async {
      late http.BaseRequest captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('https://files.catbox.moe/abc.zip\n', 200);
      });
      final uploader = CatboxUploader(client: client);

      final url = await uploader.upload(bytes: bytes, filename: 'a.zip');

      expect(url.toString(), 'https://files.catbox.moe/abc.zip');
      expect(captured.method, 'POST');
    });

    test('URL でない応答は例外にする', () async {
      final client = MockClient(
        (_) async => http.Response('something went wrong', 200),
      );
      final uploader = CatboxUploader(client: client);

      expect(
        () => uploader.upload(bytes: bytes, filename: 'a.zip'),
        throwsA(isA<FileUploadException>()),
      );
    });

    test('非 2xx はエラー本文を含めて例外にする', () async {
      final client = MockClient((_) async => http.Response('too big', 412));
      final uploader = CatboxUploader(client: client);

      expect(
        () => uploader.upload(bytes: bytes, filename: 'a.zip'),
        throwsA(
          isA<FileUploadException>().having(
            (e) => e.message,
            'message',
            contains('too big'),
          ),
        ),
      );
    });
  });

  group('UguuUploader', () {
    test('JSON から最初のファイル URL を取り出す', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'success': true,
            'files': [
              {'url': 'https://a.uguu.se/xyz.zip', 'name': 'xyz.zip'},
            ],
          }),
          200,
        ),
      );
      final uploader = UguuUploader(client: client);

      final url = await uploader.upload(bytes: bytes, filename: 'a.zip');

      expect(url.toString(), 'https://a.uguu.se/xyz.zip');
    });

    test('success=false は description を例外メッセージにする', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'success': false,
            'errorcode': 415,
            'description': 'File blacklisted.',
          }),
          415,
        ),
      );
      final uploader = UguuUploader(client: client);

      expect(
        () => uploader.upload(bytes: bytes, filename: 'a.zip'),
        throwsA(
          isA<FileUploadException>().having(
            (e) => e.message,
            'message',
            contains('File blacklisted.'),
          ),
        ),
      );
    });
  });
}
