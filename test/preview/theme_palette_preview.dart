/// **カラーテーマの候補**を横に並べて撮る、検討用スクリプト。
///
/// **通常のテストでは走らない**（`_test.dart` で終わらないので `flutter test` の
/// 対象外）。撮るときだけパスを明示する:
///
/// ```
/// flutter test test/preview/theme_palette_preview.dart
/// ```
///
/// 出力は `notes/preview/palette_*.png`。`OUT` で出力先を変えられる。
///
/// 並べるのは本体の [ThreadScreen] / [ThreadListScreen] そのもので、渡す
/// [ColorScheme] だけをこの枠が差し替える。テーマの組み立ては本体の
/// [ElecTheme.themeFrom] を通すので、色以外の作りは本番と同じになる。
///
/// ## 前提（1 周目で決めたこと）
/// - 面は**無彩**に寄せる。`ColorScheme.fromSeed` そのままだと面にも種の色みが
///   乗り、「Material の既定のアプリ」に見える。
/// - **押すもの**（スレ立て FAB・送信ボタン・OK）は [ElecColors.action] へ分けて
///   無彩にした。アクセントは**意味のあるところ**にだけ残す:
///   リンク・`>>N`・自分宛の帯・新着バッジ・勢い・連投 ID・選択中の印。
/// - 「自分のもの」（自分で立てたスレの帯とバッジ）は `tertiary` だが、これも
///   無彩寄りの暖灰に落とした。色の出る場所をさらに減らすため。
///
/// ## 何を比べているか
/// 残ったアクセント 1 色の**色相**だけを振る。面と操作系は共通なので、差は
/// リンク・`>>N`・新着・自分宛にしか出ない。
///
/// **採ったのは「無彩」**（[ElecTheme.lightScheme] / [ElecTheme.darkScheme]）。
/// 色相で差を付けない代わり、新着バッジのように発見してほしいものは
/// ベタ塗り＋白抜きにして濃度で立たせる。先頭の列がその採用テーマで、右に
/// 色相を入れた場合の候補を残してある——色を足したくなったときの出発点:
///
///   - **テラコッタ**——焼き物の赤茶。白黒のアイコンと相性がよく、青より柔らかい。
///   - **アンバー**——黄〜オレンジ。暗いテーマでよく映えるが、明るいテーマでは
///     白地でのコントラストを取りづらい。
///   - **藍**——元の路線を無彩の面に載せ替えたもの。
///
/// 暗いテーマの**地の濃さ**は別の枠（`palette_dark_levels.png`）で 3 段比べた。
/// 面の段差（ヘッダ・下書き欄・カード）が読めるかが基準で、**#0B0B0D** を採った
/// ——真っ黒はすりガラスの島が地に沈んで消える。
///
/// 見るところ:
///   - `>>N`・リンク・新着バッジが、色を見ただけで他と区別できるか。
///   - identicon（ID の絵）の彩度とアクセントがぶつからないか。
///   - 黒（白）の FAB・送信ボタンが、地から浮きすぎ・沈みすぎないか。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/read_history.dart';
import 'package:elec/src/net/thread_view_settings.dart';
import 'package:elec/src/ui/thread_list_screen.dart';
import 'package:elec/src/ui/thread_screen.dart';
import 'package:elec/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jis0208/jis0208.dart';

import '../support/preview_fonts.dart';

// ---------------------------------------------------------------------------
// 見本のスレ
// ---------------------------------------------------------------------------

final _win31j = Windows31JCodec();
List<int> _datLine(String s) => [..._win31j.encode(s), 0x0A];

class _StaticFetcher implements HttpFetcher {
  _StaticFetcher(this.body);
  final List<int> body;

  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) => Future.value(
    FetchResponse(statusCode: 200, bodyBytes: body, headers: const {}),
  );
}

