import 'package:elec/src/net/board.dart';
import 'package:elec/src/net/thread_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const eddist = EddistThreadCommands();

  ThreadCommandOption optionOf(String id) =>
      eddist.options.firstWhere((o) => o.id == id);

  group('読み取り（エッヂ）', () {
    test('スレ立て前の生のコマンドを拾う', () {
      final c = parseThreadCommand('!metadent:vv:\nスレ立てました')!;
      expect(c.id, 'metadent:vv');
      expect(c.label, 'ワッチョイ');
      expect(c.state, ThreadCommandState.pending);
    });

    test('サーバが書き換えた configured を拾う', () {
      final c = parseThreadCommand('!metadent:vv - configured\n本文')!;
      expect(c.id, 'metadent:vv');
      expect(c.state, ThreadCommandState.configured);
      expect(c.isForced, isFalse);
    });

    test('板の強制（forced）はスレ立て人の指定と区別する', () {
      final c = parseThreadCommand('!metadent:v - forced\n本文')!;
      expect(c.id, 'metadent:v');
      expect(c.label, 'レベル');
      expect(c.isForced, isTrue);
    });

    test('v の数で中身が変わる', () {
      expect(parseThreadCommand('!metadent:v:')!.label, 'レベル');
      expect(parseThreadCommand('!metadent:vv:')!.label, 'ワッチョイ');
      expect(parseThreadCommand('!metadent:vvv:')!.label, 'ワッチョイ＋レベル');
    });

    test('コマンドの無い本文では何も返さない', () {
      expect(parseThreadCommand('ただの本文\nhttps://example.com/'), isNull);
      // 綴りが違うもの（v が 4 つ・末尾が無い）は拾わない。
      expect(parseThreadCommand('!metadent:vvvv:'), isNull);
      expect(parseThreadCommand('!metadent:vv'), isNull);
    });
  });

  group('本文から取り除く', () {
    test('コマンドだけの行は行ごと消える', () {
      final body = '!metadent:vv - configured\n本文\n2 行目';
      final c = parseThreadCommand(body)!;
      expect(stripThreadCommand(body, c), '本文\n2 行目');
    });

    test('行の途中に書かれていてもその綴りだけ消す', () {
      final body = 'あああ !metadent:vv - configured いいい';
      final c = parseThreadCommand(body)!;
      expect(stripThreadCommand(body, c), 'あああ  いいい');
    });

    test('コマンドしか無い本文は空になる', () {
      const body = '!metadent:vv:';
      expect(stripThreadCommand(body, parseThreadCommand(body)!), '');
    });
  });

  group('スレ立て時の書き換え', () {
    test('本文の先頭にコマンド行を足す', () {
      expect(eddist.apply('本文', optionOf('metadent:vv')), '!metadent:vv:\n本文');
    });

    test('選び直しても行は増えず差し替わる', () {
      final once = eddist.apply('本文', optionOf('metadent:vv'));
      final twice = eddist.apply(once, optionOf('metadent:vvv'));
      expect(twice, '!metadent:vvv:\n本文');
    });

    test('「なし」に戻すとコマンド行が消える', () {
      final withCommand = eddist.apply('本文', optionOf('metadent:v'));
      expect(eddist.apply(withCommand, optionOf('metadent:none')), '本文');
    });

    test('空の本文でも改行だけ残して足せる', () {
      expect(eddist.apply('', optionOf('metadent:vv')), '!metadent:vv:\n');
    });

    test('今の指定を本文から読み戻せる', () {
      expect(eddist.selected('本文').id, 'metadent:none');
      expect(eddist.selected('!metadent:vvv:\n本文').id, 'metadent:vvv');
      // サーバが書き換えた後の綴りでも同じ指定として読める。
      expect(eddist.selected('!metadent:v - configured').id, 'metadent:v');
    });

    test('選択肢の先頭はコマンドを書かない指定', () {
      expect(eddist.options.first.line, isNull);
    });
  });

  group('板ごとの方言', () {
    test('エッヂだけコマンドを書ける', () {
      expect(dialectFor(BoardKind.eddist), isNotNull);
      // 5ch の !extend: は板ごとに受け付ける指定が違うのでまだ繋いでいない。
      expect(dialectFor(BoardKind.fivech), isNull);
      expect(dialectFor(BoardKind.shitaraba), isNull);
    });
  });
}
