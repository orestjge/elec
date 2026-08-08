/// 画像そのものを見分けるための指紋。NG 画像の判定に使う。
///
/// 同じ画像が貼り直されても URL は毎回変わるので、URL では追えない。中身から
/// 2 種類の指紋を採る。
///
///  1. **SHA-256**（完全一致）。ファイルがそのまま貼り直されたときに効く。
///     取りこぼしは無いが、1 バイトでも変われば当たらない。
///  2. **dHash**（近似一致）。17×16 に潰したグレースケールで、横に隣り合う画素の
///     明暗を 256 ビットへ畳む。再エンコード・リサイズ・軽い加工では値がほとんど
///     変わらないので、ハミング距離で「同じ絵」を拾える。
///
/// ビット数は多めに採ってある。よく使われる 64 ビット（9×8）だと、実測で
/// 「同じ絵を 1/4 に縮めたもの」が 0、「別の絵」が 5 と、差が開かない。256 ビット
/// なら同じ組が 2 と 26 になり、閾値を置ける余地ができる。
///
/// dHash には 2 つ弱点がある。**のっぺりした画像では意味を持たない**（単色に近い
/// ものは互いに似た値になり、無関係な画像まで巻き込む）ので、起伏の乏しいものは
/// dHash を採らず完全一致だけで判定する。もう 1 つ、明暗しか見ないので**構図が
/// 同じで色だけ違う画像**は見分けられない。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// dHash の一辺。横は隣との比較を採るので +1 する。
const int _hashWidth = 17;
const int _hashHeight = 16;

/// dHash のビット数。
const int imageHashBits = (_hashWidth - 1) * _hashHeight;

/// これより起伏が小さい画像は dHash を採らない（0〜255 の標準偏差）。
const double _flatThreshold = 3;

/// これを超える大きさは別スレッドで SHA-256 を採る。小さいものは、別スレッドを
/// 起こす方が高くつく。
const int _isolateThreshold = 512 << 10;

/// 画像 1 枚の指紋。
@immutable
class ImageFingerprint {
  const ImageFingerprint({required this.sha256, this.dhash});

  /// 本文の SHA-256（16 進 64 文字）。完全一致の判定に使う。
  final String sha256;

  /// dHash（[imageHashBits] ビットを詰めた列）。のっぺりした画像や、
  /// デコードできなかったものは null。
  final Uint8List? dhash;

  /// [other] との近さ。どちらかが dHash を持たないなら null。
  int? distanceTo(ImageFingerprint other) {
    final a = dhash;
    final b = other.dhash;
    if (a == null || b == null || a.length != b.length) return null;
    return hammingDistance(a, b);
  }

  Map<String, Object?> toJson() => {
    'sha256': sha256,
    if (dhash case final value?) 'dhash': hashToHex(value),
  };

