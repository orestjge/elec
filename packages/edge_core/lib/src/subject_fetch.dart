import 'dat_fetch.dart' show HttpFetchException;
import 'http.dart';
import 'models.dart';
import 'subject_parser.dart';

/// スレ一覧の取得状態。パース済みスレッドと `Last-Modified` を持つ。
class SubjectState {
  const SubjectState({required this.threads, required this.lastModified});

  final List<ThreadSummary> threads;

  /// 直近の `Last-Modified`。次回 `If-Modified-Since` に使う。
  final String? lastModified;
}

/// 1 回の取得結果。
class SubjectFetchResult {
  const SubjectFetchResult({required this.state, required this.notModified});

  final SubjectState state;

  /// 304（変化なし）だったか。true のとき [state] は前回と同一。
  final bool notModified;
}

/// subject.txt を条件付き GET する。
///
/// **Range 差分は使わない。** subject.txt はレス数やスレ順が行内で書き換わる
/// ため追記型では扱えない。`If-Modified-Since` で 304/200 を分けるのが正解
/// （変化なしなら数百バイトで済む）。ポーリングでの定期取得を想定。
class SubjectFetcher {
  const SubjectFetcher(this.http);

  final HttpFetcher http;

  static const _maxRedirects = 3;
  static const _redirectStatuses = {301, 302, 303, 307, 308};
  static bool _isRedirect(int status) => _redirectStatuses.contains(status);

  /// [metadent] が true なら `subject-metadent.txt` としてパースし、各スレの
  /// [ThreadSummary.metadent]（スレ立て人の識別子）を埋める。
  Future<SubjectFetchResult> fetch(
    Uri url, {
    SubjectState? prev,
    bool metadent = false,
  }) async {
    final headers = <String, String>{
      if (prev?.lastModified != null) 'If-Modified-Since': prev!.lastModified!,
    };
    // 5ch は板ごとにホストが分散し、`.net → .io` を 308 で恒久リダイレクトする。
    // 板追加時にホストを正規化するが、取りこぼしても読めるよう透過追従もする。
    var target = url;
    var resp = await http.get(target, headers: headers);
    for (
      var hop = 0;
      _isRedirect(resp.statusCode) && hop < _maxRedirects;
      hop++
    ) {
      final location = resp.header('location');
      if (location == null || location.isEmpty) break;
      target = target.resolve(location);
      resp = await http.get(target, headers: headers);
    }

    if (resp.statusCode == 304 && prev != null) {
      return SubjectFetchResult(state: prev, notModified: true);
    }
    if (resp.statusCode != 200) {
      throw HttpFetchException(resp.statusCode, target);
    }
    return SubjectFetchResult(
      state: SubjectState(
        threads: parseSubject(resp.bodyBytes, metadent: metadent),
        lastModified: resp.header('last-modified'),
      ),
      notModified: false,
    );
  }
}
