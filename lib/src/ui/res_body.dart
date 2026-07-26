import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'link_urls.dart';

/// 表示用に本文の前後空白を整える。AA はインデントや上下の余白が絵の一部に
/// なるためそのまま残し、それ以外の普通のレスだけ [String.trim] で詰める。
String trimUnlessAsciiArt(String text) =>
    looksLikeAsciiArt(text) ? text : text.trim();

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

/// レス本文。`>>123` / `>>3-5` のレス参照と URL をタップ可能にして表示する。
///
/// - `>>N` タップ → [onTapRes]（該当レスへスクロール）
/// - URL タップ → [onTapUrl]（ブラウザで開く）
///
/// TapGestureRecognizer を持つので Stateful にして破棄を管理する。
class ResBody extends StatefulWidget {
  const ResBody({
    super.key,
    required this.text,
    required this.onTapRes,
    required this.onTapUrl,
    this.onTapResRange,
    this.onSelectionActiveChanged,
    this.selectable = true,
    this.style,
    this.highlightQuery = '',
  });

  final String text;
  final ValueChanged<int> onTapRes;
  final ValueChanged<List<int>>? onTapResRange;
  final ValueChanged<Uri> onTapUrl;
  final ValueChanged<bool>? onSelectionActiveChanged;

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
  final _focusNode = FocusNode();
  bool _selectionActive = false;

  // URL か >>数字 を拾う。URL を先に（貪欲に）判定する。
  static final _pattern = RegExp(
    '($linkUrlPattern)|(&gt;&gt;|>>)(\\d+)(?:-(\\d+))?',
  );

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  // フォーカスを失うと選択も解除されるが、onSelectionChanged が collapsed で
  // 呼ばれないことがあるため、フォーカス喪失を選択解除の確実な合図として使う。
  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _setSelectionActive(false);
  }

  void _setSelectionActive(bool active) {
    if (_selectionActive == active) return;
    _selectionActive = active;
    widget.onSelectionActiveChanged?.call(active);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
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
      } else {
        // >>N / >>N-M
        final start = int.parse(m.group(3)!);
        final endText = m.group(4);
        final end = endText == null ? start : int.parse(endText);
        final label = endText == null
            ? '>>${m.group(3)}'
            : '>>${m.group(3)}-$endText';
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            if (start == end) {
              widget.onTapRes(start);
              return;
            }
            final from = start <= end ? start : end;
            final to = start <= end ? end : start;
            final numbers = <int>[
              for (var n = from; n <= to && n < from + 50; n++) n,
            ];
            final rangeHandler = widget.onTapResRange;
            if (rangeHandler == null) {
              widget.onTapRes(numbers.first);
            } else {
              rangeHandler(numbers);
            }
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: label, style: linkStyle, recognizer: recognizer),
        );
      }
      last = m.end;
    }
    if (last < text.length) {
      addPlain(text.substring(last));
    }

    final rootSpan = TextSpan(style: effectiveStyle, children: spans);
    final body = widget.selectable
        ? SelectableText.rich(
            rootSpan,
            focusNode: _focusNode,
            onSelectionChanged: (selection, cause) {
              _setSelectionActive(!selection.isCollapsed);
            },
          )
        : Text.rich(rootSpan);
    if (!isAsciiArt) return body;

    return SingleChildScrollView(scrollDirection: Axis.horizontal, child: body);
  }

  TextStyle _asciiArtStyle(BuildContext context, TextStyle? style) {
    final baseStyle = style ?? Theme.of(context).textTheme.bodyLarge;
    final baseSize = baseStyle?.fontSize ?? 16;
    return (baseStyle ?? const TextStyle()).copyWith(
      fontFamily: 'Monapo',
      fontSize: baseSize,
      height: 1.15,
      letterSpacing: 0,
    );
  }
}
