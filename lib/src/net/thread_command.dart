/// スレ立ての 1 レス目に書く「名前欄に何を出すか」のコマンド。
///
/// エッヂ (eddist) は `!metadent:vv:`、5ch 系は `!extend:…` と綴りが違うだけで、
/// **スレ立ての本文に書くとそのスレ全体の名前欄が変わる**（以降のレスにも効く）
/// 点は同じ。板ごとの綴りを [ThreadCommandDialect] に閉じ込め、画面側は
/// 「選べる指定」と「本文から読み取った指定」だけを見る。
///
/// 5ch を足すときは [ThreadCommandDialect] をもう 1 つ書いて [dialectFor] と
/// [_dialects] に繋ぐ。画面側は触らなくて済む。
library;

import 'board.dart';

/// 本文に書かれたコマンドが、どういう状態で見つかったか。
enum ThreadCommandState {
  /// これから投稿する本文に書かれている（まだサーバを通っていない）。
  pending,

  /// スレ立て人が指定し、サーバが受理した。
  configured,

  /// 板の設定で強制された。スレ立て人が選んだものではない。
  forced,
}

/// スレ立て画面に並べる指定 1 つ。
class ThreadCommandOption {
  const ThreadCommandOption({
    required this.id,
    required this.label,
    required this.description,
    this.line,
  });

  /// 方言をまたいで重ならない識別子。[ThreadCommand.id] と突き合わせて、本文に
  /// 今どれが書かれているかを決める。
  final String id;

  /// 「ワッチョイ」など、名前欄に出るものの短い名前。
  final String label;

  /// 選択肢の下に出す一行の説明。
  final String description;

  /// 本文へ書き足す行。null なら何も書かない（板の既定に従う）。
  final String? line;
}

/// 本文から読み取ったコマンド 1 つ。
class ThreadCommand {
  const ThreadCommand({
    required this.id,
    required this.label,
    required this.state,
    required this.start,
    required this.end,
  });

  /// 対応する [ThreadCommandOption.id]。
  final String id;

  /// 名前欄に出るものの短い名前（[ThreadCommandOption.label] と同じ語）。
  final String label;

  final ThreadCommandState state;

  /// 本文の中でコマンドが占めている範囲。
  final int start;
  final int end;

  /// 板の設定で強制されたものか。スレ立て人の指定と区別して見せる。
  bool get isForced => state == ThreadCommandState.forced;
}

/// 板ごとのコマンドの綴り。
abstract class ThreadCommandDialect {
  const ThreadCommandDialect();

  /// スレ立て画面に並べる選択肢。**先頭は必ずコマンドを書かない指定**にする
  /// （本文にコマンドが無いときの既定として使う）。
  List<ThreadCommandOption> get options;

  /// [body] に書かれたコマンドを探す。無ければ null。
  ThreadCommand? find(String body);

  /// [body] に今書かれている指定。何も書かれていなければ [options] の先頭。
  ThreadCommandOption selected(String body) {
    final found = find(body);
    if (found == null) return options.first;
    for (final option in options) {
      if (option.id == found.id) return option;
    }
    return options.first;
  }

  /// [body] のコマンドを [option] のものへ差し替える。
  ///
  /// 書く位置は**本文の先頭**に固定する。サーバはどこに書いてあっても拾うが、
  /// 読む側の目には先頭にあるのが一番分かりやすく、選び直すたびに位置が動くと
  /// 書きかけの文章が乱れるため。
  String apply(String body, ThreadCommandOption option) {
    final rest = _removeCommandLine(body, find(body));
    final line = option.line;
    if (line == null) return rest;
    return rest.isEmpty ? '$line\n' : '$line\n$rest';
  }
}

/// エッヂ (eddist) の `!metadent:`。
///
/// `v` の数で名前欄の中身が決まる（`eddist-server/src/domain/metadent.rs`）。
/// `v`→`(L20)`、`vv`→`(ipkW-6PVw)`、`vvv`→`(L20 ipkW-6PVw)`。識別子は ASN・IP・
/// UA から作られ、7 日ごとに変わる。
///
/// 投稿が通るとサーバが本文の綴りを `!metadent:vv - configured`（板が強制して
/// いれば `- forced`）へ書き換える（`domain/res.rs` の `new_from_thread`）ので、
/// dat から読むときはそちらの形で出てくる。両方を拾う。
class EddistThreadCommands extends ThreadCommandDialect {
  const EddistThreadCommands();

