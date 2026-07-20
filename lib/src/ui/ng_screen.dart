import 'package:flutter/material.dart';

import '../net/ng_store.dart';

/// NG ワード追加ダイアログを開く。追加されたら [NgWord]、取り消しなら null。
/// 設定画面とレスのメニューから共用する。
Future<NgWord?> showAddNgWordDialog(BuildContext context) {
  return showDialog<NgWord>(
    context: context,
    builder: (context) => const _AddWordDialog(),
  );
}

/// NG（あぼーん）設定画面。ワード（正規表現可）と ID を管理する。
class NgScreen extends StatelessWidget {
  const NgScreen({super.key, required this.store});

  final NgStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NG設定')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final words = store.words;
          final ids = store.ids;
          final creators = store.creators;
          return ListView(
            children: [
              _SectionHeader(title: 'NGワード', onAdd: () => _addWord(context)),
              if (words.isEmpty)
                const _EmptyHint('本文・名前に含まれると非表示にする語句を追加します')
              else
                for (final word in words)
                  ListTile(
                    leading: Icon(
                      word.isRegex ? Icons.data_object : Icons.notes,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(word.pattern),
                    subtitle: word.isRegex ? const Text('正規表現') : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () => store.removeWord(word),
                    ),
                  ),
              const Divider(height: 1),
              _SectionHeader(title: 'NG ID', onAdd: () => _addId(context)),
              if (ids.isEmpty)
                const _EmptyHint('この ID の書き込みを非表示にします')
              else
                for (final id in ids)
                  ListTile(
                    leading: Icon(
                      Icons.badge_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text('ID:$id'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () => store.removeId(id),
                    ),
                  ),
              const Divider(height: 1),
              _SectionHeader(
                title: 'NG スレ主',
                onAdd: () => _addCreator(context),
              ),
              if (creators.isEmpty)
                const _EmptyHint(
                  'スレ立て人（metadent）のスレを一覧から隠します。'
                  'スレを長押しして「このスレ主を NG」からも追加できます',
                )
              else
                for (final metadent in creators)
                  ListTile(
                    leading: Icon(
                      Icons.person_off_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text('[$metadent★]'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () => store.removeCreator(metadent),
                    ),
                  ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addWord(BuildContext context) async {
    final word = await showAddNgWordDialog(context);
    if (word != null) await store.addWord(word);
  }

  Future<void> _addId(BuildContext context) async {
    final id = await showDialog<String>(
      context: context,
      builder: (context) => const _AddIdDialog(),
    );
    if (id != null) await store.addId(id);
  }

  Future<void> _addCreator(BuildContext context) async {
    final metadent = await showDialog<String>(
      context: context,
      builder: (context) => const _AddCreatorDialog(),
    );
    if (metadent != null) await store.addCreator(metadent);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onAdd});
  final String title;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('追加'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// NG ワード追加ダイアログ。正規表現トグルと、正規表現時の妥当性チェック付き。
class _AddWordDialog extends StatefulWidget {
  const _AddWordDialog();

  @override
  State<_AddWordDialog> createState() => _AddWordDialogState();
}

class _AddWordDialogState extends State<_AddWordDialog> {
  final _controller = TextEditingController();
  bool _isRegex = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pattern = _controller.text.trim();
    if (pattern.isEmpty) {
      setState(() => _error = '語句を入力してください');
      return;
    }
    if (_isRegex && !NgStore.isValidRegex(pattern)) {
      setState(() => _error = '正規表現が不正です');
      return;
    }
    Navigator.pop(context, NgWord(pattern, isRegex: _isRegex));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NGワードを追加'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: _isRegex ? r'例: (荒らし|コピペ)+' : '例: 荒らし',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _isRegex,
            title: const Text('正規表現として扱う'),
            onChanged: (v) => setState(() {
              _isRegex = v ?? false;
              _error = null;
            }),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}

/// NG ID 追加ダイアログ。
class _AddIdDialog extends StatefulWidget {
  const _AddIdDialog();

  @override
  State<_AddIdDialog> createState() => _AddIdDialogState();
}

class _AddIdDialogState extends State<_AddIdDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    var id = _controller.text.trim();
    // 「ID:xxxx」で貼られても受け付ける。
    if (id.toUpperCase().startsWith('ID:')) id = id.substring(3).trim();
    if (id.isEmpty) {
      setState(() => _error = 'ID を入力してください');
      return;
    }
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NG ID を追加'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '例: bdwCNFndK',
          prefixText: 'ID:',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}

/// NG スレ主（metadent）追加ダイアログ。`[xxx★]` で貼られても受け付ける。
class _AddCreatorDialog extends StatefulWidget {
  const _AddCreatorDialog();

  @override
  State<_AddCreatorDialog> createState() => _AddCreatorDialogState();
}

class _AddCreatorDialogState extends State<_AddCreatorDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    // 「[xxx★]」の飾りを外して metadent 本体だけにする。
    var metadent = _controller.text.trim();
    if (metadent.startsWith('[')) metadent = metadent.substring(1);
    metadent = metadent.replaceAll('★', '').replaceAll(']', '').trim();
    if (metadent.isEmpty) {
      setState(() => _error = 'metadent を入力してください');
      return;
    }
    Navigator.pop(context, metadent);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NG スレ主を追加'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '例: B3YfDSAP',
          helperText: 'スレ一覧の [xxx★] の中身（metadent）',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}
