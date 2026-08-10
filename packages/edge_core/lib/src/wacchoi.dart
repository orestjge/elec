/// 名前欄に出るワッチョイ（回線・端末ごとの識別子）の切り出し。
///
/// スレ立てで `!metadent:vv`（エッヂ）や `!extend:on:vvvvv`（5ch 系）を指定すると、
/// 以降のレスの名前欄に括弧書きの識別子が付く。ID が日付をまたぐと変わるのに対し、
/// ワッチョイは同じ回線・端末なら数日変わらないので、**日をまたぐスレでは「ID は
/// 違うが同じ人」を繋ぐ唯一の手掛かり**になる。
library;

/// 括弧の中に出る `xxxx-yyyy` 形の識別子。
///
/// エッヂの `(L20 ipkW-6PVw)`、5ch の `(ワッチョイ 1234-abcd)` や
/// `(アウアウウー Sa1f-abcd)` のどれも、人を指しているのはこの 4-4 の部分だけ。
/// レベル（`L20`）や回線の呼び名（`アウアウウー`）は同じ人でも動くので混ぜない。
///
/// 前後が英数字・ハイフンで続いているものは拾わない。長い羅列の途中を切り取って
/// 別人を同一視するのを防ぐ。
final _identRe = RegExp(
  r'(?<![0-9A-Za-z-])([0-9A-Za-z]{4}-[0-9A-Za-z]{4})(?![0-9A-Za-z-])',
);

/// 名前の末尾に付く括弧書き。全角括弧の板もあるので両方見る。
/// 5ch の IP 表示（`(ワッチョイ 1234-abcd [192.0.2.1])`）のように中に角括弧が
/// 入ることはあるが、括弧の中に括弧は入らない前提。
final _suffixRe = RegExp(r'[(（]([^()（）]*)[)）]$');

/// [plainName] に含まれるワッチョイ。無ければ null。
///
/// 引数は **[htmlToText] を通した後の名前**。dat の名前欄は
/// `エッヂの名無し </b>(L20 ipkW-6PVw)<b>` のようにタグ込みで来るので、生のまま
/// 渡してはいけない。
///
/// 名前の**末尾の括弧**の中だけを見る。コテハンやトリップに 4-4 の並びが紛れて
/// いても人違いにしないため。
String? wacchoiOf(String plainName) {
  final suffix = _suffixRe.firstMatch(plainName.trimRight());
  if (suffix == null) return null;
  return _identRe.firstMatch(suffix.group(1)!)?.group(1);
}

/// 手で入力・貼り付けされた文字列からワッチョイを拾う（設定画面の入力用）。
///
/// `(L20 ipkW-6PVw)`・`ワッチョイ 1234-abcd`・`1234-abcd` のどれでも受ける。
/// [wacchoiOf] と違って括弧を要求しない——人が貼るものは形が揃わないため。
String? parseWacchoiInput(String text) => _identRe.firstMatch(text)?.group(1);
