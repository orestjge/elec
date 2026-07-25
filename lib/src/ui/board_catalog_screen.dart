import 'package:flutter/material.dart';

import '../net/board.dart';
import '../net/board_catalog.dart';
import '../net/board_store.dart';

/// 板リストからの追加結果。追加できた板と、追加できなかった板名を返す。
class BoardCatalogResult {
  const BoardCatalogResult({required this.added, required this.failed});
  final List<Board> added;
  final List<String> failed;
}

/// 板リストから板を追加する画面。
///
/// ダイアログではなく画面にしているのは、検索欄がキーボードに隠れないこと・
/// カテゴリ付きの長いリストを端末の高さいっぱいに出せること・取得元が増えても
/// タブで並べられることの 3 点のため。取得元は [BoardCatalogSource] で、
/// 5ch の BBSMENU と、追加済みの板と同じサーバの板リストを並べる。
class BoardCatalogScreen extends StatefulWidget {
  const BoardCatalogScreen({super.key});

  /// 現在の板一覧から取得元を組み立てる。5ch は BBSMENU が全サーバを網羅する
  /// ので 1 つにまとめ、それ以外は板を持っているホストごとに 1 つ出す。
  static List<BoardCatalogSource> sourcesFor(List<Board> boards) {
    final sources = <BoardCatalogSource>[BoardCatalogSource.fivech];
    final seen = <String>{};
    for (final board in boards) {
      final host = board.host;
      if (host.endsWith('.5ch.net') || host.endsWith('.5ch.io')) continue;
      if (!seen.add(host)) continue;
      sources.add(
        BoardCatalogSource.forHost(
          host,
          label: host == Board.eddibbHost ? 'エッヂ' : host,
        ),
      );
    }
    return sources;
  }

  @override
  State<BoardCatalogScreen> createState() => _BoardCatalogScreenState();
}

class _BoardCatalogScreenState extends State<BoardCatalogScreen> {
  final _query = TextEditingController();
  final _selected = <String, BoardCatalogEntry>{};
  final _futures = <String, Future<BoardCatalog>>{};

  late List<BoardCatalogSource> _sources;
  late BoardCatalogSource _source;

  /// 追加中の進捗（`2/5` の 2）。null なら追加していない。
  int? _addingIndex;

  @override
  void initState() {
    super.initState();
    _sources = BoardCatalogScreen.sourcesFor(BoardStore.shared.boards);
    _source = _sources.first;
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<BoardCatalog> _catalog(BoardCatalogSource source) =>
      _futures[source.id] ??= BoardStore.shared.fetchCatalog(source);

  void _reload() {
    setState(() => _futures.remove(_source.id));
  }

  List<BoardCatalogCategory> _filter(BoardCatalog catalog) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return catalog.categories;
    final result = <BoardCatalogCategory>[];
    for (final category in catalog.categories) {
      final categoryHit = category.name.toLowerCase().contains(q);
      final entries = category.entries
          .where((entry) {
            if (categoryHit) return true;
            final haystack = '${entry.name} ${entry.boardKey} ${entry.host}'
                .toLowerCase();
            return haystack.contains(q);
          })
          .toList(growable: false);
      if (entries.isNotEmpty) {
        result.add(BoardCatalogCategory(name: category.name, entries: entries));
      }
    }
    return result;
  }

  /// 選んだ板を順に追加する。1 板ずつ実在確認の通信が要るので進捗を出す。
  Future<void> _addSelected() async {
    final entries = _selected.values.toList(growable: false);
    final store = BoardStore.shared;
    final added = <Board>[];
    final failed = <String>[];
    for (var i = 0; i < entries.length; i++) {
      setState(() => _addingIndex = i + 1);
      try {
        added.add(await store.addFromUrl(entries[i].url.toString()));
      } catch (_) {
        failed.add(entries[i].name);
      }
    }
    // 複数追加したときは最初の 1 枚を開く（addFromUrl は最後の板を選ぶため）。
    if (added.isNotEmpty) await store.select(added.first.id);
    if (!mounted) return;
    Navigator.pop(context, BoardCatalogResult(added: added, failed: failed));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final addedIds = BoardStore.shared.boards.map((b) => b.id).toSet();
    final adding = _addingIndex != null;
    return PopScope(
      canPop: !adding, // 追加中に戻ると板だけ増えて結果が伝わらない。
      child: Scaffold(
        appBar: AppBar(
          title: const Text('板を追加'),
          actions: [
            IconButton(
              tooltip: '板リストを再取得',
              icon: const Icon(Icons.refresh),
              onPressed: adding ? null : _reload,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(_sources.length > 1 ? 108 : 60),
            child: Column(
              children: [
                if (_sources.length > 1)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final source in _sources)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(source.label),
                              selected: source.id == _source.id,
                              onSelected: adding
                                  ? null
                                  : (_) => setState(() => _source = source),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '検索を消去',
                              icon: const Icon(Icons.clear),
                              onPressed: _query.clear,
                            ),
                      hintText: '板名・カテゴリ・板キーで検索',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        body: FutureBuilder<BoardCatalog>(
          future: _catalog(_source),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              final error = snapshot.error;
              return _CatalogError(
                message: error is BoardAddException
                    ? error.message
                    : '${_source.label} の板リストを取得できませんでした',
                onRetry: _reload,
              );
            }
            final catalog =
                snapshot.data ??
                const BoardCatalog(sourceName: '', categories: []);
            final categories = _filter(catalog);
            if (categories.isEmpty) {
              return const Center(child: Text('該当する板がありません'));
            }
            // カテゴリが 1 つだけの掲示板は、折りたたむ意味が無いので直に並べる。
            if (categories.length == 1) {
              final entries = categories.single.entries;
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: entries.length,
                itemBuilder: (context, i) => _entryTile(entries[i], addedIds),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: categories.length,
              itemBuilder: (context, i) {
                final category = categories[i];
                return ExpansionTile(
                  key: PageStorageKey('${_source.id}/${category.name}'),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(category.name),
                  subtitle: Text('${category.entries.length} 板'),
                  // 検索中は当たったカテゴリを開いた状態で見せる。
                  initiallyExpanded: _query.text.trim().isNotEmpty,
                  children: [
                    for (final entry in category.entries)
                      _entryTile(entry, addedIds, indent: true),
                  ],
                );
              },
            );
          },
        ),
        bottomNavigationBar: _selected.isEmpty
            ? null
            : SafeArea(
                child: Material(
                  color: scheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            adding
                                ? '$_addingIndex/${_selected.length} 件目を確認しています…'
                                : '${_selected.length} 板を選択中',
                          ),
                        ),
                        TextButton(
                          onPressed: adding
                              ? null
                              : () => setState(_selected.clear),
                          child: const Text('選択解除'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: adding ? null : _addSelected,
                          child: Text('${_selected.length} 板を追加'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _entryTile(
    BoardCatalogEntry entry,
    Set<String> addedIds, {
    bool indent = false,
  }) {
    final added = addedIds.contains(entry.id);
    final selected = _selected.containsKey(entry.id);
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.only(left: indent ? 24 : 8, right: 16),
      value: added || selected,
      onChanged: (added || _addingIndex != null)
          ? null
          : (checked) => setState(() {
              if (checked == true) {
                _selected[entry.id] = entry;
              } else {
                _selected.remove(entry.id);
              }
            }),
      title: Text(entry.name),
      subtitle: Text(
        added ? '追加済み' : '${entry.host} / ${entry.boardKey}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('再試行')),
          ],
        ),
      ),
    );
  }
}
