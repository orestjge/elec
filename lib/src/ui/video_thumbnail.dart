/// mp4 等の動画直リンクから先頭フレームのサムネイルを生成する。
///
/// Android/iOS は [video_thumbnail] プラグインが OS の API（Android:
/// MediaMetadataRetriever、iOS: AVAssetImageGenerator）で動画を読み、1 フレームを
/// デコードする。**macOS は同プラグインが非対応**なので、Runner 側に用意した
/// メソッドチャンネル（`elec/video_thumbnail`・AVAssetImageGenerator）を使う。
/// faststart ＋ Range 対応サーバー（X など web ホストの mp4）なら先頭キーフレーム
/// だけ取れるので通信量は写真 1 枚程度で済む。
///
/// それ以外のプラットフォームでは常に null を返し、呼び出し側は再生カードに
/// フォールバックする。結果はプロセス内でキャッシュし、スクロールによる重複生成を
/// 避ける。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// サムネイル生成器。テストでフェイクへ差し替えられるよう関数型で持つ。
typedef VideoThumbnailGenerator = Future<Uint8List?> Function(Uri url);

/// 動画サムネイルの解決器。UI から [resolve] を呼ぶだけで使える。
class VideoThumbnails {
  VideoThumbnails._();

  /// 実際の生成処理。既定はプラグイン呼び出し。テストで差し替える。
  static VideoThumbnailGenerator generator = _generate;

  @visibleForTesting
  static TargetPlatform? debugTargetPlatform;

  /// macOS 用のサムネイル生成チャンネル（Runner の VideoThumbnailChannel）。
  static const _macChannel = MethodChannel('elec/video_thumbnail');

  /// サムネイル表示枠（幅 160）に足りる解像度。小さめに絞って生成を軽く。
  static const _maxWidth = 320;
  static const _quality = 60;

  static final Map<String, Future<Uint8List?>> _cache = {};

  /// このプラットフォームでサムネイル生成が可能か（Android/iOS/macOS）。
  static bool get isSupported {
    return switch (debugTargetPlatform ?? defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS =>
        true,
      _ => false,
    };
  }

  /// [url] の先頭フレームを JPEG バイト列で返す。生成できなければ null。
  /// 成功結果はキャッシュし、失敗（null）は次回再試行できるよう捨てる。
  static Future<Uint8List?> resolve(Uri url) {
    if (!isSupported) return Future.value(null);
    final key = url.toString();
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = generator(url);
    _cache[key] = future;
    future.then((bytes) {
      if (bytes == null) _cache.remove(key);
    });
    return future;
  }

  /// テスト間でキャッシュを初期化する。
  @visibleForTesting
  static void clearCache() => _cache.clear();

  static Future<Uint8List?> _generate(Uri url) async {
    final platform = debugTargetPlatform ?? defaultTargetPlatform;
    try {
      if (platform == TargetPlatform.macOS) {
        return await _macChannel.invokeMethod<Uint8List>('thumbnail', {
          'url': url.toString(),
          'maxWidth': _maxWidth,
          'quality': _quality,
        });
      }
      return await VideoThumbnail.thumbnailData(
        video: url.toString(),
        imageFormat: ImageFormat.JPEG,
        maxWidth: _maxWidth,
        quality: _quality,
      );
    } catch (_) {
      // 非対応コーデック・到達不可・削除済みなどは無サムネ扱い。
      return null;
    }
  }
}
