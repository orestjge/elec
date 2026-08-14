import 'package:edge_core/edge_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'id_icon.dart';
import 'link_urls.dart';

/// 表示用に本文の前後空白を整える。AA はインデントや上下の余白が絵の一部に
/// なるためそのまま残し、それ以外の普通のレスだけ [String.trim] で詰める。
String trimUnlessAsciiArt(String text) =>
    looksLikeAsciiArt(text) ? text : text.trim();

/// 本文の改行。dat のまま（`<br>`）でも、表示用に直したあと（`\n`）でも拾う。
final _bodyLineBreakRe = RegExp(r'<br\s*/?>|\r?\n', caseSensitive: false);

/// `>>N` だけでできている行（`>>5 >>7` のように並んでいてもよい）。
final _quoteLineRe = RegExp(
  '^(?:(?:&gt;&gt;|>>)$resAnchorSpecPattern[ \\t　]*)+\$',
);

/// 行の中の `>>N` ひとつ。
final _anchorRe = RegExp('(?:&gt;&gt;|>>)($resAnchorSpecPattern)');

/// 本文の中で**行を単独で占めている `>>N`**（`>>5` だけで改行している行）。
///
/// 行を丸ごと使って相手を指しているなら、それは書いた人が「ここで誰かに返す」と
/// 区切ったということ。返信先の再掲をレスの手前ではなく**その位置へ**差し込める
/// （[PostBodyQuote]）ので、`>>5 それな` のように文の頭に付いているだけのものと
/// 分けて拾う。
///
/// 返すのは行ごとの範囲（[start]–[end]。改行そのものは含まない）と、その行が
/// 指しているレス番号。[text] は dat のまま（`<br>` 区切り・`&gt;&gt;`）でも、
/// 表示用に直したあと（`\n` 区切り・`>>`）でもよい。
List<({int start, int end, List<int> numbers})> quoteLinesIn(String text) {
  final lines = <({int start, int end, List<int> numbers})>[];
  var start = 0;
  for (final br in [..._bodyLineBreakRe.allMatches(text), null]) {
    final end = br?.start ?? text.length;
    final line = text.substring(start, end).trim();
    if (line.isNotEmpty && _quoteLineRe.hasMatch(line)) {
      final numbers = [
        for (final m in _anchorRe.allMatches(line))
          ...resNumbersInAnchor(m.group(1)!),
      ];
      if (numbers.isNotEmpty) {
        lines.add((start: start, end: end, numbers: numbers));
      }
    }
    if (br == null) break;
    start = br.end;
  }
  return lines;
}

/// [quoteLinesIn] が拾った番号だけを集めたもの。行の位置が要らない側（一覧の
/// 行組み）はこちらを使う。
Set<int> standaloneQuoteLineNumbers(String text) => {
  for (final line in quoteLinesIn(text)) ...line.numbers,
};

/// AA を出すときの字。MS Pゴシック互換寄りの同梱フォント（Monapo）で、行間と
/// 字送りを AA が組まれた前提（1 行 1 行が詰まって 1 枚の絵になる）に合わせる。
///
/// 大きさは呼ぶ側の [base] のまま。本文でも引用行でも同じ形で出したいので、
/// 「どのフォントで・どれだけ詰めるか」だけをここに置く。
TextStyle asciiArtStyle(TextStyle base) =>
    base.copyWith(fontFamily: 'Monapo', height: 1.15, letterSpacing: 0);

/// 画面に収めるために AA を縮めるとき、字の大きさをここまでは下げてよいという
/// 下限（論理ピクセル）。
///
/// AA は PC の画面幅を前提に組まれていて、1 行が全角 40 字を超えるものも珍しく
/// ない。本文の 15px のままスマホ（本文の幅がおよそ 340）に出すと半分ほどが枠の
/// 外に出て、横へ振らないと絵にならない。かといって収まるまで際限なく縮めると、
/// 今度は形が潰れて何の絵か分からなくなる。
///
/// 8px は「字は読めないが、輪郭は追える」あたり。ここで縮小を止めて、はみ出す
/// 分はこれまでどおり横スクロールに任せる（[ResBody]）。
const double minAsciiArtFontSize = 8;

