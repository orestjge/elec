/// サムネイルを**元の絵の形**で出す案を並べて撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/thumb_aspect_preview.dart
/// ```
///
/// 出力は `notes/preview/thumb_aspect_{light,dark}.png` と
/// `thumb_aspect_extreme.png`。`OUT` で出力先を変えられる。
///
/// ①〜⑥ は**検討用の使い捨て**。⑦ は採用したもので、大きさの決め方は本体
/// （`post_images.dart` の `thumbBox`）をそのまま呼んでいる——写しを持つと、
/// 本体を直したときに絵だけ古くなる。
///
/// ## 何を比べているか
/// 今は一辺 [_thumbMax] の**正方形に cover** で敷いている（`post_images.dart`）。
/// 揃って並ぶので一覧としては読みやすいが、**真ん中しか残らない**——縦長の
/// 写真は上下が、横長のスクショは左右が切り落とされ、「何が写っているか」が
/// サムネイルから消える。
///
/// 元の形で出すなら、難所は 2 つ。
///   1. **比率はデコードするまで分からない**。読み込みが終わってから形が決まる
///      ので、そのままだと絵が出た瞬間に行の高さが変わり、下のレスがずれる。
///   2. **並びが揃わなくなる**。今は 2 列の升目なので端が揃うが、高さが絵ごとに
///      違うと行の下がギザギザになる。
///
/// なので案は「どこを固定するか」で分かれる。
///   - [_Plan.square]  今のまま。幅も高さも固定。
///   - [_Plan.mild]    幅を固定し、高さを比率で。ただし 4:3〜3:4 に留める。
///   - [_Plan.bold]    同じく幅固定で、16:9〜9:16 まで許す。
///   - [_Plan.single]  1 枚のときだけ本文幅いっぱいに元の形で。複数枚は升目。
///   - [_Plan.rowFix]  高さを固定し、幅を比率で（行の高さが変わらない案）。
///   - [_Plan.masonry] ③ と同じ大きさで、2 列へ振り分けて積む。
///   - [_Plan.fewOnly] **採用**。短い辺を升目に合わせ、長い辺だけ伸ばす。
///     横長は高さを変えずに幅を伸ばすので、読み込みで下のレスが動かない。
///     縦長だけが伸び、それも 3:4 まで。3 枚以上は升目に落とす。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:elec/src/ui/post_images.dart' show thumbBox, thumbFit;
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 見本の絵
// ---------------------------------------------------------------------------

/// 見出しの字。テスト環境の既定フォントはグリフを持たないので、読み込んだ
/// 日本語フォントを明示して指す。
TextStyle _text(double size, Color color, {bool bold = false}) => TextStyle(
  fontFamily: japaneseTestFontFamily,
  fontSize: size,
  color: color,
  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
);

/// 見本の 1 枚。[image] は原寸そのままで、切り取りは表示側に任せる。
class _Photo {
  _Photo(this.label, this.image);

  /// 「3:4」など、元の比率が分かる呼び名。
  final String label;
  final ui.Image image;

  double get ratio => image.width / image.height;
}

