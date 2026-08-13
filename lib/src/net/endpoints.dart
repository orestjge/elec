import 'package:edge_core/edge_core.dart';

import 'board.dart';

/// 掲示板のエンドポイント。host / boardKey をここ 1 箇所に集約する。
///
/// 5ch 互換（eddist / 5ch）としたらばの板を host + boardKey で駆動する。エッヂ固有の
/// 経路（subject-metadent.txt・必死チェッカー・auth-code・client-config）は
/// [kind] でゲートする。既定はエッヂ（liveedge）で、[EdgeEndpoints.forBoard]
/// で任意の板に切り替える。
class EdgeEndpoints {
  const EdgeEndpoints({
    this.host = 'bbs.eddibb.cc',
    this.boardKey = 'liveedge',
    this.kind = BoardKind.eddist,
    this.hissiHost = 'www.kyodemo.net',
  });

  /// [Board] から生成する。エッヂ固有機能の可否は [Board.kind] に従う。
  factory EdgeEndpoints.forBoard(Board board) => EdgeEndpoints(
    host: board.host,
    boardKey: board.boardKey,
    kind: board.kind,
  );

  final String host;
  final String boardKey;

  /// 板の種別。エッヂ固有経路の可否を決める。
  final BoardKind kind;

  /// 必死チェッカー（kyodemo）のホスト。ID の投稿経路を外部で参照する。
  final String hissiHost;

  /// 必死チェッカー（kyodemo）側の板キー。kyodemo は **5ch 板を素の板キー**で、
  /// **eddibb の板を `e_e_` 接頭辞**で持つ（実確認: `/sdemo/b/news4vip/`,
  /// `/sdemo/b/e_e_liveedge/`）。したらばは `s_` 接頭辞だが現状は未対応。
  String get hissiBoardKey =>
      kind == BoardKind.eddist ? 'e_e_$boardKey' : boardKey;

  /// 5ch 互換（どんぐり・二段階 POST）か。
  bool get isFivech => kind == BoardKind.fivech;

  bool get isShitaraba => kind == BoardKind.shitaraba;

  /// 板のワイヤ文字コード。したらばだけ EUC-JP、他は Windows-31J。
  BbsTextEncoding get textEncoding =>
      isShitaraba ? BbsTextEncoding.eucJp : BbsTextEncoding.sjis;

  /// dat の行フォーマット。したらばは行頭にレス番号がある別形式。
  DatFormat get datFormat =>
      isShitaraba ? DatFormat.shitaraba : DatFormat.fivech;

  /// metadent（スレ立て人の識別子・スレ主 NG）を扱えるか。eddist のみ。
  bool get supportsMetadent => kind == BoardKind.eddist;

  /// 必死チェッカー導線を出せるか。kyodemo は 5ch・エッヂ双方に対応するので、
  /// 5ch 互換（eddist / fivech）なら出す。kyodemo が未収録の板ならリンク先が
  /// 空になるだけで害はない。
  bool get supportsHissi =>
      kind == BoardKind.eddist || kind == BoardKind.fivech;

  /// 書き込み（レス・スレ立て）に対応しているか。
  bool get supportsWrite => true;

  /// 書き込みフォームの方言。したらばだけ `write.cgi`（大文字フィールド・EUC-JP）。
  BbsDialect get writeDialect =>
      isShitaraba ? BbsDialect.shitaraba : BbsDialect.fivechCompat;

  /// 書き込み時に付ける `Referer`。レスはスレ URL、スレ立ては板トップ。
  ///
  /// 5ch は**要求する**（無いと landing へ飛ばされる。末尾スラッシュ無しの
  /// read.cgi URL＝Slevo に合わせる）。したらばは要求しないが、ブラウザの
  /// フォーム送信に合わせて付ける（フォームの action と同じスレの URL）。
  /// eddist は不要なので null。
  String? writeReferer({String? threadKey}) {
    if (isShitaraba) {
      return threadKey != null
          ? thread(threadKey).toString()
          : Uri.https(host, '/$boardKey/').toString();
    }
    if (kind != BoardKind.fivech) return null;
    if (threadKey != null) {
      return Uri.https(host, '/test/read.cgi/$boardKey/$threadKey').toString();
    }
    return Uri.https(host, '/$boardKey/').toString();
  }

