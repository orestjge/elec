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
