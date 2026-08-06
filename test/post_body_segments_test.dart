import 'package:elec/src/ui/post_body_segments.dart';
import 'package:flutter_test/flutter_test.dart';

/// 区画の並びを「t:文章 / i:画像 / v:動画 / a:音声 / e:埋め込み」の要約にする。
List<String> shape(String body) => [
  for (final segment in splitPostBody(body))
    switch (segment) {
      PostBodyText() => 't',
      PostBodyLink() => 'l',
      PostBodyMedia(:final images) when images.isNotEmpty =>
        'i${images.length}',
      PostBodyMedia(:final videos) when videos.isNotEmpty =>
        'v${videos.length}',
      PostBodyMedia(:final audios) when audios.isNotEmpty =>
        'a${audios.length}',
      PostBodyMedia(:final embeds) => 'e${embeds.length}',
    },
];

List<String> texts(String body) => [
  for (final segment in splitPostBody(body))
    if (segment is PostBodyText) segment.text,
];

void main() {
  test('メディアの無い本文はそのまま1区画', () {
    final segments = splitPostBody('ふつうのレス');
    expect(segments.single, isA<PostBodyText>());
    expect(texts('ふつうのレス'), ['ふつうのレス']);
  });

  test('画像は貼られた位置へ挟まり、URL 自体は本文から消える', () {
    const body = 'これ見て\nhttps://example.com/a.jpg\nどう？';
    expect(shape(body), ['t', 'i1', 't']);
    expect(texts(body), ['これ見て', 'どう？']);
  });

  test('続けて貼った同じ種類は1区画にまとめる', () {
    const body =
        'https://example.com/a.jpg\n'
        'https://example.com/b.png';
    expect(shape(body), ['i2']);
  });

  test('空行で区切られた画像は別の区画にする', () {
    const body =
        'https://example.com/a.jpg\n'
        '\n'
        'https://example.com/b.png';
    expect(shape(body), ['i1', 'i1']);
  });

  test('種類が違えば続いていても区画を分けて本文の並び順を保つ', () {
    const body =
        'https://example.com/a.jpg\n'
        'https://example.com/m.mp4\n'
        'https://example.com/b.png';
    expect(shape(body), ['i1', 'v1', 'i1']);
  });

  test('音声と埋め込みもその場に挟む', () {
    const body = '曲 https://example.com/s.mp3 と https://youtu.be/dQw4w9WgXcQ';
    expect(shape(body), ['t', 'a1', 't', 'e1']);
    expect(texts(body), ['曲', 'と']);
  });

  test('サムネイルにできないリンクは本文中のリンクとして残す', () {
    const body = 'ソース https://example.com/page.html';
    expect(shape(body), ['t']);
    expect(texts(body), [body]);
  });

  test('同じ画像を2回貼れば2回とも出す', () {
    const body =
        'https://example.com/a.jpg\n'
        'コメント\n'
        'https://example.com/a.jpg';
    expect(shape(body), ['i1', 't', 'i1']);
  });

  test('本文が画像URLだけなら文章の区画は残らない', () {
    expect(shape('https://example.com/a.jpg'), ['i1']);
  });

  group('リンクプレビュー', () {
    List<String> linked(String body) => [
      for (final segment in splitPostBody(body, linkPreviews: true))
        switch (segment) {
          PostBodyText() => 't',
          PostBodyLink() => 'l',
          PostBodyMedia() => 'm',
        },
    ];

    test('行を単独で占める URL はカードの区画にする', () {
      const body = 'これ読んで\nhttps://example.com/page.html\nおもしろい';
      expect(linked(body), ['t', 'l', 't']);
      final link = splitPostBody(
        body,
        linkPreviews: true,
      ).whereType<PostBodyLink>().single;
      expect(link.url, Uri.parse('https://example.com/page.html'));
    });

    test('文の途中に埋まった URL は本文に残す', () {
      // 区画にすると 1 文が 3 段に割れて読めなくなるので触らない。
      expect(linked('詳しくは https://example.com/a を見て'), ['t']);
    });

    test('省略形の URL は正規化しつつ、書かれた表記も残す', () {
      final link = splitPostBody(
        'ttps://example.com/a.html',
        linkPreviews: true,
      ).whereType<PostBodyLink>().single;
      expect(link.url, Uri.parse('https://example.com/a.html'));
      expect(link.raw, 'ttps://example.com/a.html');
    });

    test('続けて貼られたリンクは1本ずつ別の区画にする', () {
      const body =
          'https://example.com/a.html\n'
          'https://example.com/b.html';
      expect(linked(body), ['l', 'l']);
    });

    test('設定が切れていれば今までどおり本文中のリンクのまま', () {
      const body = 'これ読んで\nhttps://example.com/page.html';
      expect(shape(body), ['t']);
      expect(texts(body), [body]);
    });

    test('サムネイルにできる URL はカードではなくサムネイルのまま', () {
      expect(linked('https://example.com/a.jpg'), ['m']);
      expect(linked('https://youtu.be/dQw4w9WgXcQ'), ['m']);
    });
  });

  test('AA の区画はインデントを削らない', () {
    const aa =
        '　　＿＿＿\n'
        '　／　　　＼\n'
        '｜　＾　＾　｜\n'
        '　＼＿＿＿／';
    final body = '$aa\nhttps://example.com/a.jpg';
    expect(shape(body), ['t', 'i1']);
    expect(texts(body).single, startsWith('　　＿＿＿'));
  });
}
