import 'dart:io';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReadHistory', () {
    test('markRead で既読になり lastSeen を返す', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      expect(h.isRead('1'), isFalse);
      await h.markRead('1', 100);
      expect(h.isRead('1'), isTrue);
      expect(h.lastSeen('1'), 100);
    });

    test('markRead は前回より小さい値では下げない', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      await h.markRead('1', 100);
      await h.markRead('1', 80); // 巻き戻さない
      expect(h.lastSeen('1'), 100);
      await h.markRead('1', 120);
      expect(h.lastSeen('1'), 120);
    });

    test('markPosition は読んでいた場所を覚え、下がりもする', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      expect(h.lastPosition('1'), isNull);
      await h.markPosition('1', 300);
      expect(h.lastPosition('1'), 300);
      // 読み返して上へ戻ったならそこが正しい。lastSeen と違って下げる。
      await h.markPosition('1', 260);
      expect(h.lastPosition('1'), 260);
    });

    test('markListed で「一覧で見た」になり、開いたスレも見た扱い', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      expect(h.isListed('1'), isFalse);
      await h.markListed(['1', '2']);
      expect(h.isListed('1'), isTrue);
      expect(h.isListed('2'), isTrue);
      expect(h.isListed('3'), isFalse);

      // 開いたスレは一覧で見ていなくても見た扱い（履歴やお気に入りから直接開く）。
      await h.markRead('3', 10);
      expect(h.isListed('3'), isTrue);
    });

    test('一覧で見たスレは新しいほうから 3000 件まで覚える', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      // スレキーは立った時刻（UNIX 秒）。古いほうから 3100 件入れる。
      await h.markListed([for (var i = 0; i < 3100; i++) '${1700000000 + i}']);
      expect(h.listedThreads, hasLength(3000));
      expect(h.isListed('${1700000000 + 3099}'), isTrue); // 新しいほうは残る
      expect(h.isListed('1700000000'), isFalse); // 古いほうから捨てる
    });

    test('お気に入りを切り替えられる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      expect(h.isFavorite('1'), isFalse);

      await h.toggleFavorite('1');
      expect(h.isFavorite('1'), isTrue);

      await h.toggleFavorite('1');
      expect(h.isFavorite('1'), isFalse);
    });

    test('スレ情報を保存できる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      const thread = ThreadSummary(
        key: '123',
        title: '保存するスレ',
        resCount: 50,
        capName: null,
      );

      await h.rememberThread(thread);

      expect(h.storedThreads.single.toSummary().title, '保存するスレ');
      expect(h.storedThreads.single.toSummary().resCount, 50);
    });

    test('直近に見たスレを保存できる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      const thread = ThreadSummary(
        key: '123',
        title: '最後に見たスレ',
        resCount: 50,
        capName: null,
      );

      await h.markLastViewedThread(thread);

      expect(h.lastViewedThread?.toSummary().key, '123');
      expect(h.lastViewedThread?.toSummary().title, '最後に見たスレ');
    });

    test('開いたスレはすぐ履歴と直近に入り既読扱いになる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      const thread = ThreadSummary(
        key: '123',
        title: '開いたスレ',
        resCount: 50,
        capName: null,
      );

      await h.markOpenedThread(thread);

      expect(h.isRead('123'), isTrue);
      expect(h.lastSeen('123'), 0);
      expect(h.lastViewedThread?.toSummary().key, '123');
      expect(h.storedThreads.single.toSummary().title, '開いたスレ');
    });

    test('開くたびに最後に見た時刻（lastSeenAt）が更新される', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final h = ReadHistory(MemoryReadHistoryStorage(), now: () => now);
      const a = ThreadSummary(key: '1', title: 'A', resCount: 1, capName: null);
      const b = ThreadSummary(key: '2', title: 'B', resCount: 1, capName: null);

      await h.markOpenedThread(a);
      now = DateTime.fromMillisecondsSinceEpoch(2000);
      await h.markOpenedThread(b);
      expect(h.lastSeenAt('1'), 1000);
      expect(h.lastSeenAt('2'), 2000);
      expect(h.lastSeenAt('3'), isNull);

      // 1 を開き直すと 1 が最新になる。
      now = DateTime.fromMillisecondsSinceEpoch(3000);
      await h.markOpenedThread(a);
      expect(h.lastSeenAt('1'), 3000);
    });

    test('lastSeenAt は永続化され forgetThread で消える', () async {
      final dir = Directory.systemTemp.createTempSync('elec_rh_seenat');
      addTearDown(() => dir.deleteSync(recursive: true));
      final now = DateTime.fromMillisecondsSinceEpoch(4000);
      final a = ReadHistory(
        FileReadHistoryStorage(directory: dir),
        now: () => now,
      );
      await a.markOpenedThread(
        const ThreadSummary(
          key: '9',
          title: '見たスレ',
          resCount: 3,
          capName: null,
        ),
      );

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.lastSeenAt('9'), 4000);

      await b.forgetThread('9');
      expect(b.lastSeenAt('9'), isNull);
    });

    test('forgetThread で既読も保存情報も消える', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      const thread = ThreadSummary(
        key: '123',
        title: '消すスレ',
        resCount: 50,
        capName: null,
      );
      await h.markOpenedThread(thread);
      expect(h.isRead('123'), isTrue);

      await h.forgetThread('123');

      expect(h.isRead('123'), isFalse);
      expect(h.lastSeen('123'), isNull);
      expect(h.storedThreads, isEmpty);
      expect(h.lastViewedThread, isNull);
    });

    test('forgetThread してもお気に入りなら保存情報は残す', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      const thread = ThreadSummary(
        key: '123',
        title: 'お気に入りスレ',
        resCount: 50,
        capName: null,
      );
      await h.markOpenedThread(thread);
      await h.setFavorite('123', true);

      await h.forgetThread('123');

      expect(h.isRead('123'), isFalse);
      expect(h.isFavorite('123'), isTrue);
      // お気に入り一覧で見せられるよう保存情報は残す。
      expect(h.storedThreads.single.toSummary().title, 'お気に入りスレ');
    });

    test('空データを load した直後でもスレ情報を保存できる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());
      await h.load();

      await h.rememberThread(
        const ThreadSummary(
          key: '123',
          title: 'ロード後に保存するスレ',
          resCount: 1,
          capName: null,
        ),
      );

      expect(h.storedThreads.single.toSummary().title, 'ロード後に保存するスレ');
    });

    test('自分のスレとレスを記録できる', () async {
      final h = ReadHistory(MemoryReadHistoryStorage());

      await h.markOwnThread('123');
      await h.markOwnPost('123', 4);

      expect(h.isOwnThread('123'), isTrue);
      expect(h.isOwnPost('123', 1), isTrue);
      expect(h.isOwnPost('123', 4), isTrue);
      expect(h.isOwnPost('123', 5), isFalse);
    });
  });

  group('FileReadHistoryStorage 永続化', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('elec_rh'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('保存 → 別インスタンスで読み込めて一致', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.markRead('123', 50);
      await a.markRead('456', 10);

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.lastSeen('123'), 50);
      expect(b.lastSeen('456'), 10);
      expect(b.isRead('789'), isFalse);
    });

    test('読んでいた場所も保存される', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.markRead('123', 300);
      await a.markPosition('123', 260);

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.lastSeen('123'), 300);
      expect(b.lastPosition('123'), 260);
      expect(b.lastPosition('456'), isNull);
    });

    test('一覧で見たスレも保存される', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.markListed(['123', '456']);

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.isListed('123'), isTrue);
      expect(b.isListed('789'), isFalse);
    });

    test('お気に入りも保存される', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.rememberThread(
        const ThreadSummary(
          key: '123',
          title: '保存済みお気に入り',
          resCount: 12,
          capName: null,
        ),
      );
      await a.setFavorite('123', true);

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.isFavorite('123'), isTrue);
      expect(b.isFavorite('456'), isFalse);
      expect(b.storedThreads.single.toSummary().title, '保存済みお気に入り');
    });

    test('直近に見たスレも保存される', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.markLastViewedThread(
        const ThreadSummary(
          key: '123',
          title: '永続化する直近スレ',
          resCount: 12,
          capName: null,
        ),
      );

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.lastViewedThread?.toSummary().key, '123');
      expect(b.lastViewedThread?.toSummary().title, '永続化する直近スレ');
    });

    test('自分のスレとレスも保存される', () async {
      final a = ReadHistory(FileReadHistoryStorage(directory: dir));
      await a.markOwnThread('123');
      await a.markOwnPost('123', 3);

      final b = ReadHistory(FileReadHistoryStorage(directory: dir));
      await b.load();
      expect(b.isOwnThread('123'), isTrue);
      expect(b.isOwnPost('123', 1), isTrue);
      expect(b.isOwnPost('123', 3), isTrue);
    });
  });
}