/// AA を幅 [maxWidth] に収めるための縮小率。
///
/// 元の幅 [naturalWidth] が収まっていれば 1。**元より大きくはしない**——小さい
/// AA は本文と同じ大きさのまま出る。はみ出すときは縦横同率で縮め、字が
/// [minFontSize] を割るところで止める（それ以上は横スクロールで見せる）。
double asciiArtFitScale({
  required double naturalWidth,
  required double maxWidth,
  required double fontSize,
  double minFontSize = minAsciiArtFontSize,
}) {
  if (naturalWidth <= 0 || fontSize <= 0) return 1;
  if (!maxWidth.isFinite || maxWidth <= 0) return 1;
  if (naturalWidth <= maxWidth) return 1;
  final floor = fontSize <= minFontSize ? 1.0 : minFontSize / fontSize;
  return (maxWidth / naturalWidth).clamp(floor, 1.0);
}

/// 折り返さずに組んだとき、[text] が要る幅（いちばん長い行の幅）。
///
/// リンクや ID の装飾は幅を変えないので、素の文字列のまま測ってよい。
double asciiArtNaturalWidth(
  BuildContext context,
  String text,
  TextStyle style,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// AA（アスキーアート）らしい本文だけ、MS Pゴシック互換寄りの同梱フォントで
/// 表示する。単発の顔文字まで巻き込まないよう、AA 記号を含む行数を見る。
bool looksLikeAsciiArt(String text) {
  final lines = _textForAsciiArtDetection(
    text,
  ).split('\n').where((line) => line.trim().isNotEmpty).toList(growable: false);
  if (lines.isEmpty) return false;

  final textSize = lines.fold<int>(0, (sum, line) => sum + line.runes.length);
  final rleRate = _runLengthEncodedLength(lines) / textSize;
  var structuralLines = 0;
  var symbolCount = 0;
  var spaceCount = 0;
  var maxWidth = 0;
  for (final line in lines) {
    final metrics = _AsciiArtLineMetrics(line);
    if (metrics.isStructural) structuralLines++;
    symbolCount += metrics.symbolCount;
    spaceCount += metrics.spaceCount;
    if (metrics.width > maxWidth) maxWidth = metrics.width;
  }

  final symbolRatio = symbolCount / textSize;
  final spaceRatio = spaceCount / textSize;

  if (lines.length >= 3) {
    return structuralLines >= 2 &&
        maxWidth >= 10 &&
        (symbolRatio >= 0.22 || spaceRatio >= 0.18 || rleRate <= 1.72);
  }

  if (lines.length == 2) {
    return structuralLines == 2 &&
        maxWidth >= 12 &&
        symbolRatio >= 0.28 &&
        (spaceRatio >= 0.16 || rleRate <= 1.68);
  }

  final metrics = _AsciiArtLineMetrics(lines.single);
  return metrics.width >= 32 &&
      metrics.symbolRatio >= 0.42 &&
      (metrics.hasRepeatedSymbol || metrics.hasWideSpacing);
}

String _textForAsciiArtDetection(String text) {
  // URL は `/`, `:`, `?`, `&`, `=` などを多く含み、AA の構造記号として
  // 誤カウントされやすい。AA 判定では本文の形だけを見たいので中立化する。
  return text.replaceAll(linkUrlRe, ' ');
}

class _AsciiArtLineMetrics {
  _AsciiArtLineMetrics(String line)
    : width = _visualWidth(line),
      symbolCount = _aaSymbolCount(line),
      spaceCount = _spaceCount(line),
      leadingSpaces = _leadingSpaceCount(line),
      hasFullWidthSpace = line.contains('　'),
      hasRepeatedSymbol = _hasRepeatedAsciiArtSymbol(line),
      hasWideSpacing = _hasWideSpacing(line);

  final int width;
  final int symbolCount;
  final int spaceCount;
  final int leadingSpaces;
  final bool hasFullWidthSpace;
  final bool hasRepeatedSymbol;
  final bool hasWideSpacing;

  double get symbolRatio => symbolCount / width;

  bool get isStructural {
    if (width < 4) return false;
    if (symbolCount >= 4 && symbolRatio >= 0.2) return true;
    if (hasFullWidthSpace && symbolCount >= 2) return true;
    if (leadingSpaces >= 2 && symbolCount >= 2) return true;
    if (hasRepeatedSymbol && symbolCount >= 3) return true;
    return hasWideSpacing && symbolCount >= 3;
  }
}

final _aaSymbolRunes =
    '　＿￣ー─━│┃┌┐└┘├┤┬┴┼┏┓┗┛┣┫┳┻╋'
            '／＼/\\|｜∧∨ＶvＷwＭm（）()[]［］{}｛｝<>＜＞'
            '・.．,:;；"\'`´｀~～^＾-‐=＝+＋*＊'
        .runes
        .toSet();

int _aaSymbolCount(String line) {
  var count = 0;
  for (final rune in line.runes) {
    if (_aaSymbolRunes.contains(rune)) count++;
  }
  return count;
}

int _spaceCount(String line) {
  var count = 0;
  for (final rune in line.runes) {
    if (rune == 0x20 || rune == 0x3000 || rune == 0x09) count++;
  }
  return count;
}

int _leadingSpaceCount(String line) {
  var count = 0;
  for (final rune in line.runes) {
    if (rune != 0x20 && rune != 0x3000 && rune != 0x09) break;
    count++;
  }
  return count;
}

int _visualWidth(String line) {
  var width = 0;
  for (final rune in line.runes) {
    width += _isHalfWidth(rune) ? 1 : 2;
  }
  return width;
}

bool _isHalfWidth(int rune) => rune <= 0x7E || 0xFF61 <= rune && rune <= 0xFF9F;

bool _hasRepeatedAsciiArtSymbol(String line) {
  int? previous;
  var run = 0;
  for (final rune in line.runes) {
    if (!_aaSymbolRunes.contains(rune)) {
      previous = null;
      run = 0;
      continue;
    }
    if (rune == previous) {
      run++;
    } else {
      previous = rune;
      run = 1;
    }
    if (run >= 3) return true;
  }
  return false;
}

bool _hasWideSpacing(String line) =>
    line.contains('  ') || line.contains('\t') || line.contains('　');

int _runLengthEncodedLength(List<String> lines) {
  var length = 0;
  for (final line in lines) {
    int? previous;
    var run = 0;
    for (final rune in line.runes) {
      if (previous == null || rune == previous) {
        run++;
      } else {
        length += 1 + run.toString().length;
        run = 1;
      }
      previous = rune;
    }
    if (previous != null) {
      length += 1 + run.toString().length;
    }
  }
  return length;
}

/// [text] のうち [queryLower]（小文字化済み・非空）に一致する箇所へ
/// [highlightStyle] を当てた span 列を [out] に追記する。残りは素の span。
/// スレ内検索で「どこが一致したか」を可視化するのに使う。
void appendHighlighted(
  List<InlineSpan> out,
  String text,
  String queryLower,
  TextStyle highlightStyle,
) {
  if (text.isEmpty) return;
  if (queryLower.isEmpty) {
    out.add(TextSpan(text: text));
    return;
  }
  final lower = text.toLowerCase();
  var i = 0;
  while (i < text.length) {
    final idx = lower.indexOf(queryLower, i);
    if (idx < 0) {
      out.add(TextSpan(text: text.substring(i)));
      return;
    }
    if (idx > i) out.add(TextSpan(text: text.substring(i, idx)));
    final end = idx + queryLower.length;
    out.add(TextSpan(text: text.substring(idx, end), style: highlightStyle));
    i = end;
  }
}

/// スレ内検索の一致ハイライト色。地の文の色は変えず背景だけ薄く敷く（半透明の
/// ため明暗どちらのテーマでも本文が読める）。
TextStyle searchHighlightStyle(ColorScheme scheme) =>
    TextStyle(backgroundColor: scheme.tertiary.withValues(alpha: 0.32));

/// 本文中に書かれた ID を拾う。
///
/// 他のレスを丸ごと貼るとヘッダ行がそのまま本文に入り（`24 名無し 2026/08/08(土)
/// 00:00:00.000 ID:X9Jh576dp`）、ID が地の文に埋もれる。ヘッダの ID 欄と同じ
/// identicon を添えれば、貼られた先でも「誰か」が同じ絵で分かる。
///
/// ID に使える字は英数字だけではない。掲示板の ID は SHA-1 の base64 の頭を
/// 切ったもの（eddist なら `+` を `.` に置換したうえで 9 文字）なので、`.` `/`
/// `+` が混じり、しかもそれが先頭・末尾に来ることがある（`ID:.fNwf8r5`）。
/// 英数字で挟まれた形だけを ID とすると、こういう ID を取りこぼしたり、
/// `ID:0.fNwf8.` を `0.fNwf8` と読み違えて別人の絵を出したりする。`-` は
/// base64 に出てこないので入れない（`ID:non-existent` のような誤爆を防ぐ）。
///
/// 誤爆を避けるため、直前が英数字のもの（`GRID:...`）は外し、英数字を 1 つ以上
/// 含む 5 文字以上だけを ID とみなす。掲示板が振る ID は 8〜9 文字なので、
/// これで普通の文中の `ID:` 表記まで拾うことはまず無い。
const _idChar = r'[0-9A-Za-z./+]';
const _idPattern =
    '(?<![0-9A-Za-z])ID:(?=$_idChar{5})($_idChar*[0-9A-Za-z]$_idChar*)';

/// レス本文。`>>123` / `>>3-5` / `>>1,3,5` のレス参照・URL・`ID:xxx` を
/// タップ可能にして表示する。
///
/// - `>>N` タップ → [onTapRes]（該当レスへスクロール）
/// - `>>N-M` / `>>N,M` タップ → [onTapResRange]（まとめて一覧表示）。
///   渡されていなければ先頭の 1 件へスクロールする
/// - URL タップ → [onTapUrl]（ブラウザで開く）
/// - `ID:xxx` タップ → [onTapId]（同じ ID のレス一覧）
///
/// TapGestureRecognizer を持つので Stateful にして破棄を管理する。
class ResBody extends StatefulWidget {
  const ResBody({
    super.key,
    required this.text,
    required this.onTapRes,
    required this.onTapUrl,
    this.onTapResRange,
    this.onTapId,
    this.selectable = true,
    this.style,
    this.highlightQuery = '',
  });

  final String text;
  final ValueChanged<int> onTapRes;
  final ValueChanged<List<int>>? onTapResRange;
  final ValueChanged<Uri> onTapUrl;

  /// 本文中の `ID:xxx` を押したとき。null なら identicon は出すがタップは効かない
  /// （ID の一覧を出せない場所でも「誰か」は絵で分かるようにする）。
  final ValueChanged<String>? onTapId;

  /// 本文を範囲選択できるようにするか。false でもリンク・レス参照タップは有効。
  final bool selectable;

  final TextStyle? style;

  /// スレ内検索中の検索語（小文字化前でよい）。空でなければ本文の一致箇所を
  /// ハイライトする。
  final String highlightQuery;

  @override
  State<ResBody> createState() => _ResBodyState();
}

class _ResBodyState extends State<ResBody> {
  final _recognizers = <TapGestureRecognizer>[];

  // URL か >>数字 か ID:xxx を拾う。URL を先に（貪欲に）判定する。URL の中の
  // `ID:` を ID として切り出さないため、この順でなければならない。
  static final _pattern = RegExp(
    '($linkUrlPattern)|(?:&gt;&gt;|>>)($resAnchorSpecPattern)|$_idPattern',
  );

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 再ビルドのたびに古い recognizer を捨てて作り直す。
    _disposeRecognizers();

    final theme = Theme.of(context);
    final linkStyle = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );

    final spans = <InlineSpan>[];
    final text = widget.text;
    final isAsciiArt = looksLikeAsciiArt(text);
    final effectiveStyle = isAsciiArt
        ? _asciiArtStyle(context, widget.style)
        : widget.style;
    // identicon は本文の文字と並ぶので、大文字の高さに収まる程度に留める。
    final idIconSize =
        (effectiveStyle?.fontSize ??
            theme.textTheme.bodyLarge?.fontSize ??
            15) *
        0.9;
    // `>>N` だけでできている行。そこに書かれた `>>N` は「ここから誰かへの
    // 返信」という宣言なので返信の矢印に替える。**文と同じ行にあるものは
    // `>>` のまま**——`今日は>>5を>>6個食べる！` のように、安価を文の部品として
    // 使う書き方があり、記号を絵にすると文が読み下せなくなる。
    final quoteLines = quoteLinesIn(text);
    final queryLower = widget.highlightQuery.trim().toLowerCase();
    final highlightStyle = searchHighlightStyle(theme.colorScheme);
    void addPlain(String part) =>
        appendHighlighted(spans, part, queryLower, highlightStyle);
    var last = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > last) {
        addPlain(text.substring(last, m.start));
      }
      final url = m.group(1);
      if (url != null) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            final uri = normalizedLinkUri(url);
            if (uri != null) widget.onTapUrl(uri);
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: url, style: linkStyle, recognizer: recognizer),
        );
      } else if (m.group(3) case final id?) {
        // 絵と文字はひとかたまりの WidgetSpan にする。別々の span にすると
        // 行末で絵だけが前の行に取り残され（word joiner でも止まらない）、
        // どの ID の絵なのか読めなくなる。
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _InlineId(
              id: id,
              label: m.group(0)!,
              iconSize: idIconSize,
              style: (effectiveStyle ?? const TextStyle()).copyWith(
                // 行の高さ（1.4）を持ち込むと箱が字より高くなり、行間が広がる。
                height: 1,
              ),
              onTap: widget.onTapId,
            ),
          ),
        );
      } else {
        // >>N / >>N-M / >>N,M
        final numbers = resNumbersInAnchor(m.group(2)!);
        if (numbers.isEmpty) {
          // 桁が多すぎて番号として読めなかったもの。書かれたまま地の文で出す。
          addPlain(m.group(0)!);
        } else {
          final recognizer = TapGestureRecognizer()
            ..onTap = () {
              final rangeHandler = widget.onTapResRange;
              if (numbers.length == 1 || rangeHandler == null) {
                widget.onTapRes(numbers.first);
              } else {
                rangeHandler(numbers);
              }
            };
          _recognizers.add(recognizer);
          final ownsLine = quoteLines.any(
            (line) => m.start >= line.start && m.end <= line.end,
          );
          if (ownsLine) {
            // 行を丸ごと使った宣言。`>>` を返信の矢印（引用行の印と同じ形）
            // に替える。
            // 矢印と番号はひとかたまりの WidgetSpan にする——別々の span だと
            // 行末で矢印だけが前の行に残る。
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _InlineResAnchor(
                  spec: m.group(2)!,
                  style: (effectiveStyle ?? const TextStyle()).copyWith(
                    // 行の高さ（1.4）を持ち込むと箱が字より高くなる。
                    height: 1,
                  ),
                  onTap: () {
                    final rangeHandler = widget.onTapResRange;
                    if (numbers.length == 1 || rangeHandler == null) {
                      widget.onTapRes(numbers.first);
                    } else {
                      rangeHandler(numbers);
                    }
                  },
                ),
              ),
            );
          } else {
            spans.add(
              TextSpan(
                // 書かれた表記のまま出す（`&gt;&gt;` のエスケープだけ直す）。
                text: '>>${m.group(2)}',
                style: linkStyle,
                recognizer: recognizer,
              ),
            );
          }
        }
      }
      last = m.end;
    }
    if (last < text.length) {
      addPlain(text.substring(last));
    }

    // 字の大きさは AA のときだけ後から決まる（幅に合わせて縮める）ので、本文の
    // 組み立てだけを渡して、根の style は呼ぶ側に決めさせる。
    Widget buildBody(TextStyle? style) {
      final rootSpan = TextSpan(style: style, children: spans);
      return widget.selectable
          ? SelectableText.rich(rootSpan)
          : Text.rich(rootSpan);
    }

    if (!isAsciiArt) return buildBody(effectiveStyle);

    return _FittedAsciiArt(
      text: text,
      style: effectiveStyle!,
      builder: buildBody,
    );
  }

  TextStyle _asciiArtStyle(BuildContext context, TextStyle? style) {
    final baseStyle = style ?? Theme.of(context).textTheme.bodyLarge;
    return asciiArtStyle(baseStyle ?? const TextStyle(fontSize: 16));
  }
}

