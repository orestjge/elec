import 'dart:io';
import 'dart:typed_data';

import 'package:elec/src/net/image_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int length, [int fill = 1]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('elec_image_cache'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('書いたものを読み戻せる', () async {
    final store = ImageCacheStore(directory: dir);
    final url = Uri.parse('https://example.com/a.jpg');

    expect(await store.read(url), isNull);
    await store.write(url, _bytes(1024));
    expect(await store.read(url), hasLength(1024));
  });

  test('URL ごとに別のものとして覚える', () async {
    final store = ImageCacheStore(directory: dir);
    await store.write(Uri.parse('https://example.com/a.jpg'), _bytes(10, 1));
    await store.write(Uri.parse('https://example.com/b.jpg'), _bytes(20, 2));

    expect(await store.read(Uri.parse('https://example.com/a.jpg')), [
      ...List.filled(10, 1),
    ]);
    expect(
      await store.read(Uri.parse('https://example.com/b.jpg')),
      hasLength(20),
    );
  });

  test('途中で書き損じたものは残さない', () async {
    final store = ImageCacheStore(directory: dir);
    final url = Uri.parse('https://example.com/a.jpg');
    await store.write(url, _bytes(64));

    // 一時ファイルは置き換えたので残らない。
    final leftovers = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('上限を超えたら古い方から捨てる', () async {
    final store = ImageCacheStore(directory: dir, maxBytes: 1000);
    // 4 枚で 1200 バイト。上限の 8 割（800）まで落とすので、古い方から 2 枚消える。
    for (var i = 0; i < 4; i++) {
      final url = Uri.parse('https://example.com/$i.jpg');
      await store.write(url, _bytes(300));
      // 更新時刻で古さを見るので、順序が付くようずらす。
      final file = dir.listSync().whereType<File>().last;
      file.setLastModifiedSync(DateTime(2026, 1, 1 + i));
    }

    await store.prune();

    expect(await store.usedBytes(), lessThanOrEqualTo(800));
    // 新しい方は残る。
    expect(await store.read(Uri.parse('https://example.com/3.jpg')), isNotNull);
  });

  test('消すと空になる', () async {
    final store = ImageCacheStore(directory: dir);
    await store.write(Uri.parse('https://example.com/a.jpg'), _bytes(512));
    expect(await store.usedBytes(), 512);

    await store.clear();

    expect(await store.usedBytes(), 0);
    expect(await store.read(Uri.parse('https://example.com/a.jpg')), isNull);
  });

  test('置き場を使えない環境でも落ちない', () async {
    // 用意できないディレクトリを渡しても、読み書きは静かに失敗するだけ。
    final store = ImageCacheStore(
      directory: Directory('${dir.path}/gone/deeper'),
    );
    final url = Uri.parse('https://example.com/a.jpg');

    await store.write(url, _bytes(16));
    expect(await store.read(url), isNull);
    expect(await store.usedBytes(), 0);
  });
}
