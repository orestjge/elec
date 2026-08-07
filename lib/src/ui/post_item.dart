import 'dart:async';
import 'dart:math' as math;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/thread_link.dart';
import 'mini_player.dart';
import 'id_color.dart';
import 'id_icon.dart';
import 'image_urls.dart';
import 'link_card.dart';
import 'post_body_segments.dart';
import 'post_images.dart';
import 'reply_tier.dart';
import 'res_body.dart';

/// スレッドの 1 レス。番号順タイムライン向けの密なレイアウト。
/// 名前・本文は [htmlToText] で整形して表示する。
class PostItem extends StatelessWidget {
  const PostItem({
    super.key,
    required this.res,
    required this.idCount,
    required this.idOrdinal,
    required this.onTapId,
    this.onTapRes,
    this.onTapResRange,
    this.onTapUrl,
    this.replyCount = 0,
    this.onTapReplies,
    this.onBodySelectionActiveChanged,
    this.onLongPress,
    this.bodySelectable = true,
    this.isOwn = false,
    this.isThreadOwner = false,
    this.isReplyToOwn = false,
    this.showReplyToOwnAccent = true,
    this.blurImages = false,
    this.linkPreviews = false,
    this.highlightQuery = '',
    this.isCurrentMatch = false,
    this.defaultName,
  });

  final Res res;

  /// このスレでの同一 ID の総数（1 なら単発）。
  final int idCount;

  /// このレスが同一 ID 内で何番目か（1 始まり）。
  final int idOrdinal;

  /// ID タップ時。同一 ID のレス一覧を出す。ヘッダの ID チップと、本文に貼られた
  /// `ID:xxx`（他のレスの引用）の両方から呼ぶ。
  final ValueChanged<String>? onTapId;

  /// `>>N` タップ時。該当レスへスクロールする。
  final ValueChanged<int>? onTapRes;

  /// `>>N-M` タップ時。範囲内のレスをまとめて扱う。
  final ValueChanged<List<int>>? onTapResRange;

  /// URL タップ時。ブラウザで開く。
  final ValueChanged<Uri>? onTapUrl;

  /// このレスが受けた返信の数（0 なら表示しない）。
  final int replyCount;

  /// 返信数タップ時。このレスへの返信一覧を出す。
  final ValueChanged<int>? onTapReplies;

  /// 本文の文字選択状態が変わったとき。
  final ValueChanged<bool>? onBodySelectionActiveChanged;

  /// レスを長押ししたとき。レス全体のコピーや ID 操作のメニューを出す。
  ///
  /// タップでは開かない。本文の `>>N` や URL を狙って触れただけ、スクロールを
  /// 止めるために触れただけでメニューが出ると邪魔になるため。押している間は指の
  /// 位置から沈み込みが広がって、離す前に「今どのレスを掴んでいるか」が分かる。
  final VoidCallback? onLongPress;

  /// 本文を範囲選択できるようにするか。通常一覧では false、メニュー内では true。
  final bool bodySelectable;

  /// このアプリから投稿したレスか。
  final bool isOwn;

  /// スレ主（`>>1` を書いた人）のレスか。
  ///
  /// スレ主はそのスレの言い出しっぺで、話の前提や進行を握っている。番号を出さない
  /// ヘッダでは `>>1` すら他のレスと同じ見た目になってしまうので、印を付けて
  /// 「これは立てた人の発言」と流し読みでも分かるようにする。
  final bool isThreadOwner;

  /// 自分のレスへ `>>N` で返信しているレスか（自分宛のレス）。
  final bool isReplyToOwn;

  /// 自分宛レスの左アクセント帯をこのレス内で描くか。
  final bool showReplyToOwnAccent;

  /// この画像に「グロ」注意が付いており、サムネイルへモザイクを掛けるか。
  final bool blurImages;

