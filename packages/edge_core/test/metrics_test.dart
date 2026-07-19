import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

ThreadSummary thread(String key, int resCount) =>
    ThreadSummary(key: key, title: 't', resCount: resCount, capName: null);

void main() {
  group('momentumPerDay', () {
    test('作成から半日で 100 レスなら勢い 200/日', () {
      final t = thread('1000000000', 100);
      final created = t.createdAt;
      final now = created.add(const Duration(hours: 12));
      expect(momentumPerDay(t, now: now), closeTo(200, 0.001));
    });

    test('丸 1 日で 50 レスなら勢い 50/日', () {
      final t = thread('1000000000', 50);
      final now = t.createdAt.add(const Duration(days: 1));
      expect(momentumPerDay(t, now: now), closeTo(50, 0.001));
    });

    test('立ったばかり（経過 0）はレス数をそのまま返す', () {
      final t = thread('1000000000', 3);
      expect(momentumPerDay(t, now: t.createdAt), 3);
    });

    test('未来時刻でも 0 除算しない', () {
      final t = thread('1000000000', 3);
      expect(
        momentumPerDay(t, now: t.createdAt.subtract(const Duration(hours: 1))),
        3,
      );
    });
  });
}
