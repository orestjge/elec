import 'package:elec/main.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('起動時にスレ一覧のヘッダとローディングを表示する', (tester) async {
    await tester.pumpWidget(const ElecApp());

    // 初回フレームでは AppBar のタイトルとローディングが出る。
    // （実ネットワークには繋がないので一覧本体は待たない）
    // SliverAppBar.large はタイトルを複数箇所に描画し得るので findsWidgets。
    expect(find.text('エッヂ'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      Localizations.localeOf(tester.element(find.byType(ThreadListScreen))),
      const Locale('ja', 'JP'),
    );
  });
}
