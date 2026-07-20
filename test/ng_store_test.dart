import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:flutter_test/flutter_test.dart';

Res _res({int number = 1, String name = '名無し', String? id, String body = ''}) =>
    Res(
      number: number,
      name: name,
      mail: '',
      dateText: '',
      dateTime: null,
      id: id,
      beId: null,
      body: body,
      kind: ResKind.normal,
      threadTitle: null,
    );

void main() {
  test('ワードNGは部分一致・大文字小文字を無視する', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWord(const NgWord('Abc'));
    expect(ng.matches(_res(body: 'これは aBC です')), isTrue);
    expect(ng.matches(_res(body: '普通のレス')), isFalse);
  });

  test('正規表現NGが効く', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWord(const NgWord(r'https?://\S+', isRegex: true));
    expect(ng.matches(_res(body: 'http://example.com を見て')), isTrue);
    expect(ng.matches(_res(body: 'リンクなし')), isFalse);
  });

  test('不正な正規表現は一致させない', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWord(const NgWord('(', isRegex: true));
    expect(ng.matches(_res(body: '((((')), isFalse);
    expect(NgStore.isValidRegex('('), isFalse);
    expect(NgStore.isValidRegex(r'\d+'), isTrue);
  });

  test('IDでNGできる', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addId('bdwCNFndK');
    expect(ng.isNgId('bdwCNFndK'), isTrue);
    expect(ng.matches(_res(id: 'bdwCNFndK', body: '何か')), isTrue);
    expect(ng.matches(_res(id: 'other', body: '何か')), isFalse);
  });

  test('名前もワードNGの対象になる', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWord(const NgWord('コテハン'));
    expect(ng.matches(_res(name: 'コテハン', body: '本文')), isTrue);
  });

  test('スレ主(metadent)を直接NGできる', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addCreator('B3YfDSAP');
    expect(ng.isNgCreator('B3YfDSAP'), isTrue);
    expect(ng.isNgCreator('cnXYQPjf'), isFalse);
    expect(ng.isNgCreator(null), isFalse);
  });

  test('NG IDのスレ立ても metadent 後半4文字で拾える', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    // 表示ID DSAXDFbJP のスレ主。metadent は [xxxx + DSAP]。
    await ng.addId('DSAXDFbJP');
    expect(ng.isNgCreator('B3YfDSAP'), isTrue); // 後半 DSAP が一致
    expect(ng.isNgCreator('B3YfQPjf'), isFalse); // 別人
    // ID を消せば連動して効かなくなる。
    await ng.removeId('DSAXDFbJP');
    expect(ng.isNgCreator('B3YfDSAP'), isFalse);
  });

  test('metadent / ID からのキー導出', () {
    expect(NgStore.creatorKeyFromMetadent('B3YfDSAP'), 'DSAP');
    expect(NgStore.creatorKeyFromMetadent('short'), isNull);
    expect(NgStore.creatorKeyFromId('DSAXDFbJP'), 'DSAP');
    expect(NgStore.creatorKeyFromId('QPjfqibof'), 'QPjf');
  });

  test('保存して読み直せる', () async {
    final storage = MemoryNgStorage();
    final ng1 = NgStore(storage);
    await ng1.load();
    await ng1.addWord(const NgWord('x', isRegex: true));
    await ng1.addId('id1');
    await ng1.addCreator('B3YfDSAP');

    final ng2 = NgStore(storage);
    await ng2.load();
    expect(ng2.words, const [NgWord('x', isRegex: true)]);
    expect(ng2.ids, ['id1']);
    expect(ng2.creators, ['B3YfDSAP']);
  });

  test('変更で listener が呼ばれる', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    var notified = 0;
    ng.addListener(() => notified++);
    await ng.addWord(const NgWord('a'));
    await ng.addId('b');
    expect(notified, 2);
  });
}
