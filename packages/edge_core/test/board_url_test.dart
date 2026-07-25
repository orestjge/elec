import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

void main() {
  BoardRef? parse(String url) => parseBoardUrl(Uri.parse(url));

  group('parseBoardUrl', () {
    test('板トップ（末尾スラッシュ）', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/');
      expect(r?.host, 'bbs.eddibb.cc');
      expect(r?.boardKey, 'liveedge');
    });

    test('板トップ（末尾スラッシュなし）', () {
      final r = parse('https://mi.5ch.net/news4vip');
      expect(r?.host, 'mi.5ch.net');
      expect(r?.boardKey, 'news4vip');
    });

    test('subject.txt を貼っても板を拾う', () {
      final r = parse('https://mi.5ch.net/news4vip/subject.txt');
      expect(r?.host, 'mi.5ch.net');
      expect(r?.boardKey, 'news4vip');
    });

    test('SETTING.TXT を貼っても板を拾う', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/SETTING.TXT');
      expect(r?.boardKey, 'liveedge');
    });

    test('スレ URL（read.cgi）でも板だけ拾う', () {
      final r = parse('https://mi.5ch.net/test/read.cgi/news4vip/1700000000/');
      expect(r?.host, 'mi.5ch.net');
      expect(r?.boardKey, 'news4vip');
    });

    test('スレ URL（正規形）でも板だけ拾う', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/1784559955');
      expect(r?.boardKey, 'liveedge');
    });

    test('dat 直リンクでも板を拾う', () {
      final r = parse('https://bbs.eddibb.cc/liveedge/dat/1784559955.dat');
      expect(r?.boardKey, 'liveedge');
    });

    test('5ch subback のスレ一覧 URL から板を拾う', () {
      final r = parse('https://itest.5ch.io/subback/livegalileo');
      expect(r?.host, 'itest.5ch.io');
      expect(r?.boardKey, 'livegalileo');
    });

    test('subback で末尾 .html が付いても拾う', () {
      final r = parse('https://itest.5ch.io/subback/news4vip.html');
      expect(r?.boardKey, 'news4vip');
    });

    test('5ch itest の read.cgi（サーバ埋め込み）から板を拾う', () {
      final r = parse(
        'https://itest.5ch.io/nova/test/read.cgi/livegalileo/1672844269/l50',
      );
      expect(r?.host, 'itest.5ch.io');
      expect(r?.boardKey, 'livegalileo');
    });

    test('したらば板トップからカテゴリと掲示板 ID を拾う', () {
      final r = parse('https://jbbs.shitaraba.net/otaku/18550/');
      expect(r?.host, 'jbbs.shitaraba.net');
      expect(r?.boardKey, 'otaku/18550');
    });

    test('したらば subject.cgi から板を拾う', () {
      final r = parse(
        'https://jbbs.shitaraba.net/bbs/subject.cgi/otaku/18550/',
      );
      expect(r?.boardKey, 'otaku/18550');
    });

    test('したらば read.cgi から板を拾う', () {
      final r = parse(
        'https://jbbs.shitaraba.net/bbs/read.cgi/otaku/18550/1700000000/l50',
      );
      expect(r?.boardKey, 'otaku/18550');
    });

    test('subback だけ・板が無ければ null', () {
      expect(parse('https://itest.5ch.io/subback/'), isNull);
      expect(parse('https://itest.5ch.io/subback'), isNull);
    });

    test('予約パス（test 等）を板キーにしない', () {
      expect(parse('https://bbs.eddibb.cc/test/'), isNull);
    });

    test('ホストだけ・パスなしは null', () {
      expect(parse('https://mi.5ch.net/'), isNull);
      expect(parse('https://mi.5ch.net'), isNull);
    });

    test('板キーに使えない文字は弾く', () {
      // 先頭セグメントが板キーの形でない（ドット等）。
      expect(parse('https://mi.5ch.net/foo.bar/'), isNull);
    });

    test('http/https 以外のスキームは null', () {
      expect(parse('ftp://mi.5ch.net/news4vip/'), isNull);
    });

    test('等価判定', () {
      expect(
        parse('https://mi.5ch.net/news4vip/'),
        parse('https://mi.5ch.net/news4vip/subject.txt'),
      );
    });
  });
}