  /// 行を単独で占めるリンクの OGP を取りに行き、カードで見せるか。
  ///
  /// リンク先へ端末から直接アクセスすることになるので、既定では取りに行かない。
  /// 設定（[ThreadViewSettings.linkPreviews]）を持っている画面だけが真を渡す。
  ///
  /// 知っている板のスレ URL のカードはこの値に関わらず出る（[ThreadLinks]）。
  final bool linkPreviews;

  /// スレ内検索中の検索語。空でなければ名前・本文の一致箇所をハイライトする。
  final String highlightQuery;

  /// このレスが現在ジャンプ中の一致レスか。アイテムごと強調する。
  final bool isCurrentMatch;

  /// 板の既定の名前（`BBS_NONAME_NAME`。例: `エッヂの名無し`）。
  ///
  /// これと同じ名前＝名無しなので、ヘッダから名前ごと省く。ほとんどのレスが
  /// 名無しなのに毎行同じ文字列が入ると、その分だけ ID の開始位置が名前の長さで
  /// 前後してしまい、上下のレスで ID を見比べにくいため。コテハンだけが残るので
  /// 「誰か」が付いているレスも見つけやすくなる。
  ///
  /// 板から取れていない（null）ときは省略しない。名無しかどうか判断できない
  /// 名前を勝手に消すと、コテハンを消す事故になるため。
  final String? defaultName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (res.isAbone) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          '${res.number} あぼーん',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    final name = htmlToText(res.name).trim();
    // AA はインデントや上下の余白が絵の一部になるのでそのまま残し、普通のレスは
    // 前後の空白・空行を落として詰める。
    final body = trimUnlessAsciiArt(htmlToText(res.body));
    // スレ URL は OGP の設定に関わらずカードにする（中身は掲示板サーバから
    // 取るので、リンク先へ通信が広がらない。詳しくは [ThreadLinks]）。
    final segments = splitPostBody(
      body,
      linkPreviews: linkPreviews,
      isThreadLink: (url) => ThreadLinks.targetOf(url) != null,
    );
    // 全画面ビューアはレス内の全画像を送れるようにする。本文の途中で区画に
    // 分かれても、どのサムネイルから開いても並びは同じ。
    final allImages = imageUrlsIn(body);

    void openUrl(Uri url) {
      final imageIndex = allImages.indexWhere((image) => image == url);
      if (imageIndex >= 0) {
        openImageViewer(
          context,
          allImages,
          initialIndex: imageIndex,
          onOpenExternally: onTapUrl,
        );
        return;
      }
      onTapUrl?.call(url);
    }

    // 現在ジャンプ中の一致レスは、左のアクセント帯と薄い背景でひと目で分かる
    // ようにする（左パディングを帯の分だけ詰めて本文位置は揃える）。
    final showAccent =
        isCurrentMatch || (showReplyToOwnAccent && isReplyToOwn && !isOwn);

