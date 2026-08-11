/// 画像バイト列の**先頭だけを読んで原寸を知る**。
///
/// 動画の 1 フレームを切り出したサムネイル（`video_thumbnail.dart`）を、元の
/// 映像の形で出すために要る。デコードすれば分かることではあるけれど、デコード
/// は非同期で、**結果が返るのは組み立てが済んだ後**——先に正方形で並べてから
/// 形が決まることになり、そのぶん下のレスが動く。原寸はヘッダに書いてあるので、
/// そこだけ読めば組み立てのその場で分かる。
///
/// 読めるのは JPEG と PNG。サムネイル生成は JPEG を返す（プラグインも macOS の
/// メソッドチャンネルも）ので実際には JPEG だけで足りるが、PNG も数行なので
/// 一緒に見る。判別できないものは null——呼び手は正方形へ倒す。
library;

import 'dart:typed_data';
import 'dart:ui' show Size;

/// [bytes] の原寸。分からなければ null。
Size? imageSizeFromHeader(Uint8List bytes) {
  return _pngSize(bytes) ?? _jpegSize(bytes);
}

/// PNG は固定位置。8 バイトの署名 → 長さ(4) → `IHDR`(4) → 幅(4) → 高さ(4)。
Size? _pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  final width = _uint32(bytes, 16);
  final height = _uint32(bytes, 20);
  if (width <= 0 || height <= 0) return null;
  return Size(width.toDouble(), height.toDouble());
}

/// JPEG はマーカーを順に辿り、**SOF**（フレーム開始）に行き当たったら、そこに
/// 書かれている高さ・幅を読む。
///
/// SOF は種類が多い（SOF0 のベースラインから SOF15 まで）。ただし同じ 0xC0 台
/// でも DHT(0xC4)・JPG(0xC8)・DAC(0xCC) は寸法を持たないので外す。
Size? _jpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < bytes.length) {
    // マーカーの前に 0xFF の詰め物が並ぶことがある。
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // 長さを持たないマーカー（RST0〜7・SOI・EOI・TEM）。
    if (marker == 0x01 ||
        marker == 0xD8 ||
        marker == 0xD9 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      // 区画は 長さ(2) → 精度(1) → 高さ(2) → 幅(2)。
      if (i + 9 >= bytes.length) return null;
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width <= 0 || height <= 0) return null;
      return Size(width.toDouble(), height.toDouble());
    }
    // SOS（画像データ開始）まで来たら、以降にヘッダは無い。
    if (marker == 0xDA) return null;
    i += 2 + length;
  }
  return null;
}

int _uint32(Uint8List bytes, int at) =>
    (bytes[at] << 24) |
    (bytes[at + 1] << 16) |
    (bytes[at + 2] << 8) |
    bytes[at + 3];
