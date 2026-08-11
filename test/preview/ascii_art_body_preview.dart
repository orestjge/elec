/// 本文の AA 表示（幅に合わせた縮小）を撮る、検討用スクリプト。
///
/// ```
/// OUT=/tmp flutter test test/preview/ascii_art_body_preview.dart
/// ```
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:elec/src/ui/compose_style.dart';
import 'package:elec/src/ui/res_body.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

/// 全角 12 字ほど。スマホでも素で収まる。
const _small = '''
　　 ∧＿∧
　　（　´∀｀）
　　（　　　　）
　　｜　｜　｜
　　（＿）＿）''';

/// 全角 20 字ほど。スマホの本文幅（およそ 340）を少し超える。
const _mona = '''
　　　　＿＿＿
　　　／　　　＼
　　／　＼　　／＼
　／　　（●）　（●）＼
　｜　　　　　▼　　　｜
　｜　　　　_人_　　　｜
　＼　　　　　　　　／
　　＼＿＿＿＿＿＿／　　　モナーだお''';

/// 全角 33 字。PC 前提の横長。
const _wide = '''
＿人人人人人人人人人人人人人人人＿
＞　　突然のシャイニングウィザード　　＜
￣Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y^Y￣''';

/// 全角 45 字。縮小の下限（8px）でも収まらず、横スクロールが残る。
const _veryWide = '''
　　　　　　　　　　　＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿
　　∧＿∧　　　　／
　（　´∀｀）　＜　これは PC の画面幅を前提に組まれた、とても横に長い AA です
　（　　　　）　　＼＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿＿
　｜　｜　｜''';

/// 半角の記号で組んだ、行の長い AA。
const _ansi = r'''
  .-"""-.        _______________________________
 / .===. \      /                               \
 \/ 6 6 \/     <  half-width art also gets wide   >
 ( \___/ )      \_______________________________/
  \_____/''';

Widget _sheet() => Builder(
  builder: (context) {
    final theme = Theme.of(context);
    Widget sample(String title, String body) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          ResBody(
            text: body,
            // PostItem の本文と同じ字。
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 15,
              height: 1.4,
            ),
            selectable: false,
            onTapRes: (_) {},
            onTapUrl: (_) {},
          ),
        ],
      ),
    );

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sample('小さい AA（等倍のまま）', _small),
          sample('モナー（少しはみ出す）', _mona),
          sample('横長 AA', _wide),
          sample('とても横長な AA（下限まで縮めても残る）', _veryWide),
          sample('半角で組んだ AA', _ansi),
        ],
      ),
    );
  },
);

/// レス入力欄に AA を書いたときの見え方（入力欄そのものは thread_screen.dart の
/// 私有ウィジェットなので、同じ組み方をここで再現する）。
Widget _composerSheet() => Builder(
  builder: (context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = composeBodyTextStyle(theme);

    Widget field(String title, String text) {
      final controller = TextEditingController(text: text);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 10,
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fit = composeAsciiArtFit(
                        context,
                        base: textStyle,
                        text: text,
                        maxWidth: constraints.maxWidth - 28 - 2,
                      );
                      return TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: fit?.lines(5) ?? 5,
                        style: fit?.style ?? textStyle,
                        decoration: composeFieldDecoration(
                          scheme: scheme,
                          hintText: 'レスを書く',
                          textStyle: textStyle,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10.5,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: kComposeControlHeight,
                  height: kComposeControlHeight,
                  child: IconButton(
                    style: composeQuietButtonStyle(scheme),
                    onPressed: () {},
                    icon: const Icon(Icons.image_outlined, size: 22),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: kComposeControlHeight,
                  height: kComposeControlHeight,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: composeShape,
                    ),
                    onPressed: () {},
                    child: const Icon(Icons.send, size: 20),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        field('ふつうの本文', 'これは普通のレスです。折り返しても読める。'),
        field('小さい AA', _small),
        field('モナー', _mona),
        field('横長 AA', _wide),
        field('とても横長な AA', _veryWide),
      ],
    );
  },
);

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
    await loadAsciiArtFont();
  });

  testWidgets('ascii art body light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      _sheet(),
      '$dir/ascii_art_body.png',
      // スマホ相当の幅（本文はここから左右の余白を引いた幅に収まる）。
      surface: const Size(390, 700),
    );
  });

  testWidgets('ascii art composer light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      _composerSheet(),
      '$dir/ascii_art_composer.png',
      surface: const Size(390, 700),
    );
  });
}