/// 切り取られたことが**一目で分かる**見本を描く。
///
/// 縁に沿って白い枠と四隅の印を入れてある。正方形へ cover で敷くと、長い方の
/// 辺にある枠と印が画面の外へ出るので、「どれだけ落ちたか」が絵として見える。
/// 中身は空や地面を模した帯と、少し中心を外した被写体（丸）。被写体を真ん中に
/// 置くと切り取っても残ってしまい、損が見えない。
ui.Image _photo(int width, int height, {required int seed}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final w = width.toDouble();
  final h = height.toDouble();
  final rect = Rect.fromLTWH(0, 0, w, h);

  final hue = (seed * 47) % 360;
  final top = HSVColor.fromAHSV(1, hue.toDouble(), .45, .95).toColor();
  final bottom = HSVColor.fromAHSV(1, (hue + 40) % 360, .70, .55).toColor();
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
        top,
        bottom,
      ]),
  );

  // 上下の帯。切り取りで真っ先に消えるのがここ。
  final band = Paint()..color = Colors.white.withValues(alpha: .30);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h * .16), band);
  canvas.drawRect(Rect.fromLTWH(0, h * .84, w, h * .16), band);

  // 被写体。中心から外して置く。
  final subject = Offset(w * .38, h * .34);
  final radius = math.min(w, h) * .18;
  canvas.drawCircle(subject, radius, Paint()..color = const Color(0xFFFFE082));
  canvas.drawCircle(
    subject,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, radius * .12)
      ..color = const Color(0xFF5D4037),
  );

  // 縁の枠と四隅の印。
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(3, math.min(w, h) * .02)
    ..color = Colors.white;
  canvas.drawRect(rect.deflate(edge.strokeWidth / 2), edge);
  final tick = math.min(w, h) * .12;
  for (final corner in [
    Rect.fromLTWH(0, 0, tick, tick),
    Rect.fromLTWH(w - tick, 0, tick, tick),
    Rect.fromLTWH(0, h - tick, tick, tick),
    Rect.fromLTWH(w - tick, h - tick, tick, tick),
  ]) {
    canvas.drawRect(corner.deflate(tick * .2), Paint()..color = Colors.white);
  }

  return recorder.endRecording().toImageSync(width, height);
}

// ---------------------------------------------------------------------------
// 並べ方の案
// ---------------------------------------------------------------------------

enum _Plan {
  square('① 今（正方形）'),
  mild('② 幅固定・高さ比率（4:3〜3:4）'),
  bold('③ 幅固定・高さ比率（16:9〜9:16）'),
  single('④ 1枚だけ幅いっぱい・元の形'),
  rowFix('⑤ 高さ固定・幅比率'),
  masonry('⑥ ③と同じ＋2列に積む'),
  fewOnly('⑦ 採用案（post_images の thumbBox）');

  const _Plan(this.label);
  final String label;
}

/// サムネイル同士の間（`post_images.dart` の `_thumbSpacing` と同じ）。
const double _spacing = 8;

/// 一辺の上限（`PostImages.thumbSize` の既定値と同じ）。
const double _thumbMax = 160;

/// 一辺の下限（`post_images.dart` の `_minThumbSize` と同じ）。
const double _thumbMin = 96;

/// 幅から升目の一辺を決める。本体と同じ式。
double _cell(double maxWidth) =>
    math.min(_thumbMax, math.max(_thumbMin, (maxWidth - _spacing) / 2));

/// [_Plan.mild] / [_Plan.bold] で高さに許す振れ幅（比率 = 幅 ÷ 高さ）。
const double _mildMin = 3 / 4;
const double _mildMax = 4 / 3;
const double _boldMin = 9 / 16;
const double _boldMax = 16 / 9;

/// 1 枚を大きく出すときの振れ幅。縦は 4:5 で止める——それ以上伸ばすと
/// レス 1 つで画面が埋まる。
const double _singleMin = 4 / 5;
const double _singleMax = 16 / 9;

/// 1 枚を大きく出すときの高さの上限。幅いっぱい×縦長だと 400dp を超え、
/// レス 1 つでスクロール 1 画面を使ってしまう。高さで頭打ちにして、そのぶん
/// 幅を戻す（形は保ったまま小さくする）。
const double _singleMaxHeight = 260;

/// 採用案の 1 枚。切るか全部見せるかも本体の判断（[thumbFit]）に従う。
Widget _sized(_Photo photo, Size box) => _picture(
  photo,
  width: box.width,
  height: box.height,
  fit: thumbFit(ratio: photo.ratio, box: box),
);

Widget _picture(
  _Photo photo, {
  required double width,
  required double height,
  BoxFit fit = BoxFit.cover,
}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: ColoredBox(
      // 縮めて全部見せるときの余り。本体と同じく地色を敷く。
      color: const Color(0xFFE3E1E6),
      child: RawImage(
        image: photo.image,
        width: width,
        height: height,
        fit: fit,
      ),
    ),
  );
}

