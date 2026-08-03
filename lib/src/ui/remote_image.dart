/// 大きすぎる画像でアプリを落とさないためのネットワーク画像読み込み。
///
/// 掲示板には数十 MB・数千万画素の画像が貼られることがある。Flutter 標準の
/// [NetworkImage] は本文を全部落としてから**原寸のまま**デコードするので、
/// 画素数 × 4 バイトがそのままメモリに載る（8000×8000 なら 256MB）。端末の
/// 上限を超えると OOM でプロセスごと落ち、Dart 側では捕まえられない。
///
/// ここでは 2 段で防ぐ。
///  1. **転送バイト数の上限**。Content-Length を見て、大きすぎるものは本文を
///     読まずに接続を捨てる（[ImageTooLargeException]）。ヘッダを見るだけなので
///     通信量はほぼ 0。Content-Length を返さないホスト向けに、受信中も
///     累計バイト数で打ち切る。
///  2. **表示サイズまで縮めてデコード**。サムネイルなら 160dp 相当、全画面
///     ビューアなら画面いっぱい相当まで。加えて画素数の絶対上限も掛ける。
///
/// 1 で弾いた画像は「タップで読み込む」カードに落とす（[ImageLoadPolicy]）。
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// これを超える画像は自動で読み込まない（利用者がタップしたら読む）。
///
/// 掲示板に貼られる写真はおおむね数 MB に収まる。それを大きく超えるものは
/// 通信量も描画コストも跳ね上がるので、勝手には取りに行かない。
const int imageAutoLoadMaxBytes = 8 << 20; // 8MiB

/// 利用者が「読み込む」と決めた画像でも、これを超えたら諦める。
/// 受信バッファだけで落ちるのを防ぐための最後の砦。
const int imageHardMaxBytes = 64 << 20; // 64MiB

/// デコード後の画素数の上限。メモリ使用量は概ね `画素数 × 4` バイト。
/// 表示サイズによる縮小が効かない極端な縦横比の画像への保険。
const int imageMaxPixels = 8 << 20; // 約 8.4M 画素 ≒ 34MB

/// 上限を超えていて読み込まなかった画像。
class ImageTooLargeException implements Exception {
  const ImageTooLargeException({required this.url, required this.bytes});

  final Uri url;

  /// 分かっていればバイト数。Content-Length を返さないホストでは null。
  final int? bytes;

  @override
  String toString() =>
      'ImageTooLargeException($url, ${bytes ?? '?'} bytes exceeds limit)';
}

/// 画像ごとの「大きさが分かったか」「利用者が読むと決めたか」をプロセス内で
/// 覚えておく。スクロールでウィジェットが作り直されるたびに取りに行かないため。
class ImageLoadPolicy {
  ImageLoadPolicy._();

  static final Map<String, int> _sizes = {};
  static final Set<String> _allowed = {};

  /// バイト数が分かっていれば返す。一度でも読んだ（弾いた）URL なら分かる。
  static int? knownBytes(Uri url) => _sizes[url.toString()];

  static void remember(Uri url, int bytes) => _sizes[url.toString()] = bytes;

  /// 利用者が「読み込む」と決めた URL か。
  static bool isAllowed(Uri url) => _allowed.contains(url.toString());

  /// 以後この URL は上限を上げて読む（同じ画像がスレ内に複数あっても一度でよい）。
  static void allow(Uri url) => _allowed.add(url.toString());

  /// 自動読み込みを見送る大きさだと既に分かっているか。真なら通信せずに
  /// 「タップで読み込む」カードを出せる。
  static bool skipsAutoLoad(Uri url) {
    if (isAllowed(url)) return false;
    final bytes = knownBytes(url);
    return bytes != null && bytes > imageAutoLoadMaxBytes;
  }

  /// この URL に掛ける転送バイト数の上限。
  static int limitFor(Uri url) =>
      isAllowed(url) ? imageHardMaxBytes : imageAutoLoadMaxBytes;

  @visibleForTesting
  static void reset() {
    _sizes.clear();
    _allowed.clear();
  }
}

/// 取得した本文を直近のぶんだけ覚えておく置き場。
///
/// **サムネイルと全画面は目標サイズが違う＝別のキャッシュ key** なので、
/// サムネイルをタップして開くと `ImageCache` には当たらず取り直しになる。
/// デコードのやり直しは表示サイズが違う以上どうしようもないが、**同じ URL を
/// 二度落とすのは無駄**（開くたびに待たされる）。直近のものだけ本文を持っておき、
/// 開いたときは通信を省いてデコードだけで済ませる。
class _BytesCache {
  _BytesCache._();

  /// 置き場の合計。デコード後の画像はこれとは別に `ImageCache` が持つので、
  /// 欲張らず数枚ぶんに留める。
  static const int _budget = 24 << 20; // 24MiB

  /// 1 枚で置き場を埋めないよう、大きすぎるものは覚えない。
  static const int _maxEntry = _budget ~/ 3;

  /// 挿入順を保つ Map。先頭が一番古い。
  static final Map<String, Uint8List> _entries = {};
  static int _total = 0;
  static bool _observing = false;

  static Uint8List? get(Uri url) {
    final key = url.toString();
    final bytes = _entries.remove(key);
    if (bytes == null) return null;
    _entries[key] = bytes; // 使ったものを新しい側へ回す
    return bytes;
  }