/// 色の手掛かりが一通り出るスレを組む。
///
/// **1 画面に収まる先頭 12 件へ意図的に詰め込む**——長文・コテハン・返信数の多い
/// レス・連投 ID・`>>N`・リンク・自分のレス・自分宛。返信数のバッジを立てるための
/// 返信は、画面に入らない 13 件目以降へ回してある。
List<int> _dat() {
  const ids = ['aB3xYz9Qw', 'Kd8mN2pLr', 'Qw7vT4sZx', 'Hj5cB1nMe'];
  final bytes = <int>[];
  for (var i = 1; i <= 40; i++) {
    final body = switch (i) {
      1 =>
        '色の候補を見るためのスレ。ここは長めの本文で、折り返したときの行間と'
            '文字の濃さを見る。',
      2 => 'まんげいらない',
      3 => '返信を多く集めたレス。番号の色が上がる。',
      4 => 'さらに返信を集めたレス。色が一段上がる。',
      5 => 'コテハンの名前はここに出る',
      6 => 'リンクで終わるレス。<br>https://example.com/some/page',
      7 => '自分の書き込み。面に薄く色が敷かれる。',
      8 => '>>7 自分宛のレス。左に帯が付く。',
      9 => '&gt;&gt;3<br>行を分けて返信するとここに引用が入る。',
      10 => '連投した2本目。ID の隣に何本目かが出る。',
      11 => '近藤さんの性癖',
      12 => 'この番組もう10年やってるらしい',
      _ when i <= 18 => '>>3 なるほど',
      _ => '>>4 それな',
    };
    final name = switch (i) {
      5 => 'ながい名前のコテハン◆Ab12Cd34Ef',
      _ => 'エッヂの名無し',
    };
    // 連投を作る（レス 2 と 10 を同じ ID にする）。
    final id = switch (i) {
      2 || 10 => 'Kd8mN2pLr',
      _ => ids[i % ids.length],
    };
    final date = '2025/11/03(月) 02:14:${i.toString().padLeft(2, '0')}.907';
    bytes.addAll(
      _datLine('$name<><>$date ID:$id<> $body <>${i == 1 ? 'スレタイ' : ''}'),
    );
  }
  return bytes;
}

/// 一覧に出したい状態を一通り並べた subject.txt。
String _subject() =>
    '${[
      '1762103601.dat<>実況の勢いがあるスレ。長いスレタイの折り返しもここで見る (842)',
      '1762103602.dat<>既読で新着があるスレ (317)',
      '1762103604.dat<>完走したスレ (1000)',
      '1762103605.dat<>一覧で見たがまだ開いていないスレ (12)',
      '1762103607.dat<>一覧でも初めて見るスレ (2)',
      '1762103606.dat<>自分で立てたスレ (3)',
    ].join('\n')}\n';

class _SubjectFetcher implements HttpFetcher {
  @override
  Future<FetchResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) => Future.value(
    FetchResponse(
      statusCode: 200,
      bodyBytes: _win31j.encode(_subject()),
      headers: const {'last-modified': 'LM'},
    ),
  );
}

// ---------------------------------------------------------------------------
// 面（無彩）
// ---------------------------------------------------------------------------

/// 地とその上に積む面。**アクセントの候補どうしでは共通**——振るのは色相だけ。
class _Surfaces {
  const _Surfaces({
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.highest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
  });

  final Color surface;
  final Color lowest;
  final Color low;
  final Color container;
  final Color high;
  final Color highest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
}

const _lightSurfaces = _Surfaces(
  surface: Color(0xFFFCFCFD),
  lowest: Color(0xFFFFFFFF),
  low: Color(0xFFF6F6F8),
  container: Color(0xFFF1F1F4),
  high: Color(0xFFEAEAEE),
  highest: Color(0xFFE4E4E9),
  onSurface: Color(0xFF17171A),
  onSurfaceVariant: Color(0xFF5C5C66),
  outline: Color(0xFFA9A9B4),
  outlineVariant: Color(0xFFDEDEE3),
);

/// 暗いテーマの地の濃さ。3 段用意して別枠で比べる。
enum _Dark {
  /// 今と同じくらい。面の段差をいちばん付けやすい。
  soft('やわらかい黒 #121316'),

  /// 一段沈めた黒。まだ段差は付けられる。
  deep('深い黒 #0B0B0D'),

  /// 真っ黒。有機 EL で地が消える。
  pure('真っ黒 #000000');

  const _Dark(this.label);
  final String label;
}