  /// 書き込み時の User-Agent。5ch の bbs.cgi は **Monazilla 系 UA を要求**する
  /// （非 Monazilla は landing へ弾かれる）。したらばも専ブラを Monazilla で
  /// 見分ける（応答が `Vary: User-Agent`）ので同じものを名乗る。eddist は既定
  /// UA のままなので null。
  String? get writeUserAgent => kind == BoardKind.fivech || isShitaraba
      ? 'Monazilla/1.00 (elec/0.1)'
      : null;

  /// 書き込みが要求する投稿時刻（UNIX 秒）。フォームの hidden `time` / `TIME`。
  ///
  /// 5ch は無いと弾かれ、したらばはフォームがページ生成時刻を持つ。eddist は
  /// 受け取らないので null＝送らない。
  String? writeTime(DateTime now) =>
      kind == BoardKind.eddist ? null : '${now.millisecondsSinceEpoch ~/ 1000}';

  Uri get subjectTxt => Uri.https(host, '/$boardKey/subject.txt');

  /// スレ一覧＋スレ立て人の metadent 付き。subject.txt と同形式で、全スレに
  /// `[metadent★]` が付く。スレ主 NG の判定に使う。eddist のみ存在する。
  Uri get subjectMetadentTxt =>
      Uri.https(host, '/$boardKey/subject-metadent.txt');

  /// スレ一覧に使う URL。eddist は metadent 付き、それ以外は素の subject.txt。
  Uri get subjectListUrl => supportsMetadent ? subjectMetadentTxt : subjectTxt;

  Uri get settingTxt => isShitaraba
      ? Uri.https(host, '/bbs/api/setting.cgi/$boardKey/')
      : Uri.https(host, '/$boardKey/SETTING.TXT');

  /// 現行スレの dat。
  Uri dat(String threadKey) => isShitaraba
      ? Uri.https(host, '/bbs/rawmode.cgi/$boardKey/$threadKey/')
      : Uri.https(host, '/$boardKey/dat/$threadKey.dat');

  /// ブラウザで開けるスレッド URL。
  Uri thread(String threadKey) => isShitaraba
      ? Uri.https(host, '/bbs/read.cgi/$boardKey/$threadKey/')
      : Uri.https(host, '/$boardKey/$threadKey');

  /// 過去ログ（oyster/kako）。現行 dat が 404 のときのフォールバック。
  Uri kakoDat(String threadKey) {
    final t4 = threadKey.substring(0, 4);
    final t5 = threadKey.substring(0, 5);
    return Uri.https(host, '/$boardKey/kako/$t4/$t5/$threadKey.dat');
  }

  /// 書き込み先。eddist は `/test/bbs.cgi`。5ch は板の host（bbsmenu 由来の
  /// `.io`）に `?guid=ON`（Slevo・PROJECT.md の実測に合わせる）。body の `bbs=`
  /// で板を指定する。**成否は Monazilla UA・guid・time・Referer が揃うかで決まる**
  /// （どれか欠けると 302 で landing へ飛ばされる）。
  ///
  /// したらばだけは板ではなく**書き込み先そのもの**を URL で指す（レスは
  /// スレキー、スレ立ては `new`）ので [writeUrl] を使う。
  Uri get bbsCgi => kind == BoardKind.fivech
      ? Uri.https(host, '/test/bbs.cgi', {'guid': 'ON'})
      : Uri.https(host, '/test/bbs.cgi');

  /// 書き込みの POST 先。[threadKey] が null ならスレ立て。
  ///
  /// 5ch 系はレスもスレ立ても同じ bbs.cgi（宛先は body で指定）。したらばは
  /// `/bbs/write.cgi/{カテゴリ}/{掲示板ID}/{スレキー or new}/`。
  Uri writeUrl({String? threadKey}) => isShitaraba
      ? Uri.https(host, '/bbs/write.cgi/$boardKey/${threadKey ?? 'new'}/')
      : bbsCgi;

  /// 認証コード入力ページ（WebView で開く）。エッヂの auth-code 方式のみ。
  Uri get authCode => Uri.https(host, '/auth-code');

  /// クライアント設定 API。eddist のみ。
  Uri get clientConfig => Uri.https(host, '/api/client-config');

  /// 必死チェッカー（kyodemo）で、ある ID の「今日の他の書き込み」を開く URL。
  /// `k` にはレスに書かれる ID ハッシュをそのまま渡す。
  Uri hissi(String id) =>
      Uri.https(hissiHost, '/sdemo/b/$hissiBoardKey/', {'bs': 'hi', 'k': id});
}
