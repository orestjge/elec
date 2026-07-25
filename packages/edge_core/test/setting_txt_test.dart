import 'package:edge_core/edge_core.dart';
import 'package:jis0208/jis0208.dart';
import 'package:test/test.dart';

void main() {
  // SETTING.TXT は SJIS。生ファイルを模して Windows-31J でエンコードする。
  BoardSetting parse(String text) =>
      parseSettingTxt(Windows31JCodec().encode(text));

  group('parseSettingTxt', () {
    test('エッヂの実測値', () {
      final s = parse(
        'BBS_TITLE=エッヂ\n'
        'BBS_NONAME_NAME=エッヂの名無し\n'
        'BBS_LINE_NUMBER=16\n'
        'BBS_MESSAGE_COUNT=9192\n'
        'BBS_SUBJECT_COUNT=192\n',
      );
      expect(s.title, 'エッヂ');
      expect(s.defaultName, 'エッヂの名無し');
      expect(s.messageMaxCount, 9192);
      expect(s.subjectMaxCount, 192);
      expect(s.hasAcorn, isFalse);
    });

    test('どんぐり板（BBS_ACORN=1）', () {
      final s = parse('BBS_TITLE=なんJ\nBBS_ACORN=1\n');
      expect(s.acorn, '1');
      expect(s.hasAcorn, isTrue);
    });

    test('CRLF・空行・=を含む値', () {
      final s = parse('BBS_TITLE=a=b\r\n\r\nBBS_NONAME_NAME=名無し\r\n');
      expect(s.title, 'a=b');
      expect(s.defaultName, '名無し');
    });

    test('= のない行は無視', () {
      final s = parse('コメント行\nBBS_TITLE=板\n');
      expect(s.title, '板');
      expect(s.values.containsKey('コメント行'), isFalse);
    });

    test('欠けている値は null', () {
      final s = parse('BBS_TITLE=板\n');
      expect(s.defaultName, isNull);
      expect(s.acorn, isNull);
      expect(s.hasAcorn, isFalse);
    });

    test('したらばの EUC-JP setting.cgi をパースする', () {
      final s = parseSettingTxt(
        EucJpCodec().encode('BBS_TITLE=したらば板\nBBS_NONAME_NAME=名無しさん\n'),
        encoding: BbsTextEncoding.eucJp,
      );
      expect(s.title, 'したらば板');
      expect(s.defaultName, '名無しさん');
    });
  });
}