/// AA の本文を、置ける幅に合わせて縮めて出す。
///
/// AA は折り返せない（折り返した時点で絵が崩れる）ので、これまでは元の大きさの
/// まま横スクロールに載せていた。PC 前提で組まれた AA はスマホの幅に収まらない
/// ものが多く、絵の右半分を見るのに毎回横へ振ることになる。
///
/// そこで、**まず幅に合わせて字を小さくし、それでも収まらない分だけ横スクロール**
/// に回す。縮めるのは字の大きさそのもの（[FittedBox] のような拡大縮小ではない）で、
/// 行間・字送りも同じ率で付いてくるため形は保たれ、小さくしても字は潰れずに出る。
/// 下限は [minAsciiArtFontSize]。
class _FittedAsciiArt extends StatefulWidget {
  const _FittedAsciiArt({
    required this.text,
    required this.style,
    required this.builder,
  });

  /// 幅を測るための本文。リンクや ID の装飾は幅を変えないので、素の文字列で測る。
  final String text;

  /// 縮める前の字（[asciiArtStyle] を通したもの）。
  final TextStyle style;

  /// 縮めた後の字で本文を組み立てる。
  final Widget Function(TextStyle style) builder;

  @override
  State<_FittedAsciiArt> createState() => _FittedAsciiArtState();
}

