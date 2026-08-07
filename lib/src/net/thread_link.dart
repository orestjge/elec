/// 本文に貼られた**スレッドの URL**を、板一覧の中のスレとして解決する。
///
/// スレ URL は OGP との相性が悪い。現行スレの read.cgi が og を書いていない板が
/// 普通にあるうえ、dat落ちしたスレは「過去ログ倉庫」の案内ページへ飛ばされる
/// ので、取れたところでリンク先とは無関係の見出しが出る。
///
/// 一方こちらは掲示板クライアントなので、**dat を直接読めばスレタイが分かる**。
/// dat落ちも同じ経路で拾える（現行 dat が過去ログへ 30x する。しない板向けに
/// `kako` の置き場も 1 回だけ見る）。
///
/// 取りに行くのは [[board_store]] が知っている板のスレだけに限る。既に一覧や
/// スレを読みに行っているホストなので、貼られたリンクを開かないまま知らない
/// サーバへ通信が広がることが無い。同じ理由で、OGP を切っていても（
/// [ThreadViewSettings.linkPreviews] が false でも）これは出す。
///
/// 取りに行くときの防御は [[link_preview]] と同じ考え方:
///  - dat の先頭 [ThreadLinks.headBytes] だけ Range で読む。要るのは 1 レス目
///    だけで、完走したスレの dat は数百 KB ある。
///  - 全体に制限時間を掛ける。
///  - 結果はプロセス内に覚える（**失敗も覚える**）。
library;

import 'dart:async';

import 'package:edge_core/edge_core.dart';
import 'package:flutter/foundation.dart';

import 'board.dart';
import 'board_store.dart';
import 'endpoints.dart';
import 'http_fetcher.dart';

/// 貼られた URL が指していた「どの板のどのスレか」。
class ThreadLinkTarget {
  const ThreadLinkTarget({required this.board, required this.ref});

  /// 板一覧の中で見つかった板。
  final Board board;

  /// URL から取り出したスレの参照。
  final ThreadRef ref;

  String get threadKey => ref.threadKey;

  /// アプリ内で開くときの正規 URL。貼られた表記（旧ホスト・read.cgi 形式）では
  /// なく、板一覧が持つホストで組み直す。
  Uri get canonicalUrl => EdgeEndpoints.forBoard(board).thread(threadKey);

  String get cacheKey => '${board.id}/$threadKey';

  @override
  bool operator ==(Object other) =>
      other is ThreadLinkTarget && other.board == board && other.ref == ref;

  @override
  int get hashCode => Object.hash(board, ref);
}

/// スレカード 1 枚ぶんの中身。
class ThreadLinkInfo {
  const ThreadLinkInfo({
    required this.target,
    required this.title,
    this.excerpt,
    this.createdAt,
    this.pastLog = false,
  });

  final ThreadLinkTarget target;

  /// スレタイ（dat の 1 レス目から）。
  final String title;

  /// 1 レス目の冒頭。無ければ null。
  final String? excerpt;

  /// スレが立った時刻（UTC）。1 レス目の日付欄から取り、読めなければスレキー
  /// （＝スレ立て時の UNIX 秒）から起こす。どちらも駄目なら null。
  ///
  /// 貼られたスレが今の話なのか何年も前のものなのかは、開く前に知りたい。
  /// スレタイだけでは実況スレも過去ログも同じ顔で並ぶ。
  final DateTime? createdAt;

  /// 過去ログ（dat落ち）から取れたか。
  final bool pastLog;

  Board get board => target.board;
}

/// スレ URL の解決器。UI からは [targetOf] → [resolve] の順に呼ぶ。
class ThreadLinks {
  ThreadLinks._();

  /// dat の先頭から読むバイト数。1 レス目 1 行だけが要る。
  ///
  /// エッヂの本文上限は 9192 文字で、Shift_JIS だと 1 レスで 18KB を超え得る。
  /// 1 行を読み切れないと（[splitDatLines] が不完全な行を捨てるので）スレタイが
  /// 取れないため、上限いっぱいのレスでも収まる幅を取る。
  static const headBytes = 32 << 10;

