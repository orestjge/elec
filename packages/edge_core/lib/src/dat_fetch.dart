import 'dat_parser.dart';
import 'http.dart';
import 'models.dart';

/// スレッドの取得状態。累積した dat のバイト列とパース済みレスを保持する。
///
/// **不変オブジェクト。** 更新は [DatFetcher.fetch] が新しい [DatState] を
/// 返すことで行う。差分取得のたびに直前の状態を渡す。
class DatState {
  const DatState({
    required this.bytes,
    required this.res,
    required this.lastModified,
    this.pastLog = false,
  });

  /// 初回取得前の空状態。
  static const empty = DatState(bytes: [], res: [], lastModified: null);

  /// この dat が過去ログ（kako）から取れたか。現行 dat が 30x で過去ログへ
  /// リダイレクトされた＝ dat落ち、を意味する。true なら書き込み不可・差分
  /// ポーリング不要。
  final bool pastLog;

  /// これまでに受信した dat の生バイト列（完全な行のみ。サーバの dat は
  /// 常に改行終端なので末尾が欠けることはない）。次回 Range 要求の基準になる。
  final List<int> bytes;

  /// パース済みのレス一覧。
  final List<Res> res;

  /// 直近の `Last-Modified` ヘッダ値。次回 `If-Modified-Since` に使う。
  final String? lastModified;

  bool get isEmpty => bytes.isEmpty;

  /// スレッドタイトル（1 レス目から取得）。
  String? get threadTitle => res.isNotEmpty ? res.first.threadTitle : null;
}

/// 1 回の差分取得の結果。
class DatFetchResult {
  const DatFetchResult({
    required this.state,
    required this.newRes,
    required this.status,
  });

  /// 更新後の状態。次回取得にそのまま渡す。
  final DatState state;

  /// 今回新しく増えたレス。304 や新着 0 のときは空。
  final List<Res> newRes;

  /// 取得の結末。
  final DatFetchStatus status;
}

enum DatFetchStatus {
  /// 初回の全取得。
  initial,

  /// 差分を追記した（新着あり）。
  appended,

  /// 変化なし（304、または新着 0 の 206）。
  notModified,

  /// dat が書き換わっていた（あぼーん等）ため全再取得した。
  refetched,

  /// スレッドが存在しない（404）。過去ログにも無い。
  notFound,

  /// dat落ち。現行 dat が 30x で過去ログ（kako）へ飛び、そこから全取得した。
  pastLog,
}

/// dat の差分取得を行う。純粋なロジックで、通信は [HttpFetcher] 越し。
class DatFetcher {
  const DatFetcher(this.http);

  final HttpFetcher http;

  /// [url] のスレッドを取得する。[prev] に直前の状態を渡すと差分取得になる。
  ///
  /// 手順（PROJECT.md「差分取得」の実装）:
  /// 1. 保持サイズ N に対し `Range: bytes={N-1}-` と 1 バイト手前から要求。
  /// 2. 206 → 先頭 1 バイトが保持データの末尾と一致すれば追記。不一致なら
  ///    dat 書き換え（あぼーん）とみなし全再取得。
  /// 3. 304 → 変化なし。
  Future<DatFetchResult> fetch(
    Uri url, {
    DatState prev = DatState.empty,
  }) async {
    if (prev.isEmpty) {
      return _full(url, status: DatFetchStatus.initial);
    }

    final headers = <String, String>{
      'Range': 'bytes=${prev.bytes.length - 1}-',
      if (prev.lastModified != null) 'If-Modified-Since': prev.lastModified!,
    };
    final resp = await http.get(url, headers: headers);

    switch (resp.statusCode) {
      case 304:
        return DatFetchResult(
          state: prev,
          newRes: const [],
          status: DatFetchStatus.notModified,
        );

      case 404:
        return DatFetchResult(
          state: prev,
          newRes: const [],
          status: DatFetchStatus.notFound,
        );

      case 206:
        return _applyPartial(url, prev, resp);

      case 200:
        // サーバが Range を無視して全文を返した。置き換える。
        return _fromFullBody(
          resp,
          lastModified: resp.header('last-modified') ?? prev.lastModified,
          status: DatFetchStatus.refetched,
        );

      case final s when _isRedirect(s):
        // 閲覧中に 30x。過去ログ（kako）なら dat落ち、ホスト移設なら透過追従。
        return _followRedirect(url, resp, status: DatFetchStatus.refetched);

      default:
        throw HttpFetchException(resp.statusCode, url);
    }
  }

  static const _redirectStatuses = {301, 302, 303, 307, 308};
  static const _maxRedirects = 3;