/// 案 [plan] で [photos] を並べる。`PostImages` の `Wrap` と同じ間隔・同じ
/// 折り返しで、大きさの決め方だけを差し替えている。
class _Thumbs extends StatelessWidget {
  const _Thumbs({required this.plan, required this.photos});

  final _Plan plan;
  final List<_Photo> photos;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final cell = _cell(maxWidth);

        if (plan == _Plan.single && photos.length == 1) {
          final photo = photos.single;
          final ratio = photo.ratio.clamp(_singleMin, _singleMax);
          var width = maxWidth;
          var height = width / ratio;
          if (height > _singleMaxHeight) {
            height = _singleMaxHeight;
            width = height * ratio;
          }
          return Align(
            alignment: Alignment.centerLeft,
            child: _picture(photo, width: width, height: height),
          );
        }

        if (plan == _Plan.masonry) return _masonry(cell);

        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            for (final photo in photos)
              switch (plan) {
                _Plan.square ||
                _Plan.single => _picture(photo, width: cell, height: cell),
                _Plan.mild => _picture(
                  photo,
                  width: cell,
                  height: cell / photo.ratio.clamp(_mildMin, _mildMax),
                ),
                _Plan.bold => _picture(
                  photo,
                  width: cell,
                  height: cell / photo.ratio.clamp(_boldMin, _boldMax),
                ),
                // 幅は升目より広げない。広げると 1 行に 2 枚入らなくなり、
                // 行数が増えて結局レスの高さが変わってしまう。
                _Plan.rowFix => _picture(
                  photo,
                  width: math.min(
                    cell,
                    cell * photo.ratio.clamp(_boldMin, _boldMax),
                  ),
                  height: cell,
                ),
                // 実際に入れたもの。写しを持たず本体の関数をそのまま呼ぶ。
                _Plan.fewOnly => _sized(
                  photo,
                  thumbBox(
                    cell: cell,
                    maxWidth: maxWidth,
                    ratio: photo.ratio,
                    count: photos.length,
                  ),
                ),
                _Plan.masonry => const SizedBox.shrink(),
              },
          ],
        );
      },
    );
  }

  /// ③ と同じ大きさのまま、**2 列へ振り分けて積む**。
  ///
  /// [Wrap] は行ごとに折り返すので、背の低い絵の下に背の高い絵ぶんの空きが
  /// 残る（5 枚並べると穴が目立つ）。列ごとに「今いちばん短い方へ足す」で
  /// 積めば穴は消えるが、**並び順が左右に飛ぶ**（1,2,3,4 が 1,3 / 2,4 の順に
  /// 見える）ので、順番が意味を持つ貼り方だと読みにくくなる。
  Widget _masonry(double cell) {
    final columns = <List<Widget>>[[], []];
    final heights = <double>[0, 0];
    for (final photo in photos) {
      final height = cell / photo.ratio.clamp(_boldMin, _boldMax);
      final into = heights[0] <= heights[1] ? 0 : 1;
      if (columns[into].isNotEmpty) {
        columns[into].add(const SizedBox(height: _spacing));
      }
      columns[into].add(_picture(photo, width: cell, height: height));
      heights[into] += height + _spacing;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < columns.length; i++) ...[
          if (i > 0) const SizedBox(width: _spacing),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: columns[i],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// レスに載せて並べる
// ---------------------------------------------------------------------------

/// 見本の組。左に見出し、右に各案を並べる。
class _Sample {
  const _Sample(this.title, this.photos);
  final String title;
  final List<_Photo> photos;
}

/// レス 1 つぶんの枠。左に ID の柱があるぶん本文が狭くなるので、そこも真似る
/// （サムネイルの一辺は本文の幅から決まるため）。
class _Post extends StatelessWidget {
  const _Post({required this.plan, required this.sample});

  final _Plan plan;
  final _Sample sample;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          // ID の柱（identicon の幅ぶん）。
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
                  '名無しさん  2026/08/11(火) 12:34:56  ID:AbCdEf00',
                  style: _text(11, scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text('これ見て', style: _text(14, scheme.onSurface)),
                const SizedBox(height: 8),
                _Thumbs(plan: plan, photos: sample.photos),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 案 1 つぶんの列。スレの幅（[_threadWidth]）で見本を縦に積む。
const double _threadWidth = 400;

class _PlanColumn extends StatelessWidget {
  const _PlanColumn({required this.plan, required this.samples});

  final _Plan plan;
  final List<_Sample> samples;

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
              plan.label,
              style: _text(14, scheme.onSurface, bold: true),
            ),
          ),
          for (final sample in samples) ...[
            Container(
              color: scheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
              child: Text(
                sample.title,
                style: _text(11, scheme.onSurfaceVariant),
              ),
            ),
            _Post(plan: plan, sample: sample),
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
  required List<_Sample> samples,
  required List<_Plan> plans,
}) async {
  // 各案を横に並べるので、幅は案の数ぶん。高さは中身なりに伸ばす。
  tester.view.physicalSize = Size(
    (_threadWidth * plans.length + 40) * 2,
    // 見本を足すと縦に伸びる。足りないと Flutter の「はみ出し」の縞が写る。
    3400 * 2,
  );
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final scheme = theme.colorScheme;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ColoredBox(
          color: scheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final plan in plans)
                  _PlanColumn(plan: plan, samples: samples),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  // 画像化はエンジン側の実際の非同期処理なので、fake async のゾーンの外へ出す。
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

  setUpAll(loadPreviewFonts);

  // 見本は使い回す（ui.Image は作り直さなくてよい）。
  final tall = _Photo('3:4', _photo(600, 800, seed: 1));
  final wide = _Photo('16:9', _photo(960, 540, seed: 3));
  final squareish = _Photo('1:1', _photo(700, 700, seed: 5));
  final shot = _Photo('9:19（スクショ）', _photo(540, 1140, seed: 7));
  final banner = _Photo('4:1（横長）', _photo(1200, 300, seed: 9));
  final strip = _Photo('1:4（超縦長）', _photo(400, 1600, seed: 11));
  // 「1 行だけ写したスクショ」。正方形へ切ると真ん中の数文字しか残らない。
  final line = _Photo('15:1（1行スクショ）', _photo(1500, 100, seed: 13));

  final common = <_Sample>[
    _Sample('1枚・縦長の写真（3:4）', [tall]),
    _Sample('1枚・横長（16:9）', [wide]),
    _Sample('2枚・縦横まぜ', [tall, wide]),
    _Sample('2枚・どちらも横長', [wide, wide]),
    _Sample('3枚', [wide, squareish, tall]),
    _Sample('4枚', [tall, wide, shot, squareish]),
    _Sample('5枚', [tall, wide, squareish, shot, wide]),
  ];

  final extreme = <_Sample>[
    _Sample('1枚・スマホのスクショ（9:19）', [shot]),
    _Sample('1枚・横長の帯（4:1）', [banner]),
    _Sample('2枚・極端どうし', [strip, banner]),
    _Sample('1枚・1行だけのスクショ（15:1）', [line]),
    _Sample('3枚・1行スクショ混じり', [line, tall, wide]),
  ];

  const plans = _Plan.values;

  testWidgets('light', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thumb_aspect_light.png',
      samples: common,
      plans: plans,
    );
  });

  testWidgets('dark', (tester) async {
    await _shoot(
      tester,
      ElecTheme.dark(),
      '$dir/thumb_aspect_dark.png',
      samples: common,
      plans: plans,
    );
  });

  // 上下限が効いているかを見る。クランプが無いと、ここでレスが画面を埋める。
  testWidgets('extreme', (tester) async {
    await _shoot(
      tester,
      ElecTheme.light(),
      '$dir/thumb_aspect_extreme.png',
      samples: extreme,
      plans: plans,
    );
  });
}
