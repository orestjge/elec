import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'link_urls.dart';

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

    return SelectableText.rich(TextSpan(style: widget.style, children: spans));
  }
}
