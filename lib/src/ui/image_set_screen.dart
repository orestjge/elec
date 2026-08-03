import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'back_swipe.dart';
import 'image_editor_screen.dart';

/// 選んだ画像を送る前に通す画面を出し、実際に送るものを返す。やめたときは null。
///
/// **1 枚だけなら一覧を挟まず編集画面へ直行する。** 大半は 1 枚なので、そこに
/// 画面を 1 つ増やさない。
Future<List<XFile>?> prepareImagesForUpload(
  BuildContext context,
  List<XFile> picked,
) async {
  if (picked.length == 1) {
    final edited = await pushImageEditor(context, picked.first);
    return edited == null ? null : [edited];
  }
  return Navigator.of(context).push<List<XFile>>(
    SwipeBackPageRoute<List<XFile>>(
      pageBuilder: (_, _, _) => ImageSetScreen(files: picked),
    ),
  );
}

/// 複数枚を送る前の一覧。並んだサムネイルから 1 枚ずつ編集画面へ入る。
///
/// 編集画面は 1 枚を扱う作りのままにしてある（拡大・書き出しプレビュー・つまみの
/// 当たり判定をそのまま使える）。複数枚の面倒はこの画面だけが見る。
class ImageSetScreen extends StatefulWidget {
  const ImageSetScreen({super.key, required this.files});

  final List<XFile> files;

  @override
  State<ImageSetScreen> createState() => _ImageSetScreenState();
}

class _ImageSetScreenState extends State<ImageSetScreen> {
  late final List<_PickedImage> _images = [
    for (final file in widget.files) _PickedImage(file),
  ];

  Future<void> _edit(int index) async {
    final entry = _images[index];
    final result = await pushImageEditor(context, entry.file);
    if (result == null || !mounted) return;
    // 編集画面は無編集なら同じインスタンスを返す。差し替わったときだけ
    // 「編集済み」とし、サムネイルも作り直したバイト列から描く。
    if (identical(result, entry.file)) return;
    final bytes = await result.readAsBytes();
    if (!mounted) return;
    setState(() {
      _images[index] = _PickedImage(result, bytes: bytes);
    });
  }

  void _remove(int index) => setState(() => _images.removeAt(index));

  void _send() => Navigator.of(context).pop([for (final e in _images) e.file]);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${_images.length} 枚の画像'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('image-set-send'),
              onPressed: _images.isEmpty ? null : _send,
              // 「送信」だとレスそのものを投稿すると読めてしまう。この画面が
              // やるのは画像を確定してアップロードするところまでなので、
              // 編集画面と同じ「完了」で揃える。
              child: const Text('完了'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'タップで 1 枚ずつ編集できます。上から順にアップロードします。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _images.length,
              itemBuilder: (context, index) =>
                  _tile(theme, _images[index], index),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ThemeData theme, _PickedImage entry, int index) {
    return Stack(
      key: ValueKey('image-set-tile-$index'),
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: _Thumbnail(entry: entry),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _edit(index),
          ),
        ),
        if (entry.bytes != null)
          Positioned(
            left: 4,
            bottom: 4,
            child: _Badge(text: '編集済み', theme: theme),
          ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: '外す',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.8),
            ),
            onPressed: () => _remove(index),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }
}

/// 一覧に並べる 1 枚。編集して差し替わったものだけバイト列を持つ。
class _PickedImage {
  _PickedImage(this.file, {this.bytes});

  final XFile file;

  /// 編集後のバイト列。端末上のファイルではないので、これを直接描く。
  final Uint8List? bytes;
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.entry});

  final _PickedImage entry;

  @override
  Widget build(BuildContext context) {
    const cacheWidth = 320;
    final bytes = entry.bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: _broken,
      );
    }
    return Image.file(
      File(entry.file.path),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: _broken,
    );
  }

  /// 読めない画像でも一覧が崩れないようにする（選んだ後に消えることもある）。
  static Widget _broken(BuildContext context, Object error, StackTrace? stack) {
    return Center(
      child: Icon(
        Icons.broken_image_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onInverseSurface,
          ),
        ),
      ),
    );
  }
}
