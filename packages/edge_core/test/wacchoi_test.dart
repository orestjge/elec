import 'package:edge_core/edge_core.dart';
import 'package:test/test.dart';

void main() {
  test('エッヂの名前欄からワッチョイを取る', () {
    expect(wacchoiOf('エッヂの名無し (L20 ipkW-6PVw)'), 'ipkW-6PVw');
    // ワッチョイだけ（!metadent:vv）の板。
    expect(wacchoiOf('エッヂの名無し (ipkW-6PVw)'), 'ipkW-6PVw');
  });

  test('5ch の名前欄からワッチョイを取る', () {
    expect(wacchoiOf('風吹けば名無し (ワッチョイ 1234-abcd)'), '1234-abcd');
    expect(wacchoiOf('風吹けば名無し (アウアウウー Sa1f-9xYz)'), 'Sa1f-9xYz');
    // IP 表示スレは括弧の中に角括弧が続く。
    expect(wacchoiOf('名無し (ワッチョイW 1234-abcd [192.0.2.1])'), '1234-abcd');
  });

  test('レベルだけ・ワッチョイの無い名前は null', () {
    expect(wacchoiOf('エッヂの名無し (L20)'), isNull);
    expect(wacchoiOf('エッヂの名無し'), isNull);
    expect(wacchoiOf(''), isNull);
  });

  test('括弧の外の 4-4 は拾わない', () {
    // コテハンやトリップに紛れた並びを人違いの種にしない。
    expect(wacchoiOf('abcd-1234 という名前'), isNull);
    expect(wacchoiOf('コテハン◆Ab12 (L20 ZZZZ-1111)'), 'ZZZZ-1111');
  });

  test('長い羅列の一部は切り取らない', () {
    expect(wacchoiOf('名無し (abcde-1234)'), isNull);
    expect(wacchoiOf('名無し (1234-abcd-5678)'), isNull);
  });

  test('入力欄には名前欄ごと貼っても、括弧が無くても通る', () {
    expect(parseWacchoiInput('  (L20 ipkW-6PVw)  '), 'ipkW-6PVw');
    expect(parseWacchoiInput('ワッチョイ 1234-abcd'), '1234-abcd');
    expect(parseWacchoiInput('ipkW-6PVw'), 'ipkW-6PVw');
    expect(parseWacchoiInput('ワッチョイなし'), isNull);
  });
}
