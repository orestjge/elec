import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/net/auth_store.dart';
import 'src/net/image_upload_settings.dart';
import 'src/net/ng_store.dart';
import 'src/net/read_history.dart';
import 'src/ui/thread_list_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 保存済みの認証トークン・既読履歴・NG 設定を読み込む。
  await Future.wait([
    AuthStore.shared.load(),
    ImageUploadSettings.shared.load(),
    ReadHistory.shared.load(),
    NgStore.shared.load(),
  ]);
  runApp(const ElecApp());
}

class ElecApp extends StatelessWidget {
  const ElecApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elec',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja', 'JP'),
      supportedLocales: const [Locale('ja', 'JP')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ElecTheme.light(),
      darkTheme: ElecTheme.dark(),
      home: const ThreadListScreen(),
    );
  }
}
