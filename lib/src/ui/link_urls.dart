/// レス本文内の URL 表記を拾い、よくある省略形を実 URL に戻す。
library;

const linkUrlPattern = r'(?:https?://|ttps://|tps://|s://)[^\s<>"]+';

final linkUrlRe = RegExp(linkUrlPattern);

Uri? normalizedLinkUri(String raw) {
  final normalized = switch (raw) {
    final s when s.startsWith('ttps://') => 'h$s',
    final s when s.startsWith('tps://') => 'ht$s',
    final s when s.startsWith('s://') => 'http$s',
    _ => raw,
  };
  return Uri.tryParse(normalized);
}
