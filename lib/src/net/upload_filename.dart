import 'dart:math';

final _random = Random.secure();

/// アップロード先に元のファイル名が残らないよう、ランダムな名前へ置き換える。
///
/// 元のファイル名は端末名や本名・撮影内容を示すことがあり、そのまま公開 URL や
/// 画像ページに載ると好ましくない（特に ImgBB は送った名前を表示に使う）。
/// 中身の種類はわかった方がよいので、拡張子だけは維持する（無ければ付けない）。
String randomizedUploadFilename(String original) {
  final ext = _extensionOf(original);
  final token = List<int>.generate(
    8,
    (_) => _random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return ext.isEmpty ? token : '$token.$ext';
}

/// 拡張子らしい末尾（英数字・短い）だけを取り出す。無ければ空文字。
String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  final ext = name.substring(dot + 1);
  if (ext.length > 5 || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) return '';
  return ext.toLowerCase();
}