  static void put(Uri url, Uint8List bytes) {
    if (bytes.length > _maxEntry) return;
    _observeMemoryPressure();
    final key = url.toString();
    final old = _entries.remove(key);
    if (old != null) _total -= old.length;
    _entries[key] = bytes;
    _total += bytes.length;
    while (_total > _budget && _entries.length > 1) {
      final oldest = _entries.keys.first;
      _total -= _entries.remove(oldest)!.length;
    }
  }

  /// 端末がメモリを欲しがったら真っ先に手放す。ここは無くても表示できる
  /// （通信し直すだけ）ので、抱えたまま落ちるより捨てた方がよい。
  static void _observeMemoryPressure() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(_MemoryPressureObserver());
  }

  @visibleForTesting
  static void clear() {
    _entries.clear();
    _total = 0;
  }
}

class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => _BytesCache.clear();
}

/// バイト数と表示サイズに上限を掛けて画像を読む [ImageProvider]。
///
/// [target] は**物理ピクセル**での目標サイズ（論理サイズ × devicePixelRatio）。
/// これより大きい画像は縮めてデコードし、小さい画像はそのまま（拡大はしない）。
@immutable
class RemoteImage extends ImageProvider<RemoteImage> {
  const RemoteImage(
    this.url, {
    required this.target,
    this.cover = false,
    this.maxBytes = imageAutoLoadMaxBytes,
  });

  final Uri url;

  /// デコード後の目標サイズ（物理ピクセル）。
  final Size target;

  /// [target] を覆うまで（BoxFit.cover 相当）残すか。既定は収める（contain 相当）。
  final bool cover;

  /// 受け取るバイト数の上限。超える画像は [ImageTooLargeException] で失敗する。
  final int maxBytes;

  // 画像ホストは掲示板サーバとは無関係なので、アプリ本体の HttpClientFetcher
  // （IPv6 優先などの都合を持つ）とは分けた素の HttpClient を使い回す。
  static io.HttpClient? _sharedClient;

  static io.HttpClient get _client => _sharedClient ??= io.HttpClient();

  /// テストの `HttpOverrides` 差し替えに追従できるよう、共有クライアントを捨てる。
  /// 覚えている本文も一緒に捨てる（前のテストの結果を使い回さない）。
  @visibleForTesting
  static void resetClient() {
    _sharedClient?.close(force: true);
    _sharedClient = null;
    _BytesCache.clear();
  }

  @override
  Future<RemoteImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RemoteImage>(this);

  @override
  ImageStreamCompleter loadImage(RemoteImage key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: key.url.toString(),
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<RemoteImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    RemoteImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      // 同じ URL を別の大きさで開き直したときは、落とし直さず本文を使い回す。
      final bytes = _BytesCache.get(url) ?? await _fetch(chunkEvents);
      if (bytes.isEmpty) throw Exception('empty image: $url');
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer, getTargetSize: _targetSize);
    } catch (_) {
      // 失敗をキャッシュに残すと再試行できなくなる。標準の NetworkImage と同じく
      // キャッシュが key を登録し終えてから捨てる。
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunkEvents.close());
    }
  }

  /// 上限を超えないよう打ち切りながら本文を受け取る。
  Future<Uint8List> _fetch(
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    final request = await _client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != io.HttpStatus.ok) {
      unawaited(response.drain<void>().catchError((_) {}));
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: url,
      );
    }

    // Content-Length は無いこともある（-1）。あるなら本文を読む前に判断できる。
    final declared = response.contentLength;
    if (declared >= 0) ImageLoadPolicy.remember(url, declared);
    if (declared > maxBytes) {
      await _abort(response);
      throw ImageTooLargeException(url: url, bytes: declared);
    }

    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    var received = 0;
    late final StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        received += chunk.length;
        // Content-Length が無い／偽っている場合はここで止める。
        if (received > maxBytes) {
          unawaited(sub.cancel());
          completer.completeError(
            ImageTooLargeException(
              url: url,
              bytes: declared >= 0 ? declared : null,
            ),
          );
          return;
        }
        builder.add(chunk);
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: received,
            expectedTotalBytes: declared >= 0 ? declared : null,
          ),
        );
      },
      onDone: () {
        if (completer.isCompleted) return;
        ImageLoadPolicy.remember(url, received);
        final bytes = builder.takeBytes();
        _BytesCache.put(url, bytes);
        completer.complete(bytes);
      },
      onError: (Object e, StackTrace s) {
        if (!completer.isCompleted) completer.completeError(e, s);
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  /// 本文を読まずに接続を捨てる。
  static Future<void> _abort(io.HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {
      // 切断できなくても呼び出し側の判断（大きすぎる）は変わらない。
    }
  }

  /// 原寸 [width]×[height] をどこまで縮めてデコードするか。
  ui.TargetImageSize _targetSize(int width, int height) {
    if (width <= 0 || height <= 0) {
      return ui.TargetImageSize(width: width, height: height);
    }
    final byTarget = cover
        ? math.max(target.width / width, target.height / height)
        : math.min(target.width / width, target.height / height);
    final byPixels = math.sqrt(imageMaxPixels / (width * height));
    // 引き伸ばしはしない（原寸より大きくデコードしても粗いだけ）。
    final scale = math.min(1.0, math.min(byTarget, byPixels));
    if (scale >= 1) return ui.TargetImageSize(width: width, height: height);
    return ui.TargetImageSize(
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteImage &&
      other.url == url &&
      other.target == target &&
      other.cover == cover &&
      other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(url, target, cover, maxBytes);

  @override
  String toString() => 'RemoteImage("$url", target: $target, max: $maxBytes)';
}
