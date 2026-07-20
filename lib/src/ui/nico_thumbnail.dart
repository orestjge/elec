/// ニコニコ動画のサムネイル URL を getthumbinfo API から解決する。
///
/// ニコニコにはサムネイルの静的 URL が無い（`sm9` → `/thumbnails/9/9` のような
/// 旧形式は古い動画でしか成立せず、新しい動画は `/thumbnails/43000000/43000000.
/// 95515327` のように ID から導けない末尾が付く）。公式の getthumbinfo が返す
/// `<thumbnail_url>` を使うのが唯一確実な手段。
///
/// 解決結果はプロセス内でキャッシュし、同じ動画への重複リクエストを避ける。
library;

import 'dart:convert';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/foundation.dart';

import '../net/http_fetcher.dart';

final _thumbnailUrlRe = RegExp(r'<thumbnail_url>(.*?)</thumbnail_url>');

/// ニコニコのサムネイル URL 解決器。UI から `resolve` を呼ぶだけで使える。
class NicoThumbnails {
  NicoThumbnails._();

  /// 取得手段。テストでフェイクへ差し替えられるよう可変にしてある。
  static HttpFetcher fetcher = HttpClientFetcher();

  static final Map<String, Future<Uri?>> _cache = {};

  /// 動画 ID [id]（`sm9` など）のサムネイル URL を返す。取得できなければ null。
  /// 成功結果はキャッシュし、失敗（null）は次回再試行できるよう捨てる。
  static Future<Uri?> resolve(String id) {
    final cached = _cache[id];
    if (cached != null) return cached;
    final future = _fetch(id);
    _cache[id] = future;
    future.then((url) {
      if (url == null) _cache.remove(id);
    });
    return future;
  }

  /// テスト間でキャッシュを初期化する。
  @visibleForTesting
  static void clearCache() => _cache.clear();

  static Future<Uri?> _fetch(String id) async {
    try {
      final resp = await fetcher.get(
        Uri.parse('https://ext.nicovideo.jp/api/getthumbinfo/$id'),
      );
      if (resp.statusCode != 200) return null;
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final raw = _thumbnailUrlRe.firstMatch(body)?.group(1)?.trim();
      if (raw == null || raw.isEmpty) return null;
      return Uri.tryParse(raw);
    } catch (_) {
      // 通信失敗・削除済み動画などは無サムネ扱い。
      return null;
    }
  }
}