  static final _re = RegExp(r'!metadent:(v{1,3})(?::| - (configured|forced))');

  static const _labels = {'v': 'レベル', 'vv': 'ワッチョイ', 'vvv': 'ワッチョイ＋レベル'};

  @override
  List<ThreadCommandOption> get options => const [
    ThreadCommandOption(
      id: 'metadent:none',
      label: 'なし',
      description: '板の既定のまま。名前欄に何も足さない',
    ),
    ThreadCommandOption(
      id: 'metadent:vv',
      label: 'ワッチョイ',
      description: '回線・端末ごとの識別子を出す（7 日で変わる）',
      line: '!metadent:vv:',
    ),
    ThreadCommandOption(
      id: 'metadent:v',
      label: 'レベル',
      description: '書いた人のレベルだけを出す',
      line: '!metadent:v:',
    ),
    ThreadCommandOption(
      id: 'metadent:vvv',
      label: 'ワッチョイ＋レベル',
      description: '識別子とレベルの両方を出す',
      line: '!metadent:vvv:',
    ),
  ];

  @override
  ThreadCommand? find(String body) {
    final match = _re.firstMatch(body);
    if (match == null) return null;
    final vs = match.group(1)!;
    return ThreadCommand(
      id: 'metadent:$vs',
      label: _labels[vs]!,
      state: switch (match.group(2)) {
        'configured' => ThreadCommandState.configured,
        'forced' => ThreadCommandState.forced,
        _ => ThreadCommandState.pending,
      },
      start: match.start,
      end: match.end,
    );
  }
}

/// 知っている方言の一覧。板が分からない場所（レス表示）で順に当てる。
const _dialects = <ThreadCommandDialect>[EddistThreadCommands()];

/// [kind] の板でスレ立て時にコマンドを書けるなら、その方言。書けないなら null。
///
/// 今はエッヂだけ。5ch の `!extend:` は板ごとに受け付ける指定が違い、板の
/// SETTING.TXT を読まないと出せる選択肢が決まらないので、まだ繋いでいない。
ThreadCommandDialect? dialectFor(BoardKind kind) =>
    kind == BoardKind.eddist ? const EddistThreadCommands() : null;

/// どの板のレスか分からないまま、本文からコマンドを読み取る。
///
/// 綴りが独特で普通の文には出てこないので、板の種別を渡さず順に当てて構わない。
/// レス表示は板を知らない入れ物（ツリー・会話シート）からも使われるため、板を
/// 引き回すより取り違えの余地が少ない。
ThreadCommand? parseThreadCommand(String body) {
  for (final dialect in _dialects) {
    final found = dialect.find(body);
    if (found != null) return found;
  }
  return null;
}

/// 本文から [command] の綴りを取り除く。
///
/// コマンドは読む人に向けた文ではなく板への指示なので、意味を [ThreadCommand]
/// として取り出したあとの本文には残さない（代わりに画面が読める形で出す）。
String stripThreadCommand(String body, ThreadCommand command) =>
    _removeCommandLine(body, command);

/// [command] の範囲を [body] から消す。その行にコマンドしか無ければ行ごと消して、
/// 空行だけが残らないようにする。
String _removeCommandLine(String body, ThreadCommand? command) {
  if (command == null) return body;
  var start = command.start;
  var end = command.end;
  // 行頭からコマンドまでが空白だけなら、その空白ごと消す。
  var lineStart = start;
  while (lineStart > 0 && body[lineStart - 1] != '\n') {
    lineStart--;
  }
  if (body.substring(lineStart, start).trim().isEmpty) start = lineStart;
  // 行末までが空白だけなら、改行 1 つまで含めて消す。
  var lineEnd = end;
  while (lineEnd < body.length && body[lineEnd] != '\n') {
    lineEnd++;
  }
  if (body.substring(end, lineEnd).trim().isEmpty) {
    end = lineEnd < body.length ? lineEnd + 1 : lineEnd;
  }
  return body.replaceRange(start, end, '');
}