    final content = Container(
      decoration: BoxDecoration(
        color: isCurrentMatch
            ? scheme.tertiaryContainer.withValues(alpha: 0.32)
            : isOwn
            ? scheme.secondaryContainer.withValues(alpha: 0.22)
            : isReplyToOwn
            ? scheme.primaryContainer.withValues(alpha: 0.2)
            : Colors.transparent,
        // 自分宛のレスは左のアクセント帯で行ごと際立たせ、塗り背景の「自分」と
        // 形の違いで見分けられるようにする（現在の一致レスが最優先）。
        border: isCurrentMatch
            ? Border(left: BorderSide(color: scheme.tertiary, width: 3))
            : (showReplyToOwnAccent && isReplyToOwn && !isOwn)
            ? Border(left: BorderSide(color: scheme.primary, width: 3))
            : null,
      ),
      padding: EdgeInsets.fromLTRB(showAccent ? 13 : 16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            res: res,
            name: _headerName(name),
            idCount: idCount,
            idOrdinal: idOrdinal,
            onTapId: onTapId,
            isOwn: isOwn,
            isThreadOwner: isThreadOwner,
            isReplyToOwn: isReplyToOwn,
            replyCount: replyCount,
            onTapReplies: onTapReplies,
            highlightQuery: highlightQuery,
          ),
          // 本文は貼られた URL の位置でサムネイルを挟みながら、上から順に積む。
          // メディアの区画（PostImages）は自前で上の余白を持つので、文章の
          // 区画だけ手前に間を入れる。
          for (var i = 0; i < segments.length; i++)
            switch (segments[i]) {
              PostBodyText(:final text) => Padding(
                padding: EdgeInsets.only(top: i == 0 ? 3 : 8),
                child: ResBody(
                  text: text,
                  // 本文は一覧のタイトル（14px）寄りに詰めつつ、読む主役テキスト
                  // なので 1px 大きい 15px・行高 1.4 に留めて読みやすさを確保する。
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    height: 1.4,
                  ),
                  onTapRes: (n) => onTapRes?.call(n),
                  onTapResRange: (numbers) => onTapResRange?.call(numbers),
                  onTapUrl: openUrl,
                  onTapId: onTapId,
                  selectable: bodySelectable,
                  onSelectionActiveChanged: onBodySelectionActiveChanged,
                  highlightQuery: highlightQuery,
                ),
              ),
              PostBodyLink(:final url, :final raw) => Padding(
                padding: EdgeInsets.only(top: i == 0 ? 3 : 8),
                child: LinkCard(
                  url: url,
                  raw: raw,
                  onTap: openUrl,
                  // OGP を取りに行くかは設定次第。スレカードはこの値に関わらず
                  // [LinkCard] 側で出す。
                  enabled: linkPreviews,
                  // 「グロ」注意の付いたレスでは、リンク先の絵まで不意に
                  // 出さない（見出しだけのカードになる）。
                  showImage: !blurImages,
                  linkStyle: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    height: 1.4,
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                ),
              ),
              PostBodyMedia(
                :final images,
                :final videos,
                :final audios,
                :final embeds,
              ) =>
                PostImages(
                  urls: images,
                  videoUrls: videos,
                  audioUrls: audios,
                  embedVideos: embeds,
                  viewerUrls: allImages,
                  onOpenImageExternally: onTapUrl,
                  onTapEmbed: (video) => openEmbedPlayer(
                    context,
                    video,
                    onOpenExternally: onTapUrl,
                  ),
                  blurImages: blurImages,
                ),
            },
        ],
      ),
    );

    // 返信の左スワイプ（`SwipeToReply`）はここでは掛けない。字下げ帯や会話の枠
    // ごと動かしたいので、行を組み立てる側が外から包む。
    if (onLongPress == null) return content;
    return _PressableRes(onLongPress: onLongPress!, child: content);
  }

  /// ヘッダに出す名前と、その見せ方（[text] が空ならヘッダに名前を出さない）。
  ///
  /// [defaultName] は [PostItem.defaultName]。
  ///
  /// - 名無し（名前欄が空、または板の既定名そのもの）は名前ごと省く。
  /// - ワッチョイのように既定名へ括弧書きが付くだけの名前
  ///   （`エッヂの名無し (L20 ipkW-6PVw)`）は、**括弧の中だけ残す**。毎行同じ
  ///   既定名は読む意味がないが、ワッチョイはそのレスを書いた人の情報なので
  ///   落とさない。ただしコテハンではないので [muted]＝控えめな見た目にして、
  ///   名乗っている人だけが目立つ状態を保つ。
  /// - コテハン（既定名と違う名前）はワッチョイが付いていてもそのまま出す。
  ///
  /// スレ内検索でその名前が引っかかっているときは、何も省かず元の名前を出す。
  /// 件数に数えたレスの一致箇所が画面のどこにも無い、という状態を作らないため。
  ({String text, bool muted}) _headerName(String name) {
    final query = highlightQuery.trim().toLowerCase();
    if (query.isNotEmpty && name.toLowerCase().contains(query)) {
      return (text: name, muted: false);
    }
    if (name.isEmpty) return (text: '', muted: false);
    // 既定名が分からなければ何も省かない。名無しかどうか判断できない名前を
    // 消すと、コテハンを消す事故になるため。
    if (defaultName == null) return (text: name, muted: false);
    if (name == defaultName) return (text: '', muted: false);

    final match = _nameSuffixRe.firstMatch(name);
    if (match != null) {
      final base = match.group(1)!.trim();
      if (base.isEmpty || base == defaultName) {
        return (text: match.group(2)!, muted: true);
      }
    }
    return (text: name, muted: false);
  }
}