_Surfaces _darkSurfaces(_Dark level) => switch (level) {
  _Dark.soft => const _Surfaces(
    surface: Color(0xFF121316),
    lowest: Color(0xFF0C0D0F),
    low: Color(0xFF16171A),
    container: Color(0xFF1B1C20),
    high: Color(0xFF212328),
    highest: Color(0xFF292B31),
    onSurface: Color(0xFFE7E7EB),
    onSurfaceVariant: Color(0xFF9C9CA6),
    outline: Color(0xFF5A5A64),
    outlineVariant: Color(0xFF33343A),
  ),
  _Dark.deep => const _Surfaces(
    surface: Color(0xFF0B0B0D),
    lowest: Color(0xFF060607),
    low: Color(0xFF101013),
    container: Color(0xFF161619),
    high: Color(0xFF1D1E22),
    highest: Color(0xFF25262B),
    onSurface: Color(0xFFE7E7EB),
    onSurfaceVariant: Color(0xFF98989F),
    outline: Color(0xFF56565E),
    outlineVariant: Color(0xFF2C2D32),
  ),
  _Dark.pure => const _Surfaces(
    surface: Color(0xFF000000),
    lowest: Color(0xFF000000),
    low: Color(0xFF0A0A0C),
    container: Color(0xFF121215),
    high: Color(0xFF1A1A1E),
    highest: Color(0xFF232328),
    onSurface: Color(0xFFE9E9ED),
    onSurfaceVariant: Color(0xFF97979F),
    outline: Color(0xFF56565E),
    outlineVariant: Color(0xFF2B2B31),
  ),
};

// ---------------------------------------------------------------------------
// アクセント（意味の色）
// ---------------------------------------------------------------------------

/// 意味を持つところにだけ出る 1 色。明るい／暗いの対で持つ。
class _Accent {
  const _Accent(
    this.label, {
    required this.light,
    required this.lightContainer,
    required this.onLightContainer,
    required this.dark,
    required this.darkContainer,
    required this.onDarkContainer,
  });

  final String label;
  final Color light;
  final Color lightContainer;
  final Color onLightContainer;
  final Color dark;
  final Color darkContainer;
  final Color onDarkContainer;

  Color of(Brightness b) => b == Brightness.light ? light : dark;
  Color container(Brightness b) =>
      b == Brightness.light ? lightContainer : darkContainer;
  Color onContainer(Brightness b) =>
      b == Brightness.light ? onLightContainer : onDarkContainer;
}

/// 焼き物の赤茶。白黒のアイコンと相性がよく、青より柔らかい。
const _terracotta = _Accent(
  'テラコッタ',
  light: Color(0xFFA9502C),
  lightContainer: Color(0xFFF6E3D8),
  onLightContainer: Color(0xFF46200F),
  dark: Color(0xFFE9A183),
  darkContainer: Color(0xFF4A3125),
  onDarkContainer: Color(0xFFFBE0D2),
);

/// 黄〜オレンジ。暗いテーマでよく映える。**明るいテーマが弱点**で、この濃さ
/// （#B26A00）でも白地に 4.2:1 しかない——本文と同じ大きさのリンクに使うには
/// 4.5:1 に届かない。採るならもう一段落として #A05F00 前後まで沈める必要がある。
const _amber = _Accent(
  'アンバー',
  light: Color(0xFFB26A00),
  lightContainer: Color(0xFFF8E7CC),
  onLightContainer: Color(0xFF4A2E00),
  dark: Color(0xFFF0B24A),
  darkContainer: Color(0xFF4E3814),
  onDarkContainer: Color(0xFFFCE3B8),
);

/// 今の路線（インディゴ）を無彩の面へ載せ替えただけのもの。基準として置く。
const _indigo = _Accent(
  '藍（今の色）',
  light: Color(0xFF3A5BD9),
  lightContainer: Color(0xFFDEE4FD),
  onLightContainer: Color(0xFF0E1F55),
  dark: Color(0xFF93A8FF),
  darkContainer: Color(0xFF263474),
  onDarkContainer: Color(0xFFDCE2FF),
);

