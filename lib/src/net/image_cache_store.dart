import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 取得した画像の本文をディスクへ置いておく。
///
/// スレを閉じて開き直すたびに全サムネイルを落とし直していた。imgur などは長い
/// `Cache-Control` を返すが、`dart:io` の `HttpClient` は HTTP キャッシュを
/// 持たないので素通りになる。1 スレで数十 MB 動くので、通信量としてはポーリング
/// （2〜3MB/時）より桁が大きい。
///
/// **置き場は OS のキャッシュ用ディレクトリ**にする。容量が足りなくなれば OS が
/// 勝手に消せる場所で、バックアップにも乗らない。掲示板の画像が端末に残り続けるのは
/// 中身によっては困るので、設定から手で消せるようにもしてある。
///
/// 読み書きはすべて失敗を握り潰す。キャッシュが壊れても表示は通信し直せば済む
/// ことなので、ここで例外を投げて画像を出せなくする方が損。
class ImageCacheStore {
  ImageCacheStore({Directory? directory, this.maxBytes = defaultMaxBytes})
    : _directory = directory;

  /// 置き場の合計の上限。超えたら古い方から捨てる。
  static const int defaultMaxBytes = 200 << 20; // 200MiB

  /// 刈るときはここまで落とす。上限ぴったりで止めると毎回刈ることになる。
  static const double _pruneTo = 0.8;

  /// 読んだファイルの更新時刻をこの間隔でだけ触り直す。毎回書くと、サムネイルを
  /// 並べるたびに枚数ぶんの書き込みが走る。
  static const Duration _touchInterval = Duration(hours: 6);

  static ImageCacheStore shared = ImageCacheStore();

  final int maxBytes;
  Directory? _directory;
  Future<Directory?>? _opening;

  /// 置き場を用意する。起動時に呼んでおくと最初の 1 枚で待たされない。
  /// 同時に、前回までに溜まったぶんを刈る。
  Future<void> open() async {
    final dir = await _dir();
    if (dir != null) await prune();
  }

  Future<Directory?> _dir() {
    final ready = _directory;
    if (ready != null) return Future.value(ready);
    return _opening ??= _resolve();
  }

  Future<Directory?> _resolve() async {
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/images');
      if (!dir.existsSync()) await dir.create(recursive: true);
      return _directory = dir;
    } catch (_) {
      // 置き場を用意できない環境（テストや権限なし）ではキャッシュ無しで動く。
      return null;
    }
  }

  File? _fileFor(Directory dir, Uri url) {
    try {
      final name = sha1.convert(utf8.encode(url.toString())).toString();
      return File('${dir.path}/$name');
    } catch (_) {
      return null;
    }
  }

  /// 覚えていれば本文を返す。無ければ null。
  Future<Uint8List?> read(Uri url) async {
    try {
      final dir = await _dir();
      if (dir == null) return null;
      final file = _fileFor(dir, url);
      if (file == null || !file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      _touch(file);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 本文を覚える。書けなくても呼び出し側は困らない。
  Future<void> write(Uri url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    try {
      final dir = await _dir();
      if (dir == null) return;
      final file = _fileFor(dir, url);
      if (file == null) return;
      // 途中で落ちても壊れたものを残さないよう、書いてから置き換える。
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      // 容量不足など。次に開いたときは通信し直すだけ。
    }
  }

  /// 上限を超えていたら、古い方から捨てる。
  Future<void> prune() async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final stat = await entry.stat();
        files.add((entry, stat));
        total += stat.size;
      }
      if (total <= maxBytes) return;

      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      final target = (maxBytes * _pruneTo).round();
      for (final (file, stat) in files) {
        if (total <= target) break;
        try {
          await file.delete();
          total -= stat.size;
        } catch (_) {
          // 消せないものは飛ばす。
        }
      }
    } catch (_) {
      // 一覧が取れない環境では何もしない。
    }
  }

  /// いま置き場が使っているバイト数。設定画面で見せる。
  Future<int> usedBytes() async {
    try {
      final dir = await _dir();
      if (dir == null) return 0;
      var total = 0;
      await for (final entry in dir.list()) {
        if (entry is File) total += (await entry.stat()).size;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 置き場を空にする。
  Future<void> clear() async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      await for (final entry in dir.list()) {
        if (entry is File) {
          try {
            await entry.delete();
          } catch (_) {
            // 消せないものは残す。
          }
        }
      }
    } catch (_) {
      // 一覧が取れなければ何もしない。
    }
  }

  /// 最近使ったものを新しく見せる。古い方から捨てるので、これが無いと
  /// よく見る画像でも書いた順に消えていく。
  void _touch(File file) {
    unawaited(() async {
      try {
        final stat = await file.stat();
        final now = DateTime.now();
        if (now.difference(stat.modified) < _touchInterval) return;
        await file.setLastModified(now);
      } catch (_) {
        // 触れなくても中身は読めている。
      }
    }());
  }

  @visibleForTesting
  static void resetShared() => shared = ImageCacheStore();
}
