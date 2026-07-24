/// 掲示板の種別。エッヂ固有機能（metadent / subject-metadent.txt / 必死チェッカー /
/// auth-code 認証）と 5ch 系機能（MonaTicket / 二段階 POST）を切り替える軸。
enum BoardKind {
  /// エッヂ (eddist) 系。metadent・auth-code 認証・必死チェッカーを持つ。
  eddist,

  /// 5ch 互換。どんぐり（MonaTicket）・二段階 POST。metadent 等は無い。
  fivech,
}

/// 閲覧・書き込み対象の板。host / boardKey に加え、表示名やデフォルト名、種別を
/// 持つ。「URL から板を追加」で増える単位で、[[board_store]] が永続化する。
class Board {
  const Board({
    required this.host,
    required this.boardKey,
    required this.title,
    this.defaultName,
    this.kind = BoardKind.fivech,
    this.messageMax,
    this.subjectMax,
  });

  /// 既定のエッヂ（liveedge）。初回起動時のシード。起動体験を変えないため
  /// これが常に一覧の先頭・初期選択になる。
  static const eddibb = Board(
    host: 'bbs.eddibb.cc',
    boardKey: 'liveedge',
    title: 'エッヂ',
    defaultName: 'エッヂの名無し',
    kind: BoardKind.eddist,
  );

  /// エッヂ (eddist) のホスト。ここに一致すれば種別を eddist と判定する。
  static const eddibbHost = 'bbs.eddibb.cc';

  final String host;
  final String boardKey;
  final String title;

  /// 名前欄が空のときのデフォルト名（`BBS_NONAME_NAME`）。未取得なら null。
  final String? defaultName;

  final BoardKind kind;

  /// 本文の最大文字数（`BBS_MESSAGE_COUNT`）。未取得なら null＝画面側の既定に従う。
  /// 5ch は 4096、エッヂは 9192 と板で異なるので compose 制限に使う。
  final int? messageMax;

  /// スレタイの最大文字数（`BBS_SUBJECT_COUNT`）。未取得なら null。
  final int? subjectMax;

  /// 板の一意 ID。ホスト＋板キー。永続化・履歴スコープ・選択状態のキー。
  String get id => '$host/$boardKey';

  bool get isEddist => kind == BoardKind.eddist;

  Board copyWith({
    String? host,
    String? title,
    String? defaultName,
    BoardKind? kind,
    int? messageMax,
    int? subjectMax,
  }) => Board(
    host: host ?? this.host,
    boardKey: boardKey,
    title: title ?? this.title,
    defaultName: defaultName ?? this.defaultName,
    kind: kind ?? this.kind,
    messageMax: messageMax ?? this.messageMax,
    subjectMax: subjectMax ?? this.subjectMax,
  );

  factory Board.fromJson(Map<String, dynamic> json) => Board(
    host: json['host'] as String,
    boardKey: json['boardKey'] as String,
    title: json['title'] as String? ?? json['boardKey'] as String,
    defaultName: json['defaultName'] as String?,
    kind: BoardKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => BoardKind.fivech,
    ),
    messageMax: (json['messageMax'] as num?)?.toInt(),
    subjectMax: (json['subjectMax'] as num?)?.toInt(),
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'boardKey': boardKey,
    'title': title,
    'defaultName': defaultName,
    'kind': kind.name,
    'messageMax': messageMax,
    'subjectMax': subjectMax,
  };

  @override
  bool operator ==(Object other) => other is Board && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