  static ImageFingerprint? fromJson(Object? value) {
    if (value is! Map) return null;
    final sha = value['sha256'];
    if (sha is! String || sha.isEmpty) return null;
    final dhash = value['dhash'];
    return ImageFingerprint(
      sha256: sha,
      dhash: dhash is String ? hexToHash(dhash) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImageFingerprint &&
      other.sha256 == sha256 &&
      listEquals(other.dhash, dhash);

  @override
  int get hashCode => Object.hash(sha256, Object.hashAll(dhash ?? const []));

  @override
  String toString() =>
      'ImageFingerprint(${sha256.substring(0, 8)}…, '
      '${dhash == null ? 'no dhash' : hashToHex(dhash!)})';
}

/// 立っているビットが違う数。dHash 同士の近さ。長さが違うなら比べられないので
/// 全ビットぶん離れているものとして扱う。
int hammingDistance(Uint8List a, Uint8List b) {
  if (a.length != b.length) return math.max(a.length, b.length) * 8;
  var count = 0;
  for (var i = 0; i < a.length; i++) {
    var v = a[i] ^ b[i];
    // 立っているビットの数だけ回る（最下位の 1 を落としていく）。
    while (v != 0) {
      v &= v - 1;
      count++;
    }
  }
  return count;
}

/// ハッシュを 16 進表記にする（保存用）。
String hashToHex(Uint8List hash) {
  final out = StringBuffer();
  for (final byte in hash) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// [hashToHex] の逆。読めなければ null。
Uint8List? hexToHash(String text) {
  if (text.isEmpty || text.length.isOdd) return null;
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

/// [bytes] の指紋を採る。画像として読めなければ dHash は付かない。
/// 中身が空なら null。
Future<ImageFingerprint?> computeImageFingerprint(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  final digest = await _sha256Of(bytes);
  return ImageFingerprint(sha256: digest, dhash: await _dhashOf(bytes));
}

/// 大きいものは別スレッドで採る。数 MB の画像を UI スレッドで回すと、
/// スクロール中に目に見えて引っかかる。
Future<String> _sha256Of(Uint8List bytes) async {
  if (bytes.length < _isolateThreshold) return sha256.convert(bytes).toString();
  try {
    return await Isolate.run(() => sha256.convert(bytes).toString());
  } catch (_) {
    // 別スレッドを起こせない環境ではこの場で採る。
    return sha256.convert(bytes).toString();
  }
}

/// 17×16 まで潰してから、横に隣り合う画素の明暗を [imageHashBits] ビットへ畳む。
/// 画像として読めない・のっぺりしすぎるものは null。
Future<Uint8List?> _dhashOf(Uint8List bytes) async {
  try {
    final gray = await _grayGrid(bytes);
    if (gray == null || _standardDeviation(gray) < _flatThreshold) return null;
    final hash = Uint8List(imageHashBits ~/ 8);
    var bit = 0;
    for (var y = 0; y < _hashHeight; y++) {
      for (var x = 0; x < _hashWidth - 1; x++) {
        final left = gray[y * _hashWidth + x];
        final right = gray[y * _hashWidth + x + 1];
        if (left < right) hash[bit >> 3] |= 1 << (bit & 7);
        bit++;
      }
    }
    return hash;
  } catch (_) {
    // 壊れた画像・未対応の形式。完全一致だけで判定する。
    return null;
  }
}

/// 17×16 のグレースケール（0〜255）。デコードはエンジン側の別スレッドで動くので、
/// ここで待っても UI は止まらない。
Future<Float64List?> _grayGrid(Uint8List bytes) async {
  final image = await _decodeSmall(bytes, _hashWidth, _hashHeight);
  if (image == null) return null;
  final width = image.width;
  final height = image.height;
  final ByteData? data;
  try {
    data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    image.dispose();
  }
  if (data == null || width <= 0 || height <= 0) return null;

  // 指定どおりの大きさで返るとは限らない（形式によっては丸められる）ので、
  // 実際の大きさから 9×8 へ最近傍で拾い直す。
  final gray = Float64List(_hashWidth * _hashHeight);
  for (var y = 0; y < _hashHeight; y++) {
    final sy = math.min(height - 1, (y * height) ~/ _hashHeight);
    for (var x = 0; x < _hashWidth; x++) {
      final sx = math.min(width - 1, (x * width) ~/ _hashWidth);
      final offset = (sy * width + sx) * 4;
      final r = data.getUint8(offset);
      final g = data.getUint8(offset + 1);
      final b = data.getUint8(offset + 2);
      gray[y * _hashWidth + x] = (r * 299 + g * 587 + b * 114) / 1000;
    }
  }
  return gray;
}

double _standardDeviation(Float64List values) {
  var sum = 0.0;
  for (final value in values) {
    sum += value;
  }
  final mean = sum / values.length;
  var variance = 0.0;
  for (final value in values) {
    final d = value - mean;
    variance += d * d;
  }
  return math.sqrt(variance / values.length);
}

/// NG 画像の一覧に出すための小さな見本。PNG の本文を返す。
/// 一覧がハッシュの羅列になると、どれを消せばよいか分からなくなる。
Future<Uint8List?> makeNgThumbnail(Uint8List bytes, {int size = 72}) async {
  try {
    final image = await _decodeFitted(bytes, size);
    if (image == null) return null;
    final ByteData? data;
    try {
      data = await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// 縦横それぞれを指定した大きさに潰してデコードする（縦横比は保たない）。
Future<ui.Image?> _decodeSmall(Uint8List bytes, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  // instantiateImageCodecWithSize が buffer を後始末する。
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (_, _) => ui.TargetImageSize(width: width, height: height),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// 縦横比を保ったまま、長辺が [size] に収まるようデコードする。
Future<ui.Image?> _decodeFitted(Uint8List bytes, int size) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      if (w <= 0 || h <= 0) return const ui.TargetImageSize();
      final scale = math.min(1.0, size / math.max(w, h));
      return ui.TargetImageSize(
        width: math.max(1, (w * scale).round()),
        height: math.max(1, (h * scale).round()),
      );
    },
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// URL → 指紋の覚え書き。
///
/// 指紋は本文を受け取らないと採れない。ここに覚えておくと、**一度見た URL は
/// 通信する前に NG と分かる**（NG 画像を開くたびに落とし直さずに済む）。
/// アプリを閉じても残るようディスクにも置く。
///
/// 中身はただの覚え書きなので、読み書きの失敗は握り潰す。消えても採り直せる。
class ImageFingerprintIndex {
  ImageFingerprintIndex({Directory? directory}) : _override = directory;

  static ImageFingerprintIndex shared = ImageFingerprintIndex();

  static const _fileName = 'elec_image_hashes.json';

  /// 覚えておく URL の数。超えたら古い方から捨てる。
  static const int maxEntries = 2000;

  /// 書き込みをまとめる間隔。スレを開くと数十枚まとめて増えるので、
  /// 1 枚ごとに書き出さない。
  static const Duration _saveDelay = Duration(seconds: 5);

  final Directory? _override;

  /// 挿入順を保つ Map。先頭が一番古い。
  final Map<String, ImageFingerprint> _entries = {};

  Timer? _saveTimer;
  Future<void> _pendingSave = Future.value();

  Future<File> _file() async {
    final dir = _override ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// 前回までのぶんを読み込む。起動時に一度呼ぶ。
  Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      final entries = json['entries'];
      if (entries is! Map) return;
      for (final entry in entries.entries) {
        final key = entry.key;
        final fingerprint = ImageFingerprint.fromJson(entry.value);
        if (key is String && fingerprint != null) _entries[key] = fingerprint;
      }
    } catch (_) {
      // 読めなければ覚え直すだけ。
    }
  }

  /// 覚えていれば返す。
  ImageFingerprint? get(Uri url) => _entries[url.toString()];

  void put(Uri url, ImageFingerprint fingerprint) {
    final key = url.toString();
    _entries.remove(key);
    _entries[key] = fingerprint;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _scheduleSave();
  }

  /// 覚えていればそれを、無ければ [bytes] から採って覚える。
  Future<ImageFingerprint?> resolve(Uri url, Uint8List bytes) async {
    final known = get(url);
    if (known != null) return known;
    final fingerprint = await computeImageFingerprint(bytes);
    if (fingerprint != null) put(url, fingerprint);
    return fingerprint;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(flush()));
  }

  /// 溜まっているぶんを今すぐ書き出す。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final snapshot = {
      for (final entry in _entries.entries) entry.key: entry.value.toJson(),
    };
    _pendingSave = _pendingSave.then((_) async {
      try {
        final file = await _file();
        await file.writeAsString(jsonEncode({'entries': snapshot}));
      } catch (_) {
        // 書けなくても次に見たときに採り直せる。
      }
    });
    await _pendingSave;
  }

  /// 書き出し待ちのタイマーを取り消す。testWidgets の偽の時計の中では、
  /// 残っているタイマーがテストを終わらせなくする。
  @visibleForTesting
  void cancelPendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  @visibleForTesting
  void clear() {
    cancelPendingSave();
    _entries.clear();
  }

  @visibleForTesting
  static void resetShared() {
    shared.clear();
    shared = ImageFingerprintIndex();
  }
}
