/// BBSMENU などから取得した、追加候補の板カタログ。
class BoardCatalog {
  const BoardCatalog({required this.sourceName, required this.categories});

  final String sourceName;
  final List<BoardCatalogCategory> categories;

  Iterable<BoardCatalogEntry> get entries sync* {
    for (final category in categories) {
      yield* category.entries;
    }
  }
}

/// 板カタログ内のカテゴリ。UI ではフォルダとして表示する。
class BoardCatalogCategory {
  const BoardCatalogCategory({required this.name, required this.entries});

  final String name;
  final List<BoardCatalogEntry> entries;
}

/// BBSMENU などから取得した、追加候補の板。
class BoardCatalogEntry {
  const BoardCatalogEntry({
    required this.name,
    required this.boardKey,
    required this.url,
  });

  final String name;
  final String boardKey;
  final Uri url;

  String get host => url.host;

  /// 追加済み判定に使うキー。[Board.id] と同じ形（ホスト＋板キー）。
  String get id => '$host/$boardKey';
}

/// 板リストの取得元。
///
/// 掲示板ごとに板リストの置き場所が違うので、取得方法を [kind] で切り替える。
/// UI はここに並んだソースをタブとして出す。
class BoardCatalogSource {
  const BoardCatalogSource({
    required this.label,
    required this.kind,
    this.host = '',
  });

  /// 5ch の BBSMENU（`menu.5ch.net/bbsmenu.json`）。板ごとにサーバが分散する
  /// ため、ここだけは専用ホストの JSON を見る。
  static const fivech = BoardCatalogSource(
    label: '5ch',
    kind: BoardCatalogSourceKind.fivechMenu,
  );

  /// 追加済みの板と同じサーバの板リスト。eddist の `/api/boards`、または
  /// 2ch 系サーバが置く `/bbsmenu.html` を見る。
  factory BoardCatalogSource.forHost(String host, {String? label}) =>
      BoardCatalogSource(
        label: label ?? host,
        kind: BoardCatalogSourceKind.host,
        host: host,
      );

  /// タブに出す表示名。
  final String label;

  final BoardCatalogSourceKind kind;

  /// [BoardCatalogSourceKind.host] のときの掲示板ホスト。
  final String host;

  /// ソースの一意キー。UI のキャッシュ・タブ選択に使う。
  String get id => kind == BoardCatalogSourceKind.fivechMenu ? '5ch' : host;

  @override
  bool operator ==(Object other) =>
      other is BoardCatalogSource && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 板リストの取得方法。
enum BoardCatalogSourceKind {
  /// 5ch の BBSMENU（JSON・カテゴリ付き・複数サーバ）。
  fivechMenu,

  /// 単一ホストの板リスト（eddist の `/api/boards` か `/bbsmenu.html`）。
  host,
}
