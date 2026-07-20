import 'package:elec/src/ui/embed_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> urls(String s) =>
      embedVideosIn(s).map((v) => v.url.toString()).toList();

  test('YouTube の各種リンクを watch URL に正規化する', () {
    expect(urls('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
    expect(urls('見て https://youtu.be/dQw4w9WgXcQ かわいい'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
    expect(urls('https://www.youtube.com/shorts/dQw4w9WgXcQ'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
    expect(urls('https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10s'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
    expect(urls('https://youtube.com/embed/dQw4w9WgXcQ'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
  });

  test('YouTube のサムネイル URL を持つ', () {
    final v = embedVideosIn('https://youtu.be/dQw4w9WgXcQ').single;
    expect(v.kind, EmbedKind.youtube);
    expect(v.id, 'dQw4w9WgXcQ');
    expect(v.thumbnailUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
  });

  test('ニコニコ動画のリンクを拾う', () {
    expect(urls('https://www.nicovideo.jp/watch/sm9'), [
      'https://www.nicovideo.jp/watch/sm9',
    ]);
    expect(urls('短縮 https://nico.ms/sm38048362 です'), [
      'https://www.nicovideo.jp/watch/sm38048362',
    ]);
    // 旧来の数字 ID。
    expect(urls('https://www.nicovideo.jp/watch/1234567890'), [
      'https://www.nicovideo.jp/watch/1234567890',
    ]);
  });

  test('ニコニコはサムネイルを持たない', () {
    final v = embedVideosIn('https://www.nicovideo.jp/watch/sm9').single;
    expect(v.kind, EmbedKind.niconico);
    expect(v.id, 'sm9');
    expect(v.thumbnailUrl, isNull);
  });

  test('動画でない URL は無視する', () {
    expect(urls('https://www.youtube.com/'), isEmpty);
    expect(urls('https://www.youtube.com/results?search_query=abc'), isEmpty);
    expect(urls('https://www.nicovideo.jp/'), isEmpty);
    expect(urls('チャンネル https://www.nicovideo.jp/user/12345'), isEmpty);
    expect(urls('https://example.com/watch?v=dQw4w9WgXcQ'), isEmpty);
  });

  test('省略された https URL も拾う', () {
    expect(urls('ttps://youtu.be/dQw4w9WgXcQ'), [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    ]);
  });

  test('重複は除去し出現順を保つ', () {
    expect(
      urls(
        'https://youtu.be/dQw4w9WgXcQ '
        'https://www.nicovideo.jp/watch/sm9 '
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      ),
      [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://www.nicovideo.jp/watch/sm9',
      ],
    );
  });
}
