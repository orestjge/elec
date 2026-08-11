/// サムネイルを元の形で出したとき、**読み込み完了でレスがどれだけ動くか**を
/// 実際に測る検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。走らせるときだけパスを明示する:
///
/// ```
/// flutter test test/preview/thumb_shift_preview.dart
/// ```
///
/// ずれ量は標準出力に出る。読み込み前後の見た目は
/// `notes/preview/thumb_shift_{before,after}.png`（`OUT` で変えられる）。
///
/// ## 何を確かめているか
/// 比率はデコードするまで分からないので、元の形で出す案はどれも「正方形で
/// 場所を取っておいて、絵が来たら高さが変わる」動きになる。問題は**その瞬間に
/// 読んでいる行が動くか**。
///
/// スレ一覧は [ScrollablePositionedList]（`thread_screen.dart`）で、ふつうの
/// [ListView] とは位置の持ち方が違う。**中心に据えた行を基点に前後へ積む**ので、
/// 「基点より上」で高さが変わったぶんは上へ逃げ、見ている行は動かない可能性が
/// ある——理屈で決めずに測る。
///
/// 測るのは 3 つ。
///   1. **画面より上**のレスの絵が届いた（いちばん怖い形）。
///   2. **画面の中**のレスの絵が届いた（動くのは当たり前。どれだけかを見る）。
///   3. **画面より下**のレスの絵が届いた（動かないはず）。
///
/// 比較のため、同じ操作を ①正方形（ずれ 0 のはず）でも走らせる。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:elec/src/ui/post_images.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 並べ方
// ---------------------------------------------------------------------------
//
// 大きさの決め方は**本体と同じもの**（`post_images.dart` の [thumbBox]）を
// 呼ぶ。ここで写しを持つと、本体を直したときに測った値だけ古くなる。

const double _spacing = 8;
const double _thumbMax = 160;
const double _thumbMin = 96;

double _cell(double maxWidth) =>
    math.min(_thumbMax, math.max(_thumbMin, (maxWidth - _spacing) / 2));

/// レスに貼られた絵 1 枚。[ratio] は幅 ÷ 高さ——実際にはデコードするまで
/// 分からない値で、届いた瞬間から効き始める。
class _Attachment {
  const _Attachment(this.ratio, this.color);
  final double ratio;
  final Color color;
}

