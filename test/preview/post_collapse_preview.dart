/// 長いレスを**途中で畳んで「続きを読む」で伸ばす**案を撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/post_collapse_preview.dart
/// ```
///
/// 出力は `notes/preview/post_collapse_{light,dark}.png` と、伸ばした後の
/// `post_collapse_opened.png`。`OUT` で出力先を変えられる。
///
/// 畳む仕掛けそのものは本体（`collapsible.dart` の [CollapsingBody]）を呼ぶ。
/// ここに置いてあるのは見本のレスと、上限を変えて並べる枠だけ。
///
/// ## 何を比べているか
/// レス 1 つが画面を埋めるほど長くなることがある。4 枚貼られたレス（サムネイル
/// を元の形で出すようにしてから、とくに）と、20 行を超える長文。どちらもスレを
/// 追う邪魔になるが、**中身を削るのではなく、畳んで開けるようにする**方が素直。
///
/// 比べるのは畳む高さの上限だけ。
///   - 畳まない（今）
///   - 400dp（画面のおよそ半分）
///   - 560dp（画面のおよそ 3/4）
///
/// ## 畳むと、ついでに画像の読み込みのズレも消える
/// 畳んでいる間の高さは上限で頭打ちになる。**中で画像が届いて伸びても外の高さは
/// 変わらない**ので、下のレスが動かない（`thumb_shift_preview.dart` で測って
/// いたズレが、長いレスに関しては丸ごと無くなる）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:elec/src/ui/collapsible.dart';
import 'package:elec/src/ui/post_images.dart' show thumbBox, thumbFit;
import 'package:elec/src/ui/res_body.dart' show asciiArtStyle;
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 見本のレス
// ---------------------------------------------------------------------------

/// 貼られた絵 1 枚。読み込みは済んでいるものとして比率を持たせる。
class _Attachment {
  const _Attachment(this.ratio, this.color);
  final double ratio;
  final Color color;
}

class _Res {
  const _Res({
    required this.title,
    required this.number,
    this.body = '',
    this.asciiArt = false,
    this.images = const [],
  });

  /// 見本の見出し（撮った絵の中で何を見ているか分かるように）。
  final String title;
  final int number;
  final String body;

  /// 等幅で出す AA か。折り返さないので畳み方の効き目が違う。
  final bool asciiArt;
  final List<_Attachment> images;
}

const _shortBody = 'それな。だいたい同じこと思った。';

final _longBody = [
  for (var i = 1; i <= 24; i++)
    '$i 行目。長いレスというのはだいたいこういう調子で延々と続くもので、'
        '読みたい人は読むし読みたくない人は飛ばす。',
].join('\n');

const _asciiArt = '''
　　　　　 ＿＿＿
　　　　／　　　　＼
　　 ／　＼　　／　＼
　 ／　　 ●　　 ●　 ＼
　｜　　　　　　　　　 ｜
　｜　　　 ＼ 　　 ／ 　｜
　 ＼　　　 ￣￣ 　　 ／
　　 ＼＿＿＿＿＿＿／
　　　　 ＼＿＿／
　　　 ／　　　　＼
　　 ／　 これは　 ＼
　｜　　　　AA　　　 ｜
　 ＼＿＿＿＿＿＿／
''';

List<_Res> _samples() {
  const colors = [
    Color(0xFF7E9B3F),
    Color(0xFF3FA08C),
    Color(0xFF6E5BC7),
    Color(0xFFB84A63),
  ];
  return [
    _Res(title: '短いレス（畳まれない）', number: 101, body: _shortBody),
    _Res(title: '長文（24行）', number: 102, body: _longBody),
    _Res(
      title: '画像 4 枚',
      number: 103,
      body: 'まとめて貼るね',
      images: [
        _Attachment(9 / 16, colors[0]),
        _Attachment(16 / 9, colors[1]),
        _Attachment(3 / 4, colors[2]),
        _Attachment(9 / 19, colors[3]),
      ],
    ),
    _Res(
      title: '長文＋画像 2 枚',
      number: 104,
      body: _longBody,
      images: [_Attachment(3 / 4, colors[1]), _Attachment(16 / 9, colors[3])],
    ),
    _Res(title: 'AA', number: 105, body: _asciiArt, asciiArt: true),
  ];
}

// ---------------------------------------------------------------------------
// 組み立て
// ---------------------------------------------------------------------------

const double _threadWidth = 400;
const double _spacing = 8;