class _FittedAsciiArtState extends State<_FittedAsciiArt> {
  /// 縮める前に必要な幅。文字列と字が変わらない限り同じなので測り直さない。
  double _naturalWidth = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measure();
  }

  @override
  void didUpdateWidget(covariant _FittedAsciiArt old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) _measure();
  }

  void _measure() {
    _naturalWidth = asciiArtNaturalWidth(context, widget.text, widget.style);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fontSize = widget.style.fontSize ?? 15;
        final scale = asciiArtFitScale(
          naturalWidth: _naturalWidth,
          maxWidth: constraints.maxWidth,
          fontSize: fontSize,
        );
        final style = scale == 1
            ? widget.style
            : widget.style.copyWith(fontSize: fontSize * scale);
        return _BodyTextScale(
          scale: scale,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: widget.builder(style),
          ),
        );
      },
    );
  }
}

/// 本文の字を縮めた率。本文に混じる ID の絵（[_InlineId]）も同じ率で小さくして、
/// 絵だけが行から飛び出さないようにする。
class _BodyTextScale extends InheritedWidget {
  const _BodyTextScale({required this.scale, required super.child});

  final double scale;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BodyTextScale>()?.scale ?? 1;

  @override
  bool updateShouldNotify(_BodyTextScale old) => old.scale != scale;
}