  /// 1 件あたりの制限時間。
  static const _timeout = Duration(seconds: 8);

  /// 覚えておく件数の上限。
  static const _maxCached = 128;

  static const _redirectStatuses = {301, 302, 303, 307, 308};
  static const _maxRedirects = 3;

  /// 対象にする板の一覧。既定は利用者が追加した板（[BoardStore]）。
  static List<Board> Function() boards = () => BoardStore.shared.boards;

  /// 通信に使う実装。掲示板サーバ向けなので、スレ本体と同じ [HttpClientFetcher]
  /// （IPv6 優先・30x を追わない）を使う。
  static HttpFetcher? _sharedFetcher;

  static HttpFetcher get _fetcher => _sharedFetcher ??= HttpClientFetcher();

  /// 解決済み（失敗を含む）。挿入順に並ぶので古いものから捨てられる。
  static final _cache = <String, Future<ThreadLinkInfo?>>{};

  /// 取れた中身。[cachedTitle] が待たずに引くための控え。
  static final _resolved = <String, ThreadLinkInfo>{};

  /// [url] が板一覧の中のスレを指しているなら、その対象を返す。違えば null。
  ///
  /// **通信しない。** 貼られた URL がスレカードの対象かどうかだけを判定する
  /// （本文の切り分けでも使うので、レスを描くたびに走る）。
  static ThreadLinkTarget? targetOf(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final ref = parseThreadUrl(url);
    if (ref == null) return null;
    final host = url.host.toLowerCase();
    ThreadLinkTarget? alias;
    for (final board in boards()) {
      if (board.boardKey != ref.board) continue;
      if (board.host.toLowerCase() == host) {
        return ThreadLinkTarget(board: board, ref: ref);
      }
      // 同じ板が別ホスト名で貼られることがある（5ch の `.net`↔`.io`、itest、
      // したらばの旧 livedoor ドメイン）。板キーはその掲示板の中で一意なので、
      // 同系のホストどうしなら板キーだけで結び付ける。ホスト一致を優先し、
      // 見つからなかったときだけこちらを使う。
      if (_sameFamily(host, board.host.toLowerCase())) {
        alias ??= ThreadLinkTarget(board: board, ref: ref);
      }
    }
    return alias;
  }

  /// [target] のスレタイ等を返す。取れなければ null。
  static Future<ThreadLinkInfo?> resolve(ThreadLinkTarget target) {
    final key = target.cacheKey;
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = _resolve(target).then((info) {
      if (info != null) _resolved[key] = info;
      return info;
    });
    _cache[key] = future;
    if (_cache.length > _maxCached) {
      _resolved.remove(_cache.keys.first);
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  /// 既に取れているスレタイ。まだ取っていない・取れなかったときは null。
  ///
  /// スレを開くときに使う。待たずに分かるぶんだけ使い、無ければ空のまま開いて
  /// dat から埋めさせる（開くのを通信で待たせない）。
  static String? cachedTitle(ThreadLinkTarget target) =>
      _resolved[target.cacheKey]?.title;

  /// テスト用に通信を差し替える。null に戻すと素の実装へ戻る。
  @visibleForTesting
  static set debugFetcher(HttpFetcher? fetcher) {
    final previous = _sharedFetcher;
    if (previous is HttpClientFetcher) previous.close();
    _sharedFetcher = fetcher;
  }

  /// テスト間で覚えた結果を捨てる。
  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    _resolved.clear();
  }

  static Future<ThreadLinkInfo?> _resolve(ThreadLinkTarget target) async {
    try {
      return await _head(target).timeout(_timeout);
    } catch (_) {
      // 通信失敗・タイムアウト・想定外の dat はすべて「カード無し」に倒す。
      // リンクは本文にそのまま残るので、読む側が失うものは無い。
      return null;
    }
  }

  /// dat の先頭を取ってスレタイを読む。30x は自分で辿る（`kako` へ飛んだら
  /// dat落ち）。
  static Future<ThreadLinkInfo?> _head(ThreadLinkTarget target) async {
    final endpoints = EdgeEndpoints.forBoard(target.board);
    var url = _headUrl(endpoints, target.threadKey);
    var pastLog = false;
    var triedKako = false;

    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final resp = await _fetcher.get(url, headers: _headers(endpoints));
      final status = resp.statusCode;

      if (status == 200 || status == 206) {
        return _parse(target, resp.bodyBytes, endpoints, pastLog: pastLog);
      }

      if (_redirectStatuses.contains(status)) {
        final location = resp.header('location');
        if (location == null || location.isEmpty) return null;
        url = url.resolve(location);
        if (url.pathSegments.contains('kako')) pastLog = true;
        continue;
      }

      // 現行 dat が消えているのに過去ログへ飛ばさない板がある。置き場は板キーと
      // スレキーから決まるので、1 回だけ直接見に行く。
      if (status == 404 && !triedKako && !endpoints.isShitaraba) {
        triedKako = true;
        pastLog = true;
        url = endpoints.kakoDat(target.threadKey);
        continue;
      }

      return null;
    }
    return null;
  }

