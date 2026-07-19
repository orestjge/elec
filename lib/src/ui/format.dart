// 表示用の数値・時刻フォーマット。

/// レス数や勢いを短く。1000 以上は `1.2k`。
String formatCompact(num n) {
  if (n >= 10000) return '${(n / 1000).round()}k';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return n.round().toString();
}

/// スレ作成からの経過を相対表記に。
String formatAge(DateTime createdUtc, {DateTime? now}) {
  final d = (now ?? DateTime.now()).toUtc().difference(createdUtc);
  if (d.inMinutes < 1) return 'たった今';
  if (d.inMinutes < 60) return '${d.inMinutes}分前';
  if (d.inHours < 24) return '${d.inHours}時間前';
  if (d.inDays < 30) return '${d.inDays}日前';
  final months = d.inDays ~/ 30;
  if (months < 12) return '$monthsヶ月前';
  return '${d.inDays ~/ 365}年前';
}