/// サムネイル 1 枚。[loaded] が false の間は正方形で場所を取る。
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.attachment,
    required this.loaded,
    required this.cell,
    required this.maxWidth,
    required this.natural,
    required this.count,
  });

  final _Attachment attachment;
  final bool loaded;
  final double cell;
  final double maxWidth;

  /// 元の形で出す案か（false なら常に正方形＝今の見た目）。
  final bool natural;

  /// 同じレスに貼られた枚数。⑦ は 3 枚以上を升目に落とす。
  final int count;

  @override
  Widget build(BuildContext context) {
    // 正方形の案（対照）は比率を渡さない＝いつまでも分からない扱いにする。
    final box = thumbBox(
      cell: cell,
      maxWidth: maxWidth,
      ratio: natural && loaded ? attachment.ratio : null,
      count: count,
    );
    return Container(
      width: box.width,
      height: box.height,
      decoration: BoxDecoration(
        color: loaded ? attachment.color : const Color(0xFFD8D8DC),
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 見本のスレ
// ---------------------------------------------------------------------------

class _Res {
  const _Res(this.number, this.lines, this.images);
  final int number;

  /// 本文の行数。レスごとに高さを散らすため。
  final int lines;
  final List<_Attachment> images;
}

/// どのレスの絵が届いたかを持つ。ここを変えるとその場で作り直される。
class _Loaded extends ChangeNotifier {
  final _numbers = <int>{};

  bool contains(int number) => _numbers.contains(number);

  void load(Iterable<int> numbers) {
    _numbers.addAll(numbers);
    notifyListeners();
  }
}

class _ResTile extends StatelessWidget {
  const _ResTile({
    required this.res,
    required this.loaded,
    required this.natural,
  });

  final _Res res;
  final _Loaded loaded;
  final bool natural;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: loaded,
      builder: (context, _) => Container(
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
                  // 位置を測る目印。レス番号で引く。
                  Text(
                    '${res.number} 名無しさん 12:34:56 ID:AbCdEf00',
                    key: ValueKey('res-${res.number}'),
                    style: TextStyle(
                      fontFamily: japaneseTestFontFamily,
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (var i = 0; i < res.lines; i++)
                    Text(
                      'レスの本文がここに入る。$i 行目。',
                      style: TextStyle(
                        fontFamily: japaneseTestFontFamily,
                        fontSize: 14,
                        color: scheme.onSurface,
                      ),
                    ),
                  if (res.images.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cell = _cell(constraints.maxWidth);
                        return Wrap(
                          spacing: _spacing,
                          runSpacing: _spacing,
                          crossAxisAlignment: WrapCrossAlignment.start,
                          children: [
                            for (final image in res.images)
                              _Thumb(
                                attachment: image,
                                loaded: loaded.contains(res.number),
                                cell: cell,
                                maxWidth: constraints.maxWidth,
                                natural: natural,
                                count: res.images.length,
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 見本のスレ。絵は 3 レスに 1 つ。**多めに寄せてある**——ずれは絵のあるレスの
/// ぶんだけ積み上がるので、少なめの見本で測ると軽く見える。
List<_Res> _thread() {
  const colors = [
    Color(0xFF7E9B3F),
    Color(0xFF3FA08C),
    Color(0xFF6E5BC7),
    Color(0xFFB84A63),
  ];
  // 実際に貼られる形の割合を粗く真似る（縦長の写真・スクショが多い）。
  const ratios = <double>[3 / 4, 16 / 9, 1, 9 / 16, 16 / 9, 3 / 4, 9 / 19, 1];
  final list = <_Res>[];
  for (var n = 1; n <= 60; n++) {
    final images = <_Attachment>[];
    if (n % 3 == 0) {
      final count = n % 12 == 0 ? 5 : (n % 9 == 0 ? 4 : (n % 6 == 0 ? 2 : 1));
      for (var i = 0; i < count; i++) {
        images.add(
          _Attachment(ratios[(n + i) % ratios.length], colors[(n + i) % 4]),
        );
      }
    }
    list.add(_Res(n, 1 + (n % 3), images));
  }
  return list;
}

// ---------------------------------------------------------------------------
// 測る
// ---------------------------------------------------------------------------

/// [targets] の絵が届くことで**増える高さの合計**。
///
/// 画面のどこにいるかとは無関係な、案そのものの持つ量。実測のずれはこれ以下に
/// なる（SPL が吸収したぶんだけ小さくなる）ので、突き合わせると「動かなかった」
/// のが吸収の結果なのか、そもそも増えていないだけなのかが分かる。
double _addedHeight(
  List<_Res> thread,
  List<int> targets, {
  required bool natural,
}) {
  if (!natural) return 0;
  // 本文の幅は端末 400dp から左右の余白と ID の柱を引いたぶん。
  const cell = _thumbMax;
  const maxWidth = 340.0;
  var total = 0.0;
  for (final res in thread) {
    if (!targets.contains(res.number)) continue;
    final boxes = [
      for (final image in res.images)
        thumbBox(
          cell: cell,
          maxWidth: maxWidth,
          ratio: image.ratio,
          count: res.images.length,
        ),
    ];
    final square = List.filled(boxes.length, const Size.square(cell));
    total += _wrapHeight(boxes, maxWidth) - _wrapHeight(square, maxWidth);
  }
  return total;
}

/// [Wrap] と同じ詰め方をしたときの高さ。
///
/// 幅の広いものは 1 行を丸ごと使う（[thumbBox]）ので、「1 行に 2 つ」で数えると
/// 実測と合わない。折り返しをそのまま真似る。
double _wrapHeight(List<Size> boxes, double maxWidth) {
  var total = 0.0;
  var rowWidth = 0.0;
  var rowHeight = 0.0;
  for (final box in boxes) {
    final needs = rowWidth == 0 ? box.width : rowWidth + _spacing + box.width;
    if (rowWidth > 0 && needs > maxWidth) {
      total += rowHeight + _spacing;
      rowWidth = box.width;
      rowHeight = box.height;
      continue;
    }
    rowWidth = needs;
    rowHeight = math.max(rowHeight, box.height);
  }
  return total + rowHeight;
}

const Size _screen = Size(400, 780);

/// どのレスの絵を届かせるか。
enum _When {
  above('画面より上のレスの絵が届いた'),
  inside('画面の中のレスの絵が届いた'),
  below('画面より下のレスの絵が届いた'),
  all('組んである絵が全部いっぺんに届いた');

  const _When(this.label);
  final String label;
}

/// [natural] の並べ方でスレを開き、[when] の絵を届かせて、**画面のいちばん上に
/// 見えているレス**がどれだけ動いたかを返す。
Future<_Result> _measure(
  WidgetTester tester, {
  required bool natural,
  required _When when,
  required double dragBy,
  String? shotBefore,
  String? shotAfter,
}) async {
  tester.view.physicalSize = _screen * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final thread = _thread();
  final loaded = _Loaded();

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ElecTheme.light(),
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: Scaffold(
          body: ScrollablePositionedList.builder(
            // 実際のスレと同じく、途中（前回の続き）から開く。
            initialScrollIndex: 20,
            itemCount: thread.length,
            itemBuilder: (context, i) =>
                _ResTile(res: thread[i], loaded: loaded, natural: natural),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  // 前回の続きから、指で [dragBy] だけ下へ送った状態にする（基点の行から離れた
  // 場所を見ている＝実際に読んでいるときの形）。
  await tester.drag(find.byType(ScrollablePositionedList), Offset(0, -dragBy));
  await tester.pump();

  // 組まれているレスを拾う。SPL は画面の外でも少し先まで組む（cacheExtent）
  // ので、「画面より上だが組まれている」行がある。そこが動くかが肝心。
  final built = <int, double>{};
  for (final res in thread) {
    final finder = find.byKey(ValueKey('res-${res.number}'));
    if (finder.evaluate().isEmpty) continue;
    built[res.number] = tester.getTopLeft(finder).dy;
  }
  final onScreen = [
    for (final entry in built.entries)
      if (entry.value >= 0 && entry.value < _screen.height) entry.key,
  ]..sort();

  // 動きを測る相手は**画面のいちばん下に見えているレス**。上で高さが変わると
  // ここが押し下げられる＝読んでいる途中で字が飛ぶ。

  // 画面のいちばん下ぎりぎりに掛かっている行を目印にすると、数 dp 押されただけ
  // で外へ出て「飛んだ」ことになり、量が読めない。下端から少し内側に入っている
  // ものの中でいちばん下を採る。
  final marker = onScreen.lastWhere(
    (n) => built[n]! < _screen.height - 240,
    orElse: () => onScreen.last,
  );

  // 絵を届かせる範囲を決める。
  final targets = [
    for (final res in thread)
      if (res.images.isNotEmpty && built.containsKey(res.number))
        if (switch (when) {
          // 画面の外（上）だが組まれている行。
          _When.above => built[res.number]! < 0,
          // 画面の中で、目印より上にある行。
          _When.inside => built[res.number]! >= 0 && res.number < marker,
          // 目印より下。
          _When.below => res.number > marker,
          // 組んであるもの全部（スレを開いた直後に近い形）。
          _When.all => true,
        })
          res.number,
  ];

  if (shotBefore != null) await _shoot(tester, shotBefore);
  final before = tester.getTopLeft(find.byKey(ValueKey('res-$marker'))).dy;

  loaded.load(targets);
  await tester.pump();

  // 目印ごと画面の外へ飛ぶことがある。そのときは組み直しの対象から外れて
  // ウィジェットが消えるので、位置は取れない（＝ずれが画面 1 枚を超えた）。
  final finder = find.byKey(ValueKey('res-$marker'));
  final after = finder.evaluate().isEmpty ? null : tester.getTopLeft(finder).dy;
  if (shotAfter != null) await _shoot(tester, shotAfter);
  return _Result(
    shift: after == null ? null : after - before,
    // 目印より下で増えたぶんは目印を動かしようがないので、突き合わせる相手は
    // 「目印より上で増えた高さ」。
    added: _addedHeight(thread, [
      for (final n in targets)
        if (n < marker) n,
    ], natural: natural),
    floor: after == null ? _screen.height - before : null,
    dragBy: dragBy,
    marker: marker,
    onScreen: '${onScreen.first}〜${onScreen.last}',
    built: '${built.keys.reduce(math.min)}〜${built.keys.reduce(math.max)}',
    targets: targets,
  );
}

/// 1 回ぶんの測定。ずれ量だけだと「何も起きていないから 0」なのか
/// 「起きたが動かない」のかが区別できないので、対象の行数も返す。
class _Result {
  const _Result({
    required this.shift,
    required this.added,
    required this.floor,
    required this.dragBy,
    required this.marker,
    required this.onScreen,
    required this.built,
    required this.targets,
  });

  /// 目印が動いた量。目印が画面の外へ飛んで測れなかったら null。
  final double? shift;

  /// 悪さの度合い。飛んで測れなかったものは最悪として扱う。
  double get severity => shift?.abs() ?? double.infinity;

  /// 絵が届いたことで**増えた高さの合計**（目印より上のぶん）。ずれの上限。
  final double added;

  /// 目印が画面の外へ飛んで測れなかったとき、最低でも動いたと言える量。
  final double? floor;

  /// どれだけ送った状態で測ったか。どこを見ているかでずれ方は変わるので、
  /// 何通りか試して**いちばん悪いもの**を採る。
  final double dragBy;

  final int marker;
  final String onScreen;
  final String built;
  final List<int> targets;

  String get _shift => switch (shift) {
    null => '画面の外へ飛んだ（+${floor!.toStringAsFixed(0)}dp 以上）',
    final s when s.abs() < 0.01 => '0（動かない）',
    final s => '${s > 0 ? "+" : ""}${s.toStringAsFixed(0)}dp',
  };

  @override
  String toString() =>
      'ずれ $_shift  ／ 伸びた高さ ${added.toStringAsFixed(0)}dp'
      '・${dragBy.toStringAsFixed(0)}dp 送った所'
      '・目印 >>$marker・画面 $onScreen（組んだ範囲 $built）'
      '・絵を届かせたレス ${targets.isEmpty ? "なし" : targets.join(",")}';
}

Future<void> _shoot(WidgetTester tester, String out) async {
  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  final file = File(out)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  setUpAll(loadPreviewFonts);

  // レスの組み合わせごとに、絵が届くと何 dp 伸びるか。どの規則がどれだけ効いて
  // いるかは、スレ全体の実測より先にこの表を見た方が早い。
  test('レスの組み合わせごとの伸び', () {
    const cell = 160.0;
    const maxWidth = 340.0;
    const cases = <String, List<double>>{
      '1枚・縦長 3:4': [3 / 4],
      '1枚・縦長 9:19（スクショ）': [9 / 19],
      '1枚・横長 16:9': [16 / 9],
      '1枚・横長 4:1': [4],
      '2枚・縦長どうし': [3 / 4, 3 / 4],
      '2枚・少し横長どうし 5:4': [1.25, 1.25],
      '2枚・横長どうし 16:9': [16 / 9, 16 / 9],
      '2枚・縦長＋横長': [3 / 4, 16 / 9],
      '3枚・まぜ': [3 / 4, 16 / 9, 1],
      '4枚・まぜ': [9 / 16, 16 / 9, 3 / 4, 9 / 19],
      '5枚・まぜ（升目に落ちる）': [3 / 4, 16 / 9, 1, 9 / 16, 3 / 4],
    };
    for (final entry in cases.entries) {
      final boxes = [
        for (final ratio in entry.value)
          thumbBox(
            cell: cell,
            maxWidth: maxWidth,
            ratio: ratio,
            count: entry.value.length,
          ),
      ];
      final square = List.filled(boxes.length, const Size.square(cell));
      final grew = _wrapHeight(boxes, maxWidth) - _wrapHeight(square, maxWidth);
      final grown = switch (grew) {
        0 => '動かない',
        // 縮む向き（下が上がる）は、伸びて押し下げるより気になりにくい。
        < 0 => '${grew.toStringAsFixed(0)}dp（縮む）',
        _ => '+${grew.toStringAsFixed(0)}dp',
      };
      // ignore: avoid_print
      print('${entry.key.padRight(26)} $grown');
    }
  });

  // 読み込みの前後を 1 組だけ撮る。数字だけだと「どう見えるか」が分からない。
  testWidgets('読み込み前後の見た目を撮る', (tester) async {
    await _measure(
      tester,
      natural: true,
      when: _When.inside,
      dragBy: 700,
      shotBefore: '$dir/thumb_shift_before.png',
      shotAfter: '$dir/thumb_shift_after.png',
    );
  });

  for (final natural in [false, true]) {
    final name = natural ? '今回の案（thumbBox）' : '今のまま（正方形）';
    for (final when in _When.values) {
      testWidgets('$name / ${when.label}', (tester) async {
        // どこを見ているかで当たり外れが出る（絵のあるレスが目印より上に来る
        // かどうか）。何通りか送って、いちばん悪かったものを採る。
        _Result? worst;
        for (final dragBy in const [400.0, 700.0, 1000.0, 1300.0]) {
          final result = await _measure(
            tester,
            natural: natural,
            when: when,
            dragBy: dragBy,
          );
          if (worst == null || result.severity > worst.severity) {
            worst = result;
          }
        }
        // ignore: avoid_print
        print('$name  ${when.label}\n    $worst');
      });
    }
  }
}
