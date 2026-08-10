import 'dart:convert';
import 'dart:typed_data';

import 'package:edge_core/edge_core.dart';
import 'package:elec/src/net/image_fingerprint.dart';
import 'package:elec/src/net/ng_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 先頭から [differingBits] ビットだけ立てた dHash。距離を狙って作れる。
Uint8List _hash(int differingBits) {
  final hash = Uint8List(imageHashBits ~/ 8);
  for (var bit = 0; bit < differingBits; bit++) {
    hash[bit >> 3] |= 1 << (bit & 7);
  }
  return hash;
}

ImageFingerprint _fingerprint(String sha256, Uint8List? dhash) =>
    ImageFingerprint(sha256: sha256, dhash: dhash);

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

  test('ワッチョイNGは ID が変わっても効く', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addWacchoi('ipkW-6PVw');

    // 日付が変わって ID だけ別物になった同じ人。
    expect(
      ng.matches(
        _res(name: 'エッヂの名無し </b>(L20 ipkW-6PVw)<b>', id: 'day1'),
      ),
      isTrue,
    );
    expect(
      ng.matches(
        _res(name: 'エッヂの名無し </b>(L21 ipkW-6PVw)<b>', id: 'day2'),
      ),
      isTrue,
    );
    // 別のワッチョイ、ワッチョイ無しは巻き込まない。
    expect(ng.matches(_res(name: 'エッヂの名無し </b>(L20 ZZZZ-1111)<b>')), isFalse);
    expect(ng.matches(_res(name: 'エッヂの名無し')), isFalse);

    await ng.removeWacchoi('ipkW-6PVw');
    expect(ng.matches(_res(name: 'エッヂの名無し </b>(L20 ipkW-6PVw)<b>')), isFalse);
  });

  test('保存して読み直せる', () async {
    final storage = MemoryNgStorage();
    final ng1 = NgStore(storage);
    await ng1.load();
    await ng1.addWord(const NgWord('x', isRegex: true));
    await ng1.addId('id1');
    await ng1.addWacchoi('ipkW-6PVw');
    await ng1.addCreator('B3YfDSAP');

    final ng2 = NgStore(storage);
    await ng2.load();
    expect(ng2.words, const [NgWord('x', isRegex: true)]);
    expect(ng2.ids, ['id1']);
    expect(ng2.wacchois, ['ipkW-6PVw']);
    expect(ng2.creators, ['B3YfDSAP']);
    expect(ng2.isNgWacchoi('ipkW-6PVw'), isTrue);
  });

  test('同じ画像・似た画像を NG にできる', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    final registered = _fingerprint('a' * 64, _hash(0));
    await ng.addImage(NgImage.from(registered));

    // 貼り直しで URL もバイト列も変わるが、絵柄は同じ（数ビットだけ違う）。
    expect(ng.isNgImage(_fingerprint('b' * 64, _hash(3))), isTrue);
    // まったく別の絵柄。
    expect(
      ng.isNgImage(_fingerprint('c' * 64, _hash(ngImageMaxDistance + 1))),
      isFalse,
    );
    // dHash が離れていても、バイト列が同じなら同じ画像。
    expect(ng.isNgImage(_fingerprint('a' * 64, _hash(60))), isTrue);
  });

  test('のっぺりした画像は完全一致だけで判定する', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addImage(NgImage.from(_fingerprint('a' * 64, null)));

    expect(ng.isNgImage(_fingerprint('a' * 64, null)), isTrue);
    // dHash を持たない相手は、近さでは拾わない。
    expect(ng.isNgImage(_fingerprint('b' * 64, _hash(0))), isFalse);
  });

  test('同じ画像を二重には登録しない', () async {
    final ng = NgStore(MemoryNgStorage());
    await ng.load();
    await ng.addImage(NgImage.from(_fingerprint('a' * 64, _hash(0))));
    await ng.addImage(NgImage.from(_fingerprint('a' * 64, _hash(1))));
    expect(ng.images.length, 1);
  });

  test('NG 画像を保存して読み直せる', () async {
    final storage = MemoryNgStorage();
    final ng1 = NgStore(storage);
    await ng1.load();
    expect(ng1.hasImages, isFalse);
    await ng1.addImage(
      NgImage.from(
        _fingerprint('a' * 64, _hash(0)),
        thumbnail: Uint8List.fromList([1, 2, 3]),
      ),
    );

    final ng2 = NgStore(storage);
    await ng2.load();
    expect(ng2.hasImages, isTrue);
    expect(ng2.images.single.sha256, 'a' * 64);
    expect(ng2.images.single.dhash, _hash(0));
    expect(ng2.images.single.thumbnail, [1, 2, 3]);
    expect(ng2.isNgImage(_fingerprint('a' * 64, _hash(0))), isTrue);

    await ng2.removeImage(ng2.images.single);
    final ng3 = NgStore(storage);
    await ng3.load();
    expect(ng3.images, isEmpty);
  });

  test('NG 画像は JSON を経由しても同じものになる', () {
    final image = NgImage.from(
      _fingerprint('a' * 64, _hash(5)),
      thumbnail: Uint8List.fromList([9, 8, 7]),
    );
    final restored = NgImage.fromJson(
      jsonDecode(jsonEncode(image.toJson())) as Object,
    );
    expect(restored!.sha256, image.sha256);
    expect(restored.dhash, image.dhash);
    expect(restored.thumbnail, image.thumbnail);
    expect(restored.addedAt, image.addedAt);
    expect(NgImage.fromJson({'dhash': 'ff'}), isNull);
    expect(NgImage.fromJson('文字列'), isNull);
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
