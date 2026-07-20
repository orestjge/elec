/// エッヂのエンドポイント。board / host をここ 1 箇所に集約する。
///
/// PROJECT.md の「将来の 5ch 対応に向けた抽象化」方針どおり、定数を散らさず
/// ここだけにまとめる。初期スコープでは liveedge 固定。
class EdgeEndpoints {
  const EdgeEndpoints({
    this.host = 'bbs.eddibb.cc',
    this.boardKey = 'liveedge',
    this.hissiHost = 'www.kyodemo.net',
    this.hissiBoardKey = 'e_e_liveedge',
  });

  final String host;
  final String boardKey;

  /// 必死チェッカー（kyodemo）のホスト。ID の投稿経路を外部で参照する。
  final String hissiHost;

  /// 必死チェッカー側の板キー。kyodemo は eddibb の板を `e_e_` 接頭辞で持つ。
  final String hissiBoardKey;

  Uri get subjectTxt => Uri.https(host, '/$boardKey/subject.txt');

  /// スレ一覧＋スレ立て人の metadent 付き。subject.txt と同形式で、全スレに
  /// `[metadent★]` が付く。スレ主 NG の判定に使う。
  Uri get subjectMetadentTxt =>
      Uri.https(host, '/$boardKey/subject-metadent.txt');

  Uri get settingTxt => Uri.https(host, '/$boardKey/SETTING.TXT');

  /// 現行スレの dat。
  Uri dat(String threadKey) => Uri.https(host, '/$boardKey/dat/$threadKey.dat');

  /// ブラウザで開けるスレッド URL。
  Uri thread(String threadKey) => Uri.https(host, '/$boardKey/$threadKey');

  /// 過去ログ（oyster/kako）。現行 dat が 404 のときのフォールバック。
  Uri kakoDat(String threadKey) {
    final t4 = threadKey.substring(0, 4);
    final t5 = threadKey.substring(0, 5);
    return Uri.https(host, '/$boardKey/kako/$t4/$t5/$threadKey.dat');
  }

  /// 書き込み先。bbs.cgi は board を問わず共通で、body の `bbs=` で板を指定する。
  Uri get bbsCgi => Uri.https(host, '/test/bbs.cgi');

  /// 認証コード入力ページ（WebView で開く）。
  Uri get authCode => Uri.https(host, '/auth-code');

  /// クライアント設定 API。
  Uri get clientConfig => Uri.https(host, '/api/client-config');

  /// 必死チェッカー（kyodemo）で、ある ID の「今日の他の書き込み」を開く URL。
  /// `k` にはレスに書かれる ID ハッシュをそのまま渡す。
  Uri hissi(String id) =>
      Uri.https(hissiHost, '/sdemo/b/$hissiBoardKey/', {'bs': 'hi', 'k': id});
}
