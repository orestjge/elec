/// レスの種別。dat の 1 行がどの形式かを表す。
///
/// eddist の `eddist-core/src/domain/res.rs` が出力する 3 形式に対応する。
enum ResKind {
  /// 通常のレス。
  normal,

  /// あぼーん（削除済み）。`あぼーん<>あぼーん<><> あぼーん <>{title}`
  abone,

  /// 1000 を超えたスレの終端メッセージ。`1001<><>Over 1000 Thread<>{body}<>`
  over1000,
}

/// dat の 1 レス。
///
/// [name] と [body] は **SJIS デコード済みだが HTML は未加工**（`<br>`、
/// HTML エンティティ、`</b>...<b>` などが残る）。表示層で整形する。
/// この分離は Slevo の `docs/app/thread-response-list.md` と同じ方針。
class Res {
  const Res({
    required this.number,
    required this.name,
    required this.mail,
    required this.dateText,
    required this.dateTime,
    required this.id,
    required this.beId,
    required this.body,
    required this.kind,
    required this.threadTitle,
  });

  /// レス番号（1 始まり）。dat 内の行位置で決まる。
  final int number;

  /// 名前欄（HTML 未加工）。`base ★cap ◆trip </b>(L5 ident)<b>` の形を取り得る。
  final String name;

  /// メール欄。`sage` かそれ以外（多くは空）。
  final String mail;

  /// 日付+ID 欄の生テキスト（表示にそのまま使える）。
  /// 例: `2025/11/03(月) 02:14:51.907`。abone では空、1001 では `Over 1000 Thread`。
  final String dateText;

  /// [dateText] をパースした UTC の瞬間。パース不能なら null。
  /// dat の時刻は JST 表記なので、9 時間引いて UTC に直してある。
  final DateTime? dateTime;

  /// `ID:` の値。cap 使用レスは `????`、abone / 1001 では null。
  final String? id;

  /// `BE:` の値（`BE:123-xxxx` の `123-xxxx` 部分）。無ければ null。
  /// eddist は現状出力しないが、5ch 互換のため受けられるようにしておく。
  final String? beId;

  /// 本文（HTML 未加工）。dat 上の前後スペース（`<> {body} <>`）は除去済み。
  final String body;

  /// レス種別。
  final ResKind kind;

  /// スレッドタイトル。通常は 1 レス目にのみ入り、それ以外は null。
  final String? threadTitle;

  bool get isAbone => kind == ResKind.abone;
}

/// subject.txt の 1 行（スレッド一覧の 1 スレ）。
class ThreadSummary {
  const ThreadSummary({
    required this.key,
    required this.title,
    required this.resCount,
    required this.capName,
  });

  /// スレッドキー（UNIX 時刻由来の数値文字列）。dat 取得の URL に使う。
  final String key;

  /// スレタイトル（`[cap★]` と末尾 `(レス数)` を除いたもの、HTML 未加工）。
  final String title;

  /// レス数。
  final int resCount;

  /// スレ立て時の cap 名。`title [xxx★] (n)` の `xxx`。無ければ null。
  /// eddist の `thread_list.rs:40` が cap 付きスレに付与する。
  final String? capName;

  /// スレッドキーを int で。
  int get keyAsInt => int.parse(key);

  /// スレッド作成時刻（キーは作成時の UNIX 秒）。
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(keyAsInt * 1000, isUtc: true);
}
