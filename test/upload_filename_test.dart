import 'package:elec/src/net/upload_filename.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('randomizedUploadFilename', () {
    test('元のファイル名は残さず拡張子だけ維持する', () {
      final name = randomizedUploadFilename('IMG_0001.JPG');
      expect(name, endsWith('.jpg'));
      expect(name.toLowerCase(), isNot(contains('img_0001')));
    });

    test('呼ぶたびに異なる名前になる', () {
      final a = randomizedUploadFilename('photo.png');
      final b = randomizedUploadFilename('photo.png');
      expect(a, isNot(equals(b)));
      expect(a, endsWith('.png'));
      expect(b, endsWith('.png'));
    });

    test('拡張子がなければ付けない', () {
      final name = randomizedUploadFilename('screenshot');
      expect(name, isNot(contains('.')));
      expect(name, isNotEmpty);
    });

    test('拡張子らしくない末尾は拡張子として扱わない', () {
      // ドット以降が長すぎる / 記号を含む場合は拡張子として採用しない。
      expect(
        randomizedUploadFilename('my.secret.location'),
        isNot(contains('.')),
      );
      expect(randomizedUploadFilename('file.'), isNot(contains('.')));
    });
  });
}
