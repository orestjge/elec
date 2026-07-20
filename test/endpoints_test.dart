import 'package:elec/src/net/endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('必死チェッカーの URL は k にレスの ID をそのまま渡す', () {
    const endpoints = EdgeEndpoints();
    final url = endpoints.hissi('bdwCNFndK');
    expect(url.host, 'www.kyodemo.net');
    expect(url.path, '/sdemo/b/e_e_liveedge/');
    expect(url.queryParameters['bs'], 'hi');
    expect(url.queryParameters['k'], 'bdwCNFndK');
  });
}
