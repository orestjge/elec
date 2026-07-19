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

  Future<SubjectFetchResult> fetch(Uri url, {SubjectState? prev}) async {
    final headers = <String, String>{
      if (prev?.lastModified != null) 'If-Modified-Since': prev!.lastModified!,
    };
    final resp = await http.get(url, headers: headers);

    if (resp.statusCode == 304 && prev != null) {
      return SubjectFetchResult(state: prev, notModified: true);
    }
    if (resp.statusCode != 200) {
      throw HttpFetchException(resp.statusCode, url);
    }
    return SubjectFetchResult(
      state: SubjectState(
        threads: parseSubject(resp.bodyBytes),
        lastModified: resp.header('last-modified'),
      ),
      notModified: false,
    );
  }
}
