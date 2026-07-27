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