  static bool _isRedirect(int status) => _redirectStatuses.contains(status);

  /// 30x を辿って移動先を全取得する。
  ///
  /// 遷移先が過去ログ（`/kako/`）なら **dat落ち**＝ [DatState.pastLog] を立てて
  /// 停止表示にする。それ以外（5ch の `.net → .io` のようなホスト移設）は
  /// **透過追従**して現行スレとして扱う。移動先が 404 なら notFound。
  ///
  /// [status] は透過追従時に付ける状態（初回なら initial、差分中の全再取得なら
  /// refetched）。
  Future<DatFetchResult> _followRedirect(
    Uri from,
    FetchResponse resp, {
    DatFetchStatus status = DatFetchStatus.pastLog,
    int hop = 0,
  }) async {
    final location = resp.header('location');
    if (location == null || location.isEmpty || hop >= _maxRedirects) {
      throw HttpFetchException(resp.statusCode, from);
    }
    final target = from.resolve(location);
    final isKako = target.pathSegments.contains('kako');
    final next = await http.get(target);
    if (next.statusCode == 404) {
      return DatFetchResult(
        state: DatState.empty,
        newRes: const [],
        status: DatFetchStatus.notFound,
      );
    }
    if (_isRedirect(next.statusCode)) {
      return _followRedirect(target, next, status: status, hop: hop + 1);
    }
    if (next.statusCode != 200) {
      throw HttpFetchException(next.statusCode, target);
    }
    return _fromFullBody(
      next,
      lastModified: next.header('last-modified'),
      status: isKako ? DatFetchStatus.pastLog : status,
      pastLog: isKako,
    );
  }

  Future<DatFetchResult> _applyPartial(
    Uri url,
    DatState prev,
    FetchResponse resp,
  ) async {
    final chunk = resp.bodyBytes;
    // 空の 206（末尾ちょうどを指定した等）は変化なし扱い。
    if (chunk.isEmpty) {
      return DatFetchResult(
        state: prev,
        newRes: const [],
        status: DatFetchStatus.notModified,
      );
    }

    // 先頭 1 バイトが保持データの末尾と一致するか。ここが差分取得の肝。
    final overlaps = chunk.first == prev.bytes.last;
    if (!overlaps) {
      // dat が書き換わっている（あぼーん等）。全再取得。
      return _full(url, status: DatFetchStatus.refetched);
    }

    // 2 バイト目以降が純粋な追記分。
    final appended = chunk.sublist(1);
    if (appended.isEmpty) {
      return DatFetchResult(
        state: prev,
        newRes: const [],
        status: DatFetchStatus.notModified,
      );
    }

    final bytes = [...prev.bytes, ...appended];
    // 追記分だけをパースする。番号は既存レス数の続きから。
    final newRes = parseDat(appended, startNumber: prev.res.length + 1);
    final state = DatState(
      bytes: bytes,
      res: [...prev.res, ...newRes],
      lastModified: resp.header('last-modified') ?? prev.lastModified,
    );
    return DatFetchResult(
      state: state,
      newRes: newRes,
      status: newRes.isEmpty
          ? DatFetchStatus.notModified
          : DatFetchStatus.appended,
    );
  }

  Future<DatFetchResult> _full(
    Uri url, {
    required DatFetchStatus status,
  }) async {
    final resp = await http.get(url);
    if (resp.statusCode == 404) {
      return DatFetchResult(
        state: DatState.empty,
        newRes: const [],
        status: DatFetchStatus.notFound,
      );
    }
    if (_isRedirect(resp.statusCode)) {
      // 過去ログ（kako）なら dat落ち、ホスト移設なら透過追従して現行扱い。
      return _followRedirect(url, resp, status: status);
    }
    if (resp.statusCode != 200) {
      throw HttpFetchException(resp.statusCode, url);
    }
    return _fromFullBody(
      resp,
      lastModified: resp.header('last-modified'),
      status: status,
    );
  }

  DatFetchResult _fromFullBody(
    FetchResponse resp, {
    required String? lastModified,
    required DatFetchStatus status,
    bool pastLog = false,
  }) {
    final res = parseDat(resp.bodyBytes);
    return DatFetchResult(
      state: DatState(
        bytes: resp.bodyBytes,
        res: res,
        lastModified: lastModified,
        pastLog: pastLog,
      ),
      newRes: res,
      status: status,
    );
  }
}

class HttpFetchException implements Exception {
  const HttpFetchException(this.statusCode, this.url);
  final int statusCode;
  final Uri url;
  @override
  String toString() => 'HttpFetchException($statusCode for $url)';
}