/// 「自分のもの」（自分で立てたスレの帯とバッジ）。**アクセントとは別に、無彩
/// 寄りの暖灰**に落としてある——色の出る場所をさらに減らすため。
({Color tertiary, Color container, Color onContainer}) _own(Brightness b) =>
    b == Brightness.light
    ? (
        tertiary: const Color(0xFF6B6259),
        container: const Color(0xFFEAE7E3),
        onContainer: const Color(0xFF2A2622),
      )
    : (
        tertiary: const Color(0xFFA8A29A),
        container: const Color(0xFF2C2A27),
        onContainer: const Color(0xFFE8E5E0),
      );

/// 面とアクセントから [ColorScheme] を組む。埋めていない役割は、アクセントを
/// 種にして [ColorScheme.fromSeed] が作った値をそのまま使う。
ColorScheme _scheme(Brightness brightness, _Surfaces s, _Accent a) {
  final own = _own(brightness);
  return ColorScheme.fromSeed(
    seedColor: a.of(brightness),
    brightness: brightness,
  ).copyWith(
    primary: a.of(brightness),
    onPrimary: brightness == Brightness.light
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF15151A),
    primaryContainer: a.container(brightness),
    onPrimaryContainer: a.onContainer(brightness),
    secondaryContainer: s.high,
    onSecondaryContainer: s.onSurface,
    tertiary: own.tertiary,
    tertiaryContainer: own.container,
    onTertiaryContainer: own.onContainer,
    error: brightness == Brightness.light
        ? const Color(0xFFC0392B)
        : const Color(0xFFFF6B5E),
    surface: s.surface,
    surfaceDim: s.high,
    surfaceBright: s.lowest,
    surfaceContainerLowest: s.lowest,
    surfaceContainerLow: s.low,
    surfaceContainer: s.container,
    surfaceContainerHigh: s.high,
    surfaceContainerHighest: s.highest,
    onSurface: s.onSurface,
    onSurfaceVariant: s.onSurfaceVariant,
    outline: s.outline,
    outlineVariant: s.outlineVariant,
  );
}

ThemeData _theme(Brightness brightness, _Surfaces s, _Accent a) =>
    ElecTheme.themeFrom(_scheme(brightness, s, a));

/// 色相を振った列。先頭は**採用テーマ**（無彩）で、残りは色を足す場合の候補。
List<(String, ThemeData)> _accentColumns(Brightness brightness) {
  final surfaces = brightness == Brightness.light
      ? _lightSurfaces
      : _darkSurfaces(_Dark.deep);
  return [
    (
      '無彩（採用）',
      brightness == Brightness.light ? ElecTheme.light() : ElecTheme.dark(),
    ),
    for (final a in [_terracotta, _amber, _indigo])
      (a.label, _theme(brightness, surfaces, a)),
  ];
}

/// 暗い地の濃さを振った列（アクセントはテラコッタで固定）。
List<(String, ThemeData)> _darkLevelColumns() => [
  for (final level in _Dark.values)
    (level.label, _theme(Brightness.dark, _darkSurfaces(level), _terracotta)),
];

// ---------------------------------------------------------------------------
// 撮る枠
// ---------------------------------------------------------------------------

const _columnWidth = 380.0;
const _columnHeight = 860.0;
const _captionHeight = 34.0;
const _gap = 12.0;