/// 長押しがメニューに繋がるまでの時間。既定の 500ms は「押しているのに何も
/// 起きない」と感じる長さなので短くする。タップの判定（100ms）とは十分離れて
/// いるので、触れただけでメニューが出ることはない。
const _resLongPressDuration = Duration(milliseconds: 400);

/// 触れてから沈み込みを広げ始めるまでの待ち時間。スクロールを始めるときの一瞬の
/// 接触で行がチカチカしないよう、指を止めている間だけ広げる。
///
/// スクロールが確定するのは指が 18px 動いてからで、そこまでの時間は引き方次第。
/// この待ち時間だけでは防ぎきれないので、指が動いたかどうかも併せて見る（[_move]）。
const _pressSpreadDelay = Duration(milliseconds: 150);

/// 指の位置からレスの端まで広がりきるまでの時間。ゆっくり見せたいので
/// [_resLongPressDuration] より長いが、easeOutCubic の出足が速いぶん、メニューが
/// 出る頃には端まで届いて見える。
const _pressSpreadDuration = Duration(milliseconds: 450);

/// 指を離してから沈み込みが消えるまでの時間。
const _pressFadeOutDuration = Duration(milliseconds: 140);

/// 指がこれだけ動いたらスワイプとみなして沈み込みを止める距離。
///
/// 長押しの判定が外れる距離（`kTouchSlop` = 18px）を待つと、スクロールを始めた
/// 指の下で一瞬広がってしまうので、その手前で引く。指の細かい揺れでは消えない
/// 程度には残す。
const _pressMoveSlop = 8.0;

/// レスを長押しでメニューへ繋ぐラッパ。押している間は指の位置から沈み込みが
/// 広がり、離す前にどのレスを掴んでいるかが分かる（[PostItem.onLongPress] 参照）。
class _PressableRes extends StatefulWidget {
  const _PressableRes({required this.onLongPress, required this.child});

  final VoidCallback onLongPress;
  final Widget child;

  @override
  State<_PressableRes> createState() => _PressableResState();
}

