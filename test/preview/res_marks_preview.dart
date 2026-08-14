/// 柱の絵に載せる印（スレ主・自分・自分宛）だけを並べて撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test`
/// の対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/res_marks_preview.dart
/// ```
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/post_item.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

Res _res(int n, String id, String body) => Res(
  number: n,
  name: 'エッヂの名無し',
  mail: '',
  dateText: '2026/08/14(木) 02:14:00.000',
  dateTime: null,
  id: id,
  beId: null,
  body: body,
  kind: ResKind.normal,
  threadTitle: null,
);

Widget _sheet(ResLayout layout) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (final (label, owner, own, replyToOwn) in const [
      ('印なし', false, false, false),
      ('スレ主', true, false, false),
      ('自分', false, true, false),
      ('自分宛', false, false, true),
      ('スレ主＋自分', true, true, false),
      ('スレ主＋自分宛', true, false, true),
    ])
      PostItem(
        res: _res(1, 'aB3xYz9Qw', label),
        idCount: 9,
        idOrdinal: 2,
        resLayout: layout,
        isThreadOwner: owner,
        isOwn: own,
        isReplyToOwn: replyToOwn,
        onTapId: (_) {},
      ),
  ],
);

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  Widget child,
  String out,
) async {
  const surface = Size(320, 560);
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
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $out');
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  setUpAll(loadPreviewFonts);

  for (final layout in ResLayout.values) {
    testWidgets('marks ${layout.name} light', (tester) async {
      await _shoot(
        tester,
        ElecTheme.light(),
        _sheet(layout),
        '$dir/res_marks_${layout.name}_light.png',
      );
    });

    testWidgets('marks ${layout.name} dark', (tester) async {
      await _shoot(
        tester,
        ElecTheme.dark(),
        _sheet(layout),
        '$dir/res_marks_${layout.name}_dark.png',
      );
    });
  }
}
