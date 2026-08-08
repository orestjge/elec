import 'package:elec/src/ui/image_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('画像と動画は種別を混ぜたまま本文の出現順で拾う', () {
    // 全画面ビューアはこの並びのまま送るので、種別ごとの塊にしてはいけない。
    const text =
        'https://example.com/a.jpg '
        'https://example.com/clip.mp4 '
        'https://example.com/b.png '
        'https://example.com/a.jpg';
    expect(mediaUrlsIn(text).map((u) => u.path).toList(), [
      '/a.jpg',
      '/clip.mp4',
      '/b.png',
    ]);
  });

  List<String> urls(String s) =>
      imageUrlsIn(s).map((u) => u.toString()).toList();
  List<String> videos(String s) =>
      videoUrlsIn(s).map((u) => u.toString()).toList();
  List<String> audios(String s) =>
      audioUrlsIn(s).map((u) => u.toString()).toList();

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

  test('音声拡張子の URL を拾う', () {
    expect(audios('曲 https://files.catbox.moe/a.mp3 と http://x/b.m4a?dl=1'), [
      'https://files.catbox.moe/a.mp3',
      'http://x/b.m4a?dl=1',
    ]);
    expect(audios('a http://x/c.OGG b http://x/d.flac'), [
      'http://x/c.OGG',
      'http://x/d.flac',
    ]);
    // 画像・動画は音声として拾わない。
    expect(audios('https://x/a.jpg https://x/b.mp4'), isEmpty);
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
      urls(
        'https://pbs.twimg.com/media/HNo8iF5bsAAURlS?format=jpg&name=4096x4096',
      ),
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

  group('isVideoUrl', () {
    bool video(String url) => isVideoUrl(Uri.parse(url));

    test('動画拡張子はアプリ内プレーヤー対象', () {
      expect(video('https://example.com/a.mp4'), isTrue);
      expect(video('https://example.com/a.webm'), isTrue);
      expect(video('https://example.com/a.MOV'), isTrue);
      expect(video('https://example.com/a.m4v?x=1'), isTrue);
    });

    test('画像・音声・ページ URL は対象外', () {
      expect(video('https://example.com/a.jpg'), isFalse);
      expect(video('https://example.com/a.mp3'), isFalse);
      expect(video('https://example.com/watch/mp4'), isFalse);
    });
  });

  group('videoSiteLabel', () {
    String label(String url) => videoSiteLabel(Uri.parse(url));

    test('既知サイトは別名にする', () {
      expect(label('https://video.twimg.com/abc/vid.mp4'), 'Twitter');
      expect(label('https://files.catbox.moe/abcd.mp4'), 'catbox');
      expect(label('https://po-kaki-to.com/abcd.mp4'), 'po-kaki-to');
    });

    test('未知サイトはドメインに落とす', () {
      expect(label('https://example.com/path/movie.mp4'), 'example.com');
      // サブドメインは畳んで発信元ドメインを見せる。
      expect(label('https://cdn.poka-kit.com/x.mp4'), 'poka-kit.com');
    });
  });
}