class _PressableResState extends State<_PressableRes>
    with TickerProviderStateMixin {
  /// 沈み込みの半径（0＝指の位置、1＝レスの端まで）。
  late final _spread = AnimationController(
    vsync: this,
    duration: _pressSpreadDuration,
  );

  /// 沈み込みの濃さ（1＝出ている）。離したらここだけ 0 へ落として消す。半径を
  /// 縮めて戻すと、広げた動きを巻き戻すように見えてしまうため。
  late final _fade = AnimationController(
    vsync: this,
    duration: _pressFadeOutDuration,
  );

  Timer? _timer;
  Offset? _origin;

  /// 指を置いた位置。ここから [_pressMoveSlop] 離れたらスワイプとみなす。
  Offset? _downAt;

  @override
  void dispose() {
    _timer?.cancel();
    _spread.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _press(Offset position) {
    _timer?.cancel();
    _downAt = position;
    _timer = Timer(_pressSpreadDelay, () {
      setState(() => _origin = position);
      _fade.value = 1;
      _spread.forward(from: 0);
    });
  }

  /// 指が動いたら、スワイプかどうかを見て沈み込みを引っ込める。
  ///
  /// スクロールが始まった（＝長押しが外れた）と分かるのは指が 18px 動いてからで、
  /// それを待つとスワイプのたびに一瞬広がってしまうので、こちらで先に見る。
  ///
  /// ここではフェードを挟まず即座に消す。流れていく画面の上に余韻が残ると、
  /// 消える動きのほうが目に付いてしまうため。
  void _move(Offset position) {
    final downAt = _downAt;
    if (downAt == null) return;
    if ((position - downAt).distance <= _pressMoveSlop) return;
    _timer?.cancel();
    _downAt = null;
    _fade.value = 0;
  }

  /// 指を離した・スクロールに取られた、どちらでも沈み込みを消す。
  void _release() {
    _timer?.cancel();
    _downAt = null;
    if (_origin != null) _fade.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 指の動きは長押しの判定を待たずに自分で見る（[_move] 参照）。スクロールに
    // 取られた後もこのレスへ届くので、途中で引っ込める判断ができる。
    return Listener(
      onPointerMove: (event) => _move(event.localPosition),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          // 長押しの長さを変えたいので GestureDetector ではなく直接組み立てる。
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: _resLongPressDuration,
                  debugOwner: this,
                ),
                (recognizer) {
                  recognizer.onLongPressDown = (details) =>
                      _press(details.localPosition);
                  recognizer.onLongPressCancel = _release;
                  recognizer.onLongPressUp = _release;
                  recognizer.onLongPress = () {
                    // 長押しが通った合図。指を離す前にメニューが出ると分かる。
                    HapticFeedback.mediumImpact();
                    widget.onLongPress();
                  };
                },
              ),
        },
        child: CustomPaint(
          painter: _PressSpread(
            origin: _origin,
            spread: _spread,
            fade: _fade,
            // レス自身の背景（自分・自分宛・検索一致）はどれも半透明なので、
            // 後ろに敷いた沈み込みが透けて出る。本文へ被せないぶん文字が濁らない。
            color: scheme.onSurface.withValues(alpha: 0.09),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 押した指の位置から広がる沈み込み。本文の後ろに描くので文字は濁らない。
class _PressSpread extends CustomPainter {
  _PressSpread({
    required this.origin,
    required this.spread,
    required this.fade,
    required this.color,
  }) : super(repaint: Listenable.merge([spread, fade]));

  /// 指を置いた位置（レス内のローカル座標）。まだ押されていなければ null。
  final Offset? origin;
  final Animation<double> spread;
  final Animation<double> fade;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = this.origin;
    if (origin == null || fade.value == 0) return;
    // 指から一番遠い角まで届く大きさを終点にして、レス全体が沈むようにする。
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    final radius =
        math.sqrt(dx * dx + dy * dy) *
        Curves.easeOutCubic.transform(spread.value);
    if (radius <= 0) return;
    // 広がった円が上下のレスに掛からないよう、このレスの矩形で切り取る
    // （ClipRect を挟むとレスごとにレイヤーが増えるので、描くときだけ切る）。
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawCircle(
      origin,
      radius,
      Paint()..color = color.withValues(alpha: color.a * fade.value),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PressSpread old) =>
      old.origin != origin ||
      old.color != color ||
      old.spread != spread ||
      old.fade != fade;
}

/// 名前の末尾に付く括弧書き（ワッチョイ・端末種別など）を切り出す。
///
/// `エッヂの名無し (L20 ipkW-6PVw)` を `エッヂの名無し` と `(L20 ipkW-6PVw)` に
/// 分ける。dat の名前欄は `ポッドの名無し </b>(L20 NKP8-6NV7)<b>` のように
/// タグ込みで来るが、[htmlToText] を通した後の文字列を相手にする。
///
/// 括弧の中に括弧は入らない前提（`[^()（）]*`）。全角括弧の板もあるので両方見る。
final _nameSuffixRe = RegExp(r'^(.*?)[\s　]*([(（][^()（）]*[)）])$');

/// 返信件数を押せるときの当たり判定の高さ。文字の高さ（16px）のままだと指には
/// 狭いので広げる。
///
/// ヘッダの他の要素（ID アイコン 20px・名前と時刻 20px）より数 px 高いので、返信の
/// 付いたレスだけヘッダがわずかに伸びる。返信の付いたレスは元から目立たせている
/// （件数が左へ張り出す）ので、そこだけ息継ぎが入るのは筋が通る。
const double _replyCountTapHeight = 26;

/// 受けた返信の件数。**0 件のレスには出さない。**
///
/// 掲示板では返信数がそのレスの重要度の指標になるので、ヘッダの先頭に置いて
/// 流し読みでも目に入るようにする。0 件で何も出さないぶん、反応が集まったレス
/// だけが左に張り出して見える。段階の基準はスレマップの目印と共有する
/// （[replyTierOf]）ので、マップで見つけた場所とレス本体の見た目が対応する。
///
/// 色は 1 段階だけ上げ、その上の段階は太さで示す。テキストなので淡い色にすると
/// 読めなくなるため（マップのバーは面なので濃さ 2 段階で出せる）。
class _ReplyCount extends StatelessWidget {
  const _ReplyCount({
    required this.number,
    required this.replyCount,
    required this.onTap,
  });

  final int number;
  final int replyCount;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tier = replyTierOf(replyCount);
    final color = tier == ReplyTier.none ? scheme.primary : scheme.error;
    final weight = tier == ReplyTier.veryMany
        ? FontWeight.w800
        : FontWeight.w700;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: weight,
      leadingDistribution: TextLeadingDistribution.even,
    );

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 受けた返信の数は吹き出し。返信する操作は左スワイプ中に出る矢印
        // （`SwipeToReply`）で、「付いたもの」と「これからする操作」を形で
        // 分ける。
        Icon(Icons.chat_bubble_outline, size: 13, color: color),
        const SizedBox(width: 2),
        Text('$replyCount', style: style),
      ],
    );

    if (onTap == null) return label;
    // ここから返信一覧（会話ビュー）へ入れる。余白は右にだけ足す。ヘッダの
    // 先頭に来るので、左を広げると件数が本文の左端からずれる。
    return InkWell(
      onTap: () => onTap!(number),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: _replyCountTapHeight,
        child: Padding(
          padding: const EdgeInsets.only(right: 2),
          // widthFactor: 1 で横幅は中身なりに縮める（Wrap 内で全幅化させない）。
          child: Center(widthFactor: 1, child: label),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.res,
    required this.name,
    required this.idCount,
    required this.idOrdinal,
    required this.onTapId,
    required this.isOwn,
    required this.isThreadOwner,
    required this.isReplyToOwn,
    this.replyCount = 0,
    this.onTapReplies,
    this.highlightQuery = '',
  });

  final Res res;

  /// ヘッダに出す名前と見せ方（[PostItem._headerName] の結果）。
  final ({String text, bool muted}) name;
  final int idCount;
  final int idOrdinal;
  final ValueChanged<String>? onTapId;
  final int replyCount;
  final ValueChanged<int>? onTapReplies;
  final bool isOwn;
  final bool isThreadOwner;
  final bool isReplyToOwn;
  final String highlightQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineHeight = _headerLineHeight(theme);
    // 返信件数が押せるときだけ、件数のスロットを当たり判定の高さまで広げる。
    // 押せないレスは今までどおり 1 行分のままにして、一覧の詰まりを保つ。
    final replyCountSlotHeight =
        onTapReplies != null && lineHeight < _replyCountTapHeight
        ? _replyCountTapHeight
        : lineHeight;

    return Row(
      // 左グループが 2 行になっても、日時・返信ボタンは 1 行目の高さに揃える。
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左グループ（番号・名前・ID・自分）を Expanded で残り幅ごと占有させ、
        // 日時・返信ボタンを画面幅に関わらず常に右端へ固定する。深いツリーで幅が
        // 足りないときは、要素を省略せず Wrap で 2 行目へ折り返す。
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // ヘッダは「どれだけ反応され・誰が・何者で・いつ」の順に読ませる。
                //
                // **レス番号は出さない。** 番号は `>>N` から辿るための参照値で、
                // 読むときには要らない。レスを指定する操作は左スワイプ（返信・
                // `SwipeToReply`）と長押しメニューが受け持つ。
                if (replyCount > 0)
                  _HeaderSlot(
                    height: replyCountSlotHeight,
                    child: _ReplyCount(
                      number: res.number,
                      replyCount: replyCount,
                      onTap: onTapReplies,
                    ),
                  ),
                // チップは固定高さのスロットに入れない。狭いときは中身に応じて
                // 縦に伸び、それでも入らなければ省略する。スロットで 1 行に
                // 固定すると、折り返したときにチップが潰れる。
                if (res.id != null)
                  _IdChip(
                    id: res.id!,
                    count: idCount,
                    ordinal: idOrdinal,
                    onTap: onTapId,
                  )
                else
                  // ID なしの板。アイコンごと省くと、名無し・返信なしのレスは
                  // ヘッダが時刻だけになってレスの切れ目が読めなくなる。
                  const _NoIdChip(),
                // スレ主の印は ID アイコンのすぐ隣。「誰が」に掛かる情報なので
                // 人物（アイコン）から離さない。長いコテハンの後ろに置くと、
                // 折り返したときにアイコンと別の行へ飛んでしまう。★ はスレ主
                // NG の `[xxxx★]` と同じ、このアプリでのスレ主の記号。
                if (isThreadOwner)
                  _OwnChip(
                    color: scheme.tertiary,
                    label: 'スレ主',
                    icon: Icons.star_rounded,
                  ),
                // Wrap の子は Flexible にできないので、極端に長い名前だけは
                // 行幅で頭打ちにして省略する（通常の名前はそのまま 1 チャンク）。
                // 名無しは空文字で渡ってくるので、枠ごと出さない。
                if (name.text.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: _HeaderSlot(
                      height: lineHeight,
                      child: _NameLabel(
                        name: name.text,
                        muted: name.muted,
                        highlightQuery: highlightQuery,
                      ),
                    ),
                  ),
                if (isOwn)
                  _OwnChip(color: scheme.secondary)
                else if (isReplyToOwn)
                  _OwnChip(
                    color: scheme.primary,
                    onColor: scheme.onPrimary,
                    label: '自分宛',
                    icon: Icons.reply,
                    filled: true,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _HeaderSlot(
          height: lineHeight,
          child: _TimeLabel(res: res),
        ),
      ],
    );
  }

  double _headerLineHeight(ThemeData theme) {
    final style = theme.textTheme.labelLarge;
    final fontSize = style?.fontSize ?? 14;
    return fontSize * (style?.height ?? 20 / fontSize);
  }
}

