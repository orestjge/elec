import 'dart:typed_data';

import 'package:elec/src/net/image_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  // "Exif" のマーカー識別子。
  const exifTag = [0x45, 0x78, 0x69, 0x66];
  // APP0 の "JFIF" 識別子。
  const jfifTag = [0x4A, 0x46, 0x49, 0x46];

  final jpeg = Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x06, ...jfifTag, // APP0(JFIF)
    0xFF, 0xE1, 0x00, 0x08, ...exifTag, 0x00, 0x00, // APP1(Exif)
    0xFF, 0xDA, 0x00, 0x03, 0x01, // SOS
    0x12, 0x34, 0x56, // 画像データ
    0xFF, 0xD9, // EOI
  ]);

  test('JPEG の Exif(APP1) を取り除く', () {
    final out = stripImageMetadata(jpeg);
    expect(_contains(out, exifTag), isFalse, reason: 'Exif が残っている');
    // APP0 と画像データ・両端のマーカーは維持する。
    expect(_contains(out, jfifTag), isTrue);
    expect(_contains(out, [0x12, 0x34, 0x56]), isTrue);
    expect(out.sublist(0, 2), [0xFF, 0xD8]);
    expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
    expect(out.length, lessThan(jpeg.length));
  });

  test('JPEG でない入力はそのまま返す', () {
    // PNG シグネチャ。
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x01,
      0x02,
    ]);
    expect(stripImageMetadata(png), png);
  });

  test('短すぎる入力でも落ちない', () {
    final tiny = Uint8List.fromList([0xFF, 0xD8]);
    expect(stripImageMetadata(tiny), tiny);
  });
}