Future<void> _shoot(
  WidgetTester tester,
  Brightness brightness,
  String out, {
  required List<(String, ThemeData)> columns,
  required Widget Function() screen,
  required Future<void> Function(WidgetTester) settle,
}) async {
  final width = _columnWidth * columns.length + _gap * (columns.length + 1);
  final height = _columnHeight + _captionHeight + _gap * 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  // 枠そのものの地色。候補の面に引きずられないよう、明るさなりの中間灰にする。
  final sheet = brightness == Brightness.light
      ? const Color(0xFFD8D8DC)
      : const Color(0xFF2A2A2E);
  final captionColor = brightness == Brightness.light
      ? const Color(0xFF1B1B1F)
      : const Color(0xFFE7E7EB);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ColoredBox(
          color: sheet,
          child: Padding(
            padding: const EdgeInsets.all(_gap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, theme) in columns) ...[
                  SizedBox(
                    width: _columnWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: _captionHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              label,
                              style: TextStyle(
                                color: captionColor,
                                fontFamily: japaneseTestFontFamily,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: _columnHeight,
                          // 端末 1 台ぶんとして描かせる。親の広い画面をそのまま
                          // 見せると、幅で切り替わる組み方が別物になる。
                          child: MediaQuery(
                            data: const MediaQueryData(
                              size: Size(_columnWidth, _columnHeight),
                              devicePixelRatio: 2,
                            ),
                            child: Theme(data: theme, child: screen()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (label != columns.last.$1) const SizedBox(width: _gap),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester);

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

/// スレ画面を組む。既読・自分のレスは候補間で同じにする（色だけを見たいので）。
Future<Widget Function()> _threadScreen() async {
  final history = ReadHistory(MemoryReadHistoryStorage());
  await history.markOwnPost('1762103691', 7);
  final view = ThreadViewSettings(MemoryThreadViewSettingsStorage());
  // 番号順で撮る。ツリー表示だと返信がぶら下がって、見せたいレス（コテハン・
  // リンク・自分のレス）が 1 画面目から外れる。
  await view.setLayout(ThreadLayout.number);
  return () => ThreadScreen(
    threadKey: '1762103691',
    threadTitle: '色の候補を並べて見るスレ',
    onClose: () {},
    fetcher: _StaticFetcher(_dat()),
    // 撮っている間に取り直しが走らないよう長くする。
    pollInterval: const Duration(hours: 1),
    readHistory: history,
    threadViewSettings: view,
    defaultName: Board.eddibb.defaultName,
  );
}

/// スレ一覧を組む。既読・新着・完走・自分のスレ・新顔が一通り出る並びにする。
Future<Widget Function()> _listScreen() async {
  final history = ReadHistory(MemoryReadHistoryStorage());
  await history.markOpenedThread(
    const ThreadSummary(
      key: '1762103602',
      title: '既読で新着があるスレ',
      resCount: 300,
      capName: null,
    ),
  );
  await history.markRead('1762103602', 300);
  await history.markOwnThread('1762103606');
  await history.markListed([
    '1762103601',
    '1762103604',
    '1762103605',
    '1762103606',
  ]);
  return () => ThreadListScreen(
    // 取得は列ごとに別の口を持たせる（同じものを使い回すと状態が混ざる）。
    fetcher: _SubjectFetcher(),
    pollInterval: const Duration(hours: 1),
    readHistory: history,
  );
}

void main() {
  final dir = Platform.environment['OUT'] ?? 'notes/preview';

  // フォント読み込みはテスト本体の外で（fake async のゾーンに入れない）。
  setUpAll(loadPreviewFonts);

  // 取得（Future）の解決 → 初回レイアウト → つまみのフェードイン、の 3 段階分。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('thread light', (tester) async {
    await _shoot(
      tester,
      Brightness.light,
      '$dir/palette_light.png',
      columns: _accentColumns(Brightness.light),
      screen: await _threadScreen(),
      settle: settle,
    );
  });

  testWidgets('thread dark', (tester) async {
    await _shoot(
      tester,
      Brightness.dark,
      '$dir/palette_dark.png',
      columns: _accentColumns(Brightness.dark),
      screen: await _threadScreen(),
      settle: settle,
    );
  });

  testWidgets('list light', (tester) async {
    await _shoot(
      tester,
      Brightness.light,
      '$dir/palette_list_light.png',
      columns: _accentColumns(Brightness.light),
      screen: await _listScreen(),
      settle: settle,
    );
  });

  testWidgets('list dark', (tester) async {
    await _shoot(
      tester,
      Brightness.dark,
      '$dir/palette_list_dark.png',
      columns: _accentColumns(Brightness.dark),
      screen: await _listScreen(),
      settle: settle,
    );
  });

  // 暗い地の濃さ 3 段。面の段差（ヘッダ・下書き欄・カード）が読めるかで決める。
  testWidgets('dark levels', (tester) async {
    await _shoot(
      tester,
      Brightness.dark,
      '$dir/palette_dark_levels.png',
      columns: _darkLevelColumns(),
      screen: await _threadScreen(),
      settle: settle,
    );
  });

  testWidgets('dark levels list', (tester) async {
    await _shoot(
      tester,
      Brightness.dark,
      '$dir/palette_dark_levels_list.png',
      columns: _darkLevelColumns(),
      screen: await _listScreen(),
      settle: settle,
    );
  });
}