class _HeaderSlot extends StatelessWidget {
  const _HeaderSlot({required this.height, required this.child});
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // widthFactor: 1.0 で横幅は中身に合わせて縮める。これがないと Wrap の中で
    // Align が横いっぱいに広がり、チップが全幅になって 1 個ずつ縦積みになる。
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: 1,
        child: child,
      ),
    );
  }
}

class _NameLabel extends StatelessWidget {
  const _NameLabel({
    required this.name,
    this.muted = false,
    this.highlightQuery = '',
  });
  final String name;

  /// 名乗っていない人の付随情報（ワッチョイ等）か。時刻と同じ「添え物」の見た目に
  /// 落として、コテハンだけが名前として目立つようにする。
  final bool muted;
  final String highlightQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = muted
        ? theme.textTheme.labelMedium
        : theme.textTheme.labelLarge;
    final style = base?.copyWith(
      color: muted
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
      fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final queryLower = highlightQuery.trim().toLowerCase();
    final Widget label;
    if (queryLower.isEmpty) {
      label = Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    } else {
      final spans = <InlineSpan>[];
      appendHighlighted(
        spans,
        name,
        queryLower,
        searchHighlightStyle(theme.colorScheme),
      );
      label = Text.rich(
        TextSpan(style: style, children: spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (name.isEmpty) return label;
    return Tooltip(
      message: name,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      child: label,
    );
  }
}

class _OwnChip extends StatelessWidget {
  const _OwnChip({
    required this.color,
    this.onColor,
    this.label = '自分',
    this.icon,
    this.filled = false,
  });

  /// 枠線・文字色（[filled] のときは塗り色）。
  final Color color;

  /// [filled] のときの文字・アイコン色（塗り色の上に載る色）。
  final Color? onColor;
  final String label;

  /// ラベル左に添えるアイコン（自分宛の返信矢印など）。
  final IconData? icon;

  /// 塗りつぶしにするか。false なら枠線のみ。「自分」との形の違いを付ける。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? (onColor ?? color) : color;
    // 高さ・幅とも中身に合わせて縮める。height + alignment を使うと Wrap 内で
    // 横いっぱいに広がってしまうため、上下パディングでピル高さを作る。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: filled ? color : null,
        border: filled
            ? null
            : Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              height: 1,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// レス時刻。既定は HH:MM のみ。タップでコンマ以下・日付まで含む完全な
/// 日時をスナックバーに出す。
///
/// 秒を落とすのは、ヘッダの右端で幅を 1 文字分でも空けるため（左の名前・ID の
/// 幅がその分増え、ID の位置が揃いやすくなる）。秒が要る場面（連投の間隔を見る
/// など）はタップで完全な日時が出るので、情報自体は失われない。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.res});
  final Res res;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final full = res.dateText.trim();
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(_short(res), style: style),
    );
    if (full.isEmpty) return label;
    // タップ／ホバーでコンマ以下・日付まで含む完全な日時をその場に出す。画面下の
    // スナックバーだと入力欄に重なるため、近くに浮かぶツールチップにする。
    return Tooltip(
      message: full,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      child: label,
    );
  }

  /// 日付テキストから時刻の時分（HH:MM）を取り出す。無ければ全体。
  static String _short(Res res) {
    final m = RegExp(r'(\d{2}:\d{2})(?::\d{2})?').firstMatch(res.dateText);
    return m?.group(1) ?? res.dateText;
  }
}

/// ID なしの板でのアイコン枠。[_IdChip] と同じ大きさ・同じ位置を占め、
/// ヘッダの左端とレスの切れ目だけを保つ。
///
/// 押せない（絞り込む ID が無い）し、輪も色を持たない（連投を数えられない）。
class _NoIdChip extends StatelessWidget {
  const _NoIdChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'IDなし',
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Container(
          padding: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.8),
              width: 1.2,
            ),
          ),
          child: const IdIconPlaceholder(),
        ),
      ),
    );
  }
}