/// 本文の文字列に混ぜる ID。レスの左に立つ柱（`PostItem` の identicon）と同じ絵に
/// `ID:xxx` の文字を添えたもので、絵と文字で 1 つの塊として置く。
///
/// **大きさは本文のフォントに合わせる。** 柱の絵と違ってこれは文字と同じ行に
/// 並ぶので、行の高さを超えると行間が割れる。役割も「人物の顔」ではなく
/// 「文中の記号」なので、柱と同じ大きさにする必要はない。
///
/// 柱にあるレス数のリング（`idColorForCount`）は付けない。本文に貼られた ID は
/// 別スレのものかもしれず、このスレでの連投数を語れないため。
/// **行を丸ごと使って書かれた** `>>N` を、返信の矢印＋番号にしたもの。
///
/// その行の `>>` は「これは誰への返信か」を言うためだけの記号で、引用行
/// （`QuotedResRow`）の頭に置いた矢印と同じことを言っている。同じ形にすると、
/// 返信先の中身が出せるとき（`PostBodyQuote`）と出せないときで見え方が揃う。
///
/// **文と同じ行にある `>>N` は替えない**（[quoteLinesIn]）。`今日は>>5を>>6個
/// 食べる！` のように安価を文の部品として使う書き方があり、記号を絵にすると
/// 文が読み下せなくなる。
class _InlineResAnchor extends StatelessWidget {
  const _InlineResAnchor({
    required this.spec,
    required this.style,
    required this.onTap,
  });

