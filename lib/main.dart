import 'package:flutter/material.dart';

import 'src/net/auth_store.dart';
import 'src/net/read_history.dart';
import 'src/ui/thread_list_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 保存済みの認証トークンと既読履歴を読み込む。
  await Future.wait([AuthStore.shared.load(), ReadHistory.shared.load()]);
  runApp(const ElecApp());
}

class ElecApp extends StatelessWidget {
  const ElecApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elec',
      debugShowCheckedModeBanner: false,
      theme: ElecTheme.light(),
      darkTheme: ElecTheme.dark(),
      home: const ThreadListScreen(),
    );
  }
}
