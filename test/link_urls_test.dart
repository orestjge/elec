import 'package:elec/src/ui/link_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('省略された https URL を正規化する', () {
    expect(
      normalizedLinkUri('ttps://example.com/a')?.toString(),
      'https://example.com/a',
    );
    expect(
      normalizedLinkUri('tps://example.com/a')?.toString(),
      'https://example.com/a',
    );
    expect(
      normalizedLinkUri('s://example.com/a')?.toString(),
      'https://example.com/a',
    );
  });

  test('通常の http/https URL はそのまま扱う', () {
    expect(
      normalizedLinkUri('https://example.com/a')?.toString(),
      'https://example.com/a',
    );
    expect(
      normalizedLinkUri('http://example.com/a')?.toString(),
      'http://example.com/a',
    );
  });
}
