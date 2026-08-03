import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/net/auth_store.dart';
import 'src/net/board.dart';
import 'src/net/board_store.dart';
import 'src/net/endpoints.dart';
import 'src/net/file_upload_settings.dart';
import 'src/net/image_cache_store.dart';
import 'src/net/image_upload_settings.dart';
import 'src/net/ng_store.dart';
import 'src/net/read_history.dart';
import 'src/ui/thread_list_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 保存済みの認証トークン・板一覧・既読履歴・NG 設定を読み込む。
  await Future.wait([
    AuthStore.shared.load(),
    BoardStore.shared.load(),
    ImageUploadSettings.shared.load(),
    FileUploadSettings.shared.load(),
    ReadHistory.shared.load(),
    NgStore.shared.load(),
  ]);
  // 画像キャッシュの置き場を用意して、溜まっているぶんを刈る。表示を待たせる
  // 必要は無いので待たない。
  unawaited(ImageCacheStore.shared.open());
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
      home: const _BoardHome(),
    );
  }
}

/// 現在選択中の板でスレ一覧を表示する。板を切り替えると [BoardStore] の通知で
/// 作り直す（`key` に板 ID を入れて State を破棄・再生成し、ポーリングを板ごとに
/// やり直す）。板ごとの既読履歴は切替時に読み込んでから画面を組む。
class _BoardHome extends StatefulWidget {
  const _BoardHome();

  @override
  State<_BoardHome> createState() => _BoardHomeState();
}

class _BoardHomeState extends State<_BoardHome> {
  late Board _board;

  /// 現在板の既読履歴。読み込み済みなら即セット、未読み込み（追加直後の板）は
  /// null にして [_loadHistory] の完了後に埋める。
  ReadHistory? _history;

  @override
  void initState() {
    super.initState();
    _board = BoardStore.shared.current;
    _resolveHistory();
    BoardStore.shared.addListener(_onBoardChanged);
  }

  void _onBoardChanged() {
    final board = BoardStore.shared.current;
    if (board.id == _board.id) return;
    setState(() {
      _board = board;
      _resolveHistory();
    });
  }

  /// 既定板・切替済みの板は同期で取れるので即描画。初めて開く板だけ非同期で
  /// 読み込んでから埋める。
  void _resolveHistory() {
    _history = ReadHistory.cachedFor(_board);
    if (_history != null) return;
    final board = _board;
    ReadHistory.forBoard(board).then((history) {
      if (mounted && board.id == _board.id) {
        setState(() => _history = history);
      }
    });
  }

  @override
  void dispose() {
    BoardStore.shared.removeListener(_onBoardChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    if (history == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ThreadListScreen(
      key: ValueKey(_board.id),
      board: _board,
      endpoints: EdgeEndpoints.forBoard(_board),
      readHistory: history,
    );
  }
}
