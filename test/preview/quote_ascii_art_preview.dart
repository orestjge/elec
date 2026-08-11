/// 引用行の AA 表示を撮る、検討用スクリプト。
///
/// ```
/// OUT=/tmp flutter test test/preview/quote_ascii_art_preview.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/ui/thread_tree.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

Res post(int n, String body) => Res(
  number: n,
  name: '名無し',
  mail: '',
  dateText: '',
  dateTime: null,
  id: 'x9Jh576dp',
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

const _small = '''
　　 ∧＿∧
　　（　´∀｀）
　　（　　　　）
　　｜　｜　｜
　　（＿）＿）''';

const _mona = '''
　　＿＿＿
　／　　　＼
／　＿　　ノ＼
|　（＿）　（＿）｜
|　　　▼　　　｜
|　　　_人_　　|
＼　　　　　　／
　＼＿＿＿＿／''';

const _wide = '''
＿人人人人人人人人人人人人人人人＿
＞　　突然のシャイニングウィザード　　＜
￣Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y￣''';

const _tall = '''
　　　　　　　　　　　＿＿
　　　　　　　　　／　　　＼
　　　　　　　　／　＿　　＿＼
　　　　　　　｜　（・）　（・）｜
　　　　　　　｜　　　▼　　　｜
　　　　　　　｜　　　_人_　　｜
　　　　　　　＼　　　　　　／
　　　　　　　／￣￣￣￣￣￣＼
　　　　　　／　　　　　　　　＼
　　　　　｜　　　　　　　　　　｜
　　　　　｜　　　　　　　　　　｜
　　　　　＼＿＿＿＿＿＿＿＿＿／''';

Widget _sheet() => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (final sample in [
      ('ふつうの本文', 'これは普通の返信です。長さがあっても 1 行で切る。'),
      ('小さい AA', _small),
      ('モナー風', _mona),
      ('横長 AA', _wide),
      ('縦長 AA', _tall),
      ('AA ＋ 画像', '$_small\nhttps://example.com/a.jpg'),
    ]) ...[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 0, 0),
        child: Text(sample.$1, style: const TextStyle(fontSize: 10)),
      ),
      QuotedResRow(res: post(12, sample.$2.replaceAll('\n', '<br>'))),
    ],
  ],
);

/// 入力欄の上に出る返信先の帯を模したもの（帯そのものは `thread_screen.dart` の
/// 私有ウィジェットなので、同じ組み方をここで再現する）。高さの上限だけが引用行と
/// 違うので、その見え方を確かめるために並べる。
Widget _barSheet() => Builder(
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    Widget line(String text) => Row(
      children: [
        Text(
          '12',
          style: TextStyle(
            fontSize: 11,
            color: scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: QuoteAsciiArt(
              text: text,
              color: scheme.onSurfaceVariant,
              maxHeight: 32,
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.reply, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final sample in [_small, _mona, _wide]) ...[
                  const SizedBox(height: 2),
                  line(sample),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  },
);

Future<void> _loadMonapo() async {
  final bytes = ByteData.sublistView(
    Uint8List.fromList(File('assets/fonts/monapo.ttf').readAsBytesSync()),
  );
  await (FontLoader('Monapo')..addFont(Future.value(bytes))).load();
}

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  Widget child,
  String out, {
  required Size surface,
}) async {
  await tester.binding.setSurfaceSize(surface);
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: Material(color: theme.colorScheme.surface, child: child),
      ),
    ),
  );
  await tester.pump();

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  final file = File(out)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $out');
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  setUpAll(() async {
    await loadPreviewFonts();
    await _loadMonapo();
  });

  testWidgets('quote aa light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      _sheet(),
      '$dir/quote_aa_light.png',
      surface: const Size(420, 560),
    );
  });

  testWidgets('reply bar aa light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      _barSheet(),
      '$dir/quote_aa_bar.png',
      surface: const Size(420, 140),
    );
  });
}