/// レス 1 つ。[maxHeight] が null なら畳まない（今の見た目）。
class _ResTile extends StatefulWidget {
  const _ResTile({
    required this.res,
    required this.maxHeight,
    this.opened = false,
  });

  final _Res res;
  final double? maxHeight;

  /// 「続きを読む」を押した後を撮るための初期値。
  final bool opened;

  @override
  State<_ResTile> createState() => _ResTileState();
}

class _ResTileState extends State<_ResTile> {
  late bool _open = widget.opened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cap = widget.maxHeight;
    final body = _body(context);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: .5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.res.number} 名無しさん 12:34:56 ID:AbCdEf00',
                  style: TextStyle(
                    fontFamily: japaneseTestFontFamily,
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                // AA は畳まない（本体の [PostItem] と同じ扱い）。
                if (cap == null || widget.res.asciiArt)
                  body
                else
                  CollapsingBody(
                    maxHeight: cap,
                    expanded: _open,
                    showLineCount: widget.res.images.isEmpty,
                    onExpand: () => setState(() => _open = true),
                    child: body,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final res = widget.res;
    final base = TextStyle(
      fontFamily: japaneseTestFontFamily,
      fontSize: 14,
      height: 1.45,
      color: scheme.onSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (res.body.isNotEmpty)
          Text(
            res.body,
            softWrap: !res.asciiArt,
            style: res.asciiArt ? asciiArtStyle(base) : base,
          ),
        if (res.images.isNotEmpty) ...[
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final cell = math.min(
                160.0,
                math.max(96.0, (constraints.maxWidth - _spacing) / 2),
              );
              return Wrap(
                spacing: _spacing,
                runSpacing: _spacing,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: [
                  for (final image in res.images)
                    _thumb(
                      image,
                      cell: cell,
                      maxWidth: constraints.maxWidth,
                      count: res.images.length,
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _thumb(
    _Attachment image, {
    required double cell,
    required double maxWidth,
    required int count,
  }) {
    final box = thumbBox(
      cell: cell,
      maxWidth: maxWidth,
      ratio: image.ratio,
      count: count,
    );
    // 中身は問わないので無地。大きさの決まり方だけ本体と揃える。
    return Container(
      width: box.width,
      height: box.height,
      decoration: BoxDecoration(
        color: image.color,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        thumbFit(ratio: image.ratio, box: box) == BoxFit.contain ? '全' : '',
        style: const TextStyle(color: Colors.white70, fontSize: 11),
      ),
    );
  }
}

/// 上限 1 つぶんの列。
class _CapColumn extends StatelessWidget {
  const _CapColumn({
    required this.cap,
    required this.label,
    this.opened = false,
  });

  final double? cap;
  final String label;
  final bool opened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _threadWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: japaneseTestFontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          for (final res in _samples()) ...[
            Container(
              color: scheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
              child: Text(
                res.title,
                style: TextStyle(
                  fontFamily: japaneseTestFontFamily,
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _ResTile(res: res, maxHeight: cap, opened: opened),
          ],
        ],
      ),
    );
  }
}

Future<void> _shoot(
  WidgetTester tester,
  ThemeData theme,
  String out, {
  bool opened = false,
}) async {
  const caps = <(double?, String)>[
    (null, '今（畳まない）'),
    (400, '上限 400dp（画面の約半分）'),
    (560, '上限 560dp（画面の約 3/4）'),
  ];

  tester.view.physicalSize = Size(
    (_threadWidth * caps.length + 40) * 2,
    // 畳まない列がいちばん高い。24 行の長文が 2 つあるので 4600dp ほど要る。
    4700 * 2,
  );
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (cap, label) in caps)
                  _CapColumn(cap: cap, label: label, opened: opened),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  // 高さを測ってから畳むので、落ち着くまで数フレーム進める。
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
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
    // AA は同梱フォントの字幅でないと形が崩れる。
    await loadAsciiArtFont();
  });

  testWidgets('light', (tester) async {
    await _shoot(tester, ElecTheme.light(), '$dir/post_collapse_light.png');
  });

  testWidgets('dark', (tester) async {
    await _shoot(tester, ElecTheme.dark(), '$dir/post_collapse_dark.png');
  });

  // 「続きを読む」を押した後。畳む前と同じ中身が出るかを見る。
  testWidgets('opened', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/post_collapse_opened.png',
      opened: true,
    );
  });
}
