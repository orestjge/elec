import 'models.dart';

/// スレッドの「勢い」= 1 日あたりのレス数。
///
/// 5ch 系専ブラの定番指標。作成からの経過時間でレス数を割る。live 板では
/// スレの活発さの目安になり、並べ替えにも使う。
///
/// [now] を注入できるようにしてあるのはテストのため（既定は現在時刻 UTC）。
double momentumPerDay(ThreadSummary thread, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now().toUtc()).difference(thread.createdAt);
  final days = elapsed.inSeconds / Duration.secondsPerDay;
  // 立ったばかり（経過 0 以下）はレス数をそのまま勢いとして扱い、0 除算を避ける。
  if (days <= 0) return thread.resCount.toDouble();
  return thread.resCount / days;
}