  /// 先頭だけ取るための URL。
  ///
  /// したらばの rawmode は Range ではなく URL でレス範囲を指定する形なので、
  /// 1 レス目だけを名指しする。
  static Uri _headUrl(EdgeEndpoints endpoints, String threadKey) {
    final dat = endpoints.dat(threadKey);
    if (!endpoints.isShitaraba) return dat;
    return dat.replace(path: '${dat.path}1');
  }

  static Map<String, String> _headers(EdgeEndpoints endpoints) =>
      endpoints.isShitaraba
      ? const {}
      : const {'Range': 'bytes=0-${headBytes - 1}'};

  /// 受け取ったバイト列の 1 行目からスレタイと冒頭を作る。
  ///
  /// **改行までで切ってから渡す。** Range で切れた末尾は文字の途中で終わって
  /// いることがあり、行として読める保証が無い。改行が 1 つも無ければ 1 レス目を
  /// 読み切れていないので諦める（[headBytes] を超える長さのレス）。
  static ThreadLinkInfo? _parse(
    ThreadLinkTarget target,
    List<int> bytes,
    EdgeEndpoints endpoints, {
    required bool pastLog,
  }) {
    final lineEnd = bytes.indexOf(0x0A);
    if (lineEnd < 0) return null;
    final res = parseDat(
      bytes.sublist(0, lineEnd + 1),
      encoding: endpoints.textEncoding,
      format: endpoints.datFormat,
    );
    if (res.isEmpty) return null;
    final first = res.first;
    final title = htmlToText(first.threadTitle ?? '').trim();
    if (title.isEmpty) return null;
    return ThreadLinkInfo(
      target: target,
      title: title,
      excerpt: _excerpt(first.body),
      createdAt: first.dateTime ?? _keyTime(target.threadKey),
      pastLog: pastLog,
    );
  }

  /// スレキーから起こしたスレ立て時刻。5ch 系もしたらばもキーは UNIX 秒。
  ///
  /// 1 レス目の日付欄が読めない板・形式（したらばの `rawmode` は日付欄の形が
  /// 違う）でも、キーからなら必ず出せる。
  static DateTime? _keyTime(String threadKey) {
    final seconds = int.tryParse(threadKey);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  /// 1 レス目の冒頭。カードは 1〜2 行しか出せないので改行や連続空白は潰す
  /// （AA が貼られていても、崩れた形を出すより 1 行に詰める方がまし）。
  static String? _excerpt(String body) {
    final text = htmlToText(body).replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  /// 同じ掲示板の別ホスト名か。
  static bool _sameFamily(String a, String b) =>
      (_isFivechHost(a) && _isFivechHost(b)) ||
      (_isShitarabaHost(a) && _isShitarabaHost(b));

  static bool _isFivechHost(String host) =>
      host.endsWith('.5ch.net') ||
      host.endsWith('.5ch.io') ||
      host.endsWith('.bbspink.com');

  static bool _isShitarabaHost(String host) =>
      host == 'jbbs.shitaraba.net' || host == 'jbbs.livedoor.jp';
}