  /// 番号の部分（`5` / `1-3` / `1,2`）。
  final String spec;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // AA が幅に合わせて縮んでいるなら、矢印と字も同じ率で小さくする。
    final scale = _BodyTextScale.of(context);
    final base = scale == 1
        ? style
        : style.copyWith(fontSize: (style.fontSize ?? 15) * scale);
    final size = (base.fontSize ?? 15) * 0.95;
    return Semantics(
      label: '>>$spec',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.reply, size: size, color: scheme.primary),
            const SizedBox(width: 1),
            Text(
              spec,
              style: base.copyWith(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineId extends StatelessWidget {
  const _InlineId({
    required this.id,
    required this.label,
    required this.iconSize,
    required this.style,
    this.onTap,
  });

  final String id;

  /// 本文に書かれていた表記（`ID:xxx`）。ID そのものは [id] に入っている。
  final String label;

  final double iconSize;
  final TextStyle style;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // AA が幅に合わせて縮んでいるなら、絵と字も同じ率で小さくする。
    final scale = _BodyTextScale.of(context);
    final style = scale == 1
        ? this.style
        : this.style.copyWith(fontSize: (this.style.fontSize ?? 15) * scale);
    return Semantics(
      label: 'ID:$id',
      button: onTap != null,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap == null ? null : () => onTap!(id),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdIcon(id: id, size: iconSize * scale),
            const SizedBox(width: 2),
            Text(
              label,
              style: onTap == null
                  ? style
                  : style.copyWith(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: scheme.primary,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
