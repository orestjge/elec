import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'link_urls.dart';

/// AA（アスキーアート）らしい本文だけ、MS Pゴシック互換寄りの同梱フォントで
/// 表示する。単発の顔文字まで巻き込まないよう、AA 記号を含む行数を見る。
bool looksLikeAsciiArt(String text) {
  final lines = text.split('\n');
  var aaLines = 0;
  for (final line in lines) {
    if (_looksLikeAsciiArtLine(line)) aaLines++;
  }
  if (aaLines >= 2) return true;

  if (lines.length == 1) {
    final line = lines.single.trim();
    return line.length >= 24 && _aaSymbolCount(line) >= 8;
  }
  return false;
}

final _aaSymbolRunes =
    '　＿￣ー─━│┃┌┐└┘├┤┬┴┼┏┓┗┛┣┫┳┻╋'
            '／＼/\\|｜∧∨ＶvＷwＭm（）()[]［］{}｛｝<>＜＞'
            '・.．,:;；"\'`´｀~～^＾-‐=＝+＋*＊'
        .runes
        .toSet();

bool _looksLikeAsciiArtLine(String line) {
  final trimmed = line.trim();
  if (trimmed.length < 4) return false;

  final symbolCount = _aaSymbolCount(line);
  final symbolRatio = symbolCount / trimmed.length;
  final leadingSpaces = _leadingSpaceCount(line);
  final hasFullWidthSpace = line.contains('　');

  return symbolCount >= 4 && symbolRatio >= 0.18 ||
      hasFullWidthSpace && symbolCount >= 2 ||
      leadingSpaces >= 4 && symbolCount >= 2;
}

int _aaSymbolCount(String line) {
  var count = 0;
  for (final rune in line.runes) {
    if (_aaSymbolRunes.contains(rune)) count++;
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
    this.style,
  });

  final String text;
  final ValueChanged<int> onTapRes;
  final ValueChanged<List<int>>? onTapResRange;
  final ValueChanged<Uri> onTapUrl;
  final TextStyle? style;

  @override
  State<ResBody> createState() => _ResBodyState();
}

class _ResBodyState extends State<ResBody> {
  final _recognizers = <TapGestureRecognizer>[];

  // URL か >>数字 を拾う。URL を先に（貪欲に）判定する。
  static final _pattern = RegExp(
    '($linkUrlPattern)|(&gt;&gt;|>>)(\\d+)(?:-(\\d+))?',
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
    var last = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
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
      spans.add(TextSpan(text: text.substring(last)));
    }

    final body = SelectableText.rich(
      TextSpan(style: effectiveStyle, children: spans),
    );
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
