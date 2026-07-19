import 'package:elec/src/ui/id_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ID 色はレス数に応じて段階的に変わる', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);

    expect(idColorForCount(scheme, 1), scheme.onSurfaceVariant);
    expect(idColorForCount(scheme, 2), scheme.primary);
    expect(idColorForCount(scheme, 4), scheme.primary);
    expect(idColorForCount(scheme, 5), scheme.tertiary);
    expect(idColorForCount(scheme, 8), scheme.error);
  });
}
