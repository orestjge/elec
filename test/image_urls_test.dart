import 'package:elec/src/ui/image_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> urls(String s) =>
      imageUrlsIn(s).map((u) => u.toString()).toList();
  List<String> videos(String s) =>
      videoUrlsIn(s).map((u) => u.toString()).toList();

  test('画像拡張子の URL を拾う', () {
    expect(urls('見て https://i.imgur.com/abc.jpg かわいい'), [
      'https://i.imgur.com/abc.jpg',
    ]);
    expect(urls('a http://x/y.PNG b http://x/z.webp'), [
      'http://x/y.PNG',
      'http://x/z.webp',
    ]);
  });

  test('クエリ付きは拡張子で判定しつつ URL 全体を返す', () {
    // パス末尾が画像拡張子なら対象。
    expect(urls('https://h/pic.jpeg より'), ['https://h/pic.jpeg']);
  });

  test('画像でない URL は無視する', () {
    expect(urls('https://example.com/page や https://imgur.com/abc'), isEmpty);
    expect(urls('スレ http://bbs.eddibb.cc/liveedge/1234'), isEmpty);
  });

  test('動画拡張子の URL を拾う', () {
    expect(videos('動画 https://example.com/a.mp4 と http://x/b.webm?dl=1'), [
      'https://example.com/a.mp4',
      'http://x/b.webm?dl=1',
    ]);
    expect(videos('画像 https://example.com/a.jpg'), isEmpty);
  });

  test('省略された https URL も拾って正規化する', () {
    expect(urls('ttps://example.com/a.jpg tps://example.com/b.png'), [
      'https://example.com/a.jpg',
      'https://example.com/b.png',
    ]);
    expect(videos('s://example.com/c.mp4'), ['https://example.com/c.mp4']);
  });

  test('重複は除去し出現順を保つ', () {
    expect(urls('https://x/a.png https://x/b.gif https://x/a.png'), [
      'https://x/a.png',
      'https://x/b.gif',
    ]);
  });

  test('pbs.twimg.com/media は format クエリで画像展開する', () {
    // 拡張子は無いが format=jpg なので画像扱い。URL 全体（クエリ含む）を返す。
    expect(
      urls('https://pbs.twimg.com/media/HNo8iF5bsAAURlS?format=jpg&name=4096x4096'),
      ['https://pbs.twimg.com/media/HNo8iF5bsAAURlS?format=jpg&name=4096x4096'],
    );
    // png も対象。
    expect(urls('https://pbs.twimg.com/media/ABC?format=png&name=large'), [
      'https://pbs.twimg.com/media/ABC?format=png&name=large',
    ]);
  });

  test('twimg でも format が無い/画像でなければ無視する', () {
    expect(urls('https://pbs.twimg.com/media/ABC'), isEmpty);
    expect(urls('https://pbs.twimg.com/media/ABC?format=mp4'), isEmpty);
    // /media/ 以外のパスは対象外。
    expect(urls('https://pbs.twimg.com/profile/ABC?format=jpg'), isEmpty);
  });

  test('URL が無ければ空', () {
    expect(urls('ただの本文です'), isEmpty);
  });

  group('videoSiteLabel', () {
    String label(String url) => videoSiteLabel(Uri.parse(url));

    test('既知サイトは別名にする', () {
      expect(label('https://video.twimg.com/abc/vid.mp4'), 'Twitter');
      expect(label('https://files.catbox.moe/abcd.mp4'), 'catbox');
    });

    test('未知サイトはドメインに落とす', () {
      expect(label('https://example.com/path/movie.mp4'), 'example.com');
      // サブドメインは畳んで発信元ドメインを見せる。
      expect(label('https://cdn.poka-kit.com/x.mp4'), 'poka-kit.com');
    });
  });
}
