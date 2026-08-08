/// 「n分前」表示を進めるための時計。
///
/// 相対表記は放っておくと古びる（描き直されるまで「5分前」のまま止まる）。
/// かといってレスの数だけタイマーを持つのは無駄なので、**アプリ全体で 1 本**
/// 回して、表示側はそれを見に来る。聞き手が居なくなればタイマーも止める
/// （画面を閉じたあともタイマーが残らないようにするため。テストの「タイマーが
/// 残っている」判定にも引っかからない）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'format.dart';

/// 1 分ごとに今を配る時計。聞き手が居る間だけ動く。
class NowTicker extends ValueNotifier<DateTime> {
  NowTicker() : super(DateTime.now());

  /// 表示は分単位（「n分前」）なので、1 分ごとで足りる。
  static const interval = Duration(minutes: 1);

  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(interval, (_) => value = DateTime.now());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// アプリで 1 本の時計。相対表記を出している間だけ動く。
final nowTicker = NowTicker();

/// レスの時刻表示。相対表記になる間だけ [nowTicker] を見て描き直す。
///
/// 1 日以上前のレス（＝表示が変わらない）では時計を見に行かない。古いスレを
/// 開いただけでタイマーが回り、全レスが 1 分ごとに描き直されるのを避ける。
class LiveResTime extends StatelessWidget {
  const LiveResTime({
    super.key,
    required this.when,
    required this.text,
    required this.builder,
  });

  /// レスの時刻（UTC）。分からなければ null。
  final DateTime? when;

  /// その時点での表示文字列。
  final String Function(DateTime now) text;

  final Widget Function(BuildContext context, String text) builder;

  @override
  Widget build(BuildContext context) {
    if (relativeResTime(when) == null) {
      return builder(context, text(DateTime.now()));
    }
    return ValueListenableBuilder<DateTime>(
      valueListenable: nowTicker,
      builder: (context, now, _) => builder(context, text(now)),
    );
  }
}
