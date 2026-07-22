import 'dart:typed_data';

/// 画像バイト列から位置情報などのメタデータを取り除く。
///
/// スマホで撮った写真の JPEG には GPS 位置・端末名・撮影日時などの Exif が
/// 埋め込まれていることが多い。アップロード先（特に ImgBB）はこれを残す・表示
/// することがあるため、送信前に落とす。
///
/// JPEG は APP0(JFIF) だけ残して APP1〜APP15（Exif / XMP / IPTC 等）と COM を
/// 取り除く。再エンコードはせず画素はそのまま維持する。JPEG 以外や壊れた入力は
/// そのまま返す（判別できないものを無理に触らない）。
Uint8List stripImageMetadata(Uint8List bytes) {
  if (!_isJpeg(bytes)) return bytes;
  try {
    return _stripJpegMetadata(bytes);
  } catch (_) {
    // 想定外の構造なら安全側に倒して原本を返す。
    return bytes;
  }
}

bool _isJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

Uint8List _stripJpegMetadata(Uint8List bytes) {
  final out = BytesBuilder();
  // SOI
  out.add([0xFF, 0xD8]);
  var i = 2;
  while (i + 1 < bytes.length) {
    if (bytes[i] != 0xFF) {
      // マーカー境界が壊れている。以降をそのままつなげて終了。
      out.add(Uint8List.sublistView(bytes, i));
      return out.toBytes();
    }
    final marker = bytes[i + 1];

    // SOS（画像データ開始）以降は末尾までそのまま。
    if (marker == 0xDA) {
      out.add(Uint8List.sublistView(bytes, i));
      return out.toBytes();
    }

    // 長さを持たないスタンドアロンマーカー（RSTn / EOI など）。
    if (marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add([0xFF, marker]);
      i += 2;
      continue;
    }

    if (i + 3 >= bytes.length) {
      out.add(Uint8List.sublistView(bytes, i));
      return out.toBytes();
    }
    final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
    final segEnd = i + 2 + segLen;
    if (segLen < 2 || segEnd > bytes.length) {
      // 長さが不正。以降をそのまま残す。
      out.add(Uint8List.sublistView(bytes, i));
      return out.toBytes();
    }

    // APP1〜APP15（Exif/XMP/IPTC 等）と COM は落とす。APP0(JFIF) は残す。
    final isMetadata = (marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE;
    if (!isMetadata) {
      out.add(Uint8List.sublistView(bytes, i, segEnd));
    }
    i = segEnd;
  }
  return out.toBytes();
}
