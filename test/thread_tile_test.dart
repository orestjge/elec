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
  testWidgets('一覧でも初めて見るスレは塗りつぶしの点を出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), seen: ThreadSeen.fresh, onTap: () {})),
    );
    expect(find.byKey(const ValueKey('fresh-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('listed-dot')), findsNothing);
  });

  testWidgets('一覧で見たがまだ開いていないスレは輪郭だけの点を出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), seen: ThreadSeen.listed, onTap: () {})),
    );
    expect(find.byKey(const ValueKey('listed-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('fresh-dot')), findsNothing);
  });

  testWidgets('開いたスレは点も「既読」ラベルもチェックも出さない', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), seen: ThreadSeen.opened, onTap: () {})),
    );
    expect(find.byKey(const ValueKey('fresh-dot')), findsNothing);
    expect(find.byKey(const ValueKey('listed-dot')), findsNothing);
    expect(find.text('既読'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('3 つの状態で行の高さも左端も動かない', (tester) async {
    final sizes = <Size>[];
    final titleLefts = <double>[];
    for (final seen in ThreadSeen.values) {
      await tester.pumpWidget(
        wrap(
          ListView(
            children: [
              SizedBox(
                width: 360,
                child: ThreadTile(thread: thread(), seen: seen, onTap: () {}),
              ),
            ],
          ),
        ),
      );
      sizes.add(tester.getSize(find.byType(ThreadTile)));
      titleLefts.add(tester.getTopLeft(find.text('テストスレ')).dx);
    }
    expect(sizes.toSet(), hasLength(1));
    expect(titleLefts.toSet(), hasLength(1));
  });

  testWidgets('新着があれば +N バッジを出す', (tester) async {
    await tester.pumpWidget(
      wrap(
        ThreadTile(
          thread: thread(),
          seen: ThreadSeen.opened,
          newCount: 5,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('+5'), findsOneWidget);
  });

  testWidgets('新着が無ければバッジは出ない', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), seen: ThreadSeen.opened, onTap: () {})),
    );
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('停止状態ラベルを出す', (tester) async {
    await tester.pumpWidget(
      wrap(
        ThreadTile(
          thread: thread(),
          status: ThreadStatus.archived,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('dat落ち'), findsOneWidget);
  });

  // 新着バッジも停止状態も、自動更新で後から付く。そのとき行の高さが変わると、
  // その行より下（＝見ている場所）が丸ごとズレる。
  group('後から付くものが出入りしても行の高さは変わらない', () {
    /// スレ一覧と同じ条件（幅 360・縦は無制限）で 1 行を測る。
    Future<double> heightOf(
      WidgetTester tester,
      ThreadTile tile, {
      double textScale = 1,
    }) async {
      await tester.pumpWidget(
        wrap(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: ListView(children: [SizedBox(width: 360, child: tile)]),
          ),
        ),
      );
      return tester.getSize(find.byType(ThreadTile)).height;
    }

    ThreadTile tile(String title, {int newCount = 0, ThreadStatus? status}) =>
        ThreadTile(
          thread: ThreadSummary(
            key: '1700000000',
            title: title,
            resCount: 100,
            capName: null,
          ),
          seen: ThreadSeen.opened,
          newCount: newCount,
          status: status,
          onTap: () {},
        );

    // 短め（確実に 1 行）と、1 行に収まるぎりぎりの長さの両方で確かめる。後者は
    // タイトルの幅がわずかでも削られれば 2 行に落ちる長さ。
    for (final (name, title) in [('短いタイトル', 'あ' * 20), ('折り返しの境目', 'あ' * 50)]) {
      // 文字を大きくしている端末でも同じ（下段の高さを決め打ちしていない）。
      for (final scale in [1.0, 1.5]) {
        testWidgets('$name：新着バッジ（文字 ${scale}x）', (tester) async {
          final without = await heightOf(tester, tile(title), textScale: scale);
          expect(
            await heightOf(tester, tile(title, newCount: 1), textScale: scale),
            without,
          );
          expect(
            await heightOf(
              tester,
              tile(title, newCount: 999),
              textScale: scale,
            ),
            without,
          );
        });

        testWidgets('$name：停止状態（文字 ${scale}x）', (tester) async {
          final without = await heightOf(tester, tile(title), textScale: scale);
          expect(
            await heightOf(
              tester,
              tile(title, status: ThreadStatus.archived),
              textScale: scale,
            ),
            without,
          );
        });
      }
    }
  });

  testWidgets('自分のスレは自分ラベルを出す', (tester) async {
    await tester.pumpWidget(
      wrap(ThreadTile(thread: thread(), isOwn: true, onTap: () {})),
    );
    expect(find.text('自分'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
  });
}
