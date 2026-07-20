import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/thread_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ThreadSummary thread() => const ThreadSummary(
  key: '1700000000',
  title: 'テストスレ',
  resCount: 100,
  capName: null,
);

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('未読スレは未読ドットを出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), isRead: false, onTap: () {})),
    );
    expect(find.byKey(const ValueKey('unread-dot')), findsOneWidget);
  });

  testWidgets('既読スレはドットも「既読」ラベルもチェックも出さない', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), isRead: true, onTap: () {})),
    );
    expect(find.byKey(const ValueKey('unread-dot')), findsNothing);
    expect(find.text('既読'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('新着があれば +N バッジを出す', (tester) async {
    await tester.pumpWidget(
      wrap(
        ThreadTile(thread: thread(), isRead: true, newCount: 5, onTap: () {}),
      ),
    );
    expect(find.text('+5'), findsOneWidget);
  });

  testWidgets('新着が無ければバッジは出ない', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), isRead: true, onTap: () {})),
    );
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('停止状態ラベルを出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), statusLabel: 'dat落ち', onTap: () {})),
    );
    expect(find.text('dat落ち'), findsOneWidget);
  });

  testWidgets('自分のスレは自分ラベルを出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), isOwn: true, onTap: () {})),
    );
    expect(find.text('自分'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
  });
}