class _IdChip extends StatelessWidget {
  const _IdChip({
    required this.id,
    required this.count,
    required this.ordinal,
    required this.onTap,
  });
  final String id;
  final int count;
  final int ordinal;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final color = idColorForCount(Theme.of(context).colorScheme, count);
    return Semantics(
      // 絵には読み上げるものが無いので、元のチップの文言をここに持たせる。
      // ウィジェットテストもこのラベルでアイコンを掴む。
      label: count > 1 ? 'ID:$id ($ordinal/$count)' : 'ID:$id',
      button: onTap != null,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(id),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          // 高さ・幅とも中身に合わせて縮める（Wrap 内で全幅化させない）。
          // 余白は右にだけ足す。ヘッダの先頭に来るので、左を広げるとアイコンが
          // 本文の左端からずれる。
          padding: const EdgeInsets.only(right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  // 外周のリングだけレス数で色を変える。中の絵は ID ごとの
                  // 色なので、そこに連投の多さを混ぜると両方読めなくなる。
                  border: Border.all(
                    color: color.withValues(alpha: 0.75),
                    width: 1.2,
                  ),
                ),
                child: IdIcon(id: id),
              ),
              if (count > 1) ...[
                const SizedBox(width: 4),
                // 上のラベルが「ID:xxx (1/2)」まで読み上げるので、同じことを
                // 言うこの数字は読み上げから外す。見た目の要約でしかない。
                ExcludeSemantics(
                  child: Text(
                    '$ordinal/$count',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      leadingDistribution: TextLeadingDistribution.even,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
