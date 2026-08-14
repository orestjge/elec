import 'dart:async';
import 'dart:math' as math;

import 'package:edge_core/edge_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/thread_command.dart';
import '../net/thread_view_settings.dart';
import '../net/thread_link.dart';
import 'mini_player.dart';
import 'device_gestures.dart';
import 'format.dart';
import 'id_color.dart';
import 'now_ticker.dart';
import 'id_icon.dart';
import 'link_card.dart';
import 'long_press.dart';
import 'collapsible.dart';
import 'post_body_segments.dart';
import 'post_images.dart';
import 'reply_tier.dart';
import 'thread_tree.dart';
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
    this.onTapWacchoi,
    this.resLayout = ResLayout.gutter,
    this.nested = false,
    this.attachedToQuote = false,
    this.quotedRes,
    this.inlineQuotes = const {},
    this.onTapRes,
    this.onTapResRange,
    this.onTapUrl,
    this.replyCount = 0,
    this.onTapReplies,
    this.onLongPress,
    this.bodySelectable = false,
    this.isOwn = false,
    this.isThreadOwner = false,
    this.isReplyToOwn = false,
    this.showAccentBar = true,
    this.blurImages = false,
    this.linkPreviews = false,
    this.highlightQuery = '',
    this.isCurrentMatch = false,
    this.defaultName,
    this.collapseLongBody = false,
    this.bodyExpanded = false,
    this.onExpandBody,
  });

  final Res res;

  /// このスレでの同一 ID の総数（1 なら単発）。
  final int idCount;

  /// このレスが同一 ID 内で何番目か（1 始まり）。
  final int idOrdinal;

  /// ID タップ時。同一 ID のレス一覧を出す。左の柱の identicon と、本文に
  /// 貼られた `ID:xxx`（他のレスの引用）の両方から呼ぶ。
  final ValueChanged<String>? onTapId;

  /// 名前欄のワッチョイ（`(L20 ipkW-6PVw)` の `ipkW-6PVw`）タップ時。同じ
  /// ワッチョイのレス一覧を出す。ワッチョイの無い板・名前では押せない。
  final ValueChanged<String>? onTapWacchoi;

  /// レス 1 件の組み方（[ThreadViewSettings.resLayout]）。
  ///
  /// [ResLayout.gutter] は identicon をレスの左に立て、時刻を足元に置く。
  /// [ResLayout.header] は identicon を小さくしてヘッダの行に並べ、時刻もそこへ
  /// 収める。読む人が設定で選ぶ——どちらが良いかはスレの性格で変わるため。
  final ResLayout resLayout;

  /// すぐ上に、このレスの返信先の引用行（`QuotedResRow`）が並んでいるか。
  ///
  /// その引用行は**このレスのもの**（このレスが指している相手の再掲）なので、
  /// 上の余白を詰めてひと塊に見せる。空けたままだと、引用行が上下のレスの
  /// どちらに付いているのか読めない。
  ///
  /// 詰め方は組み方で変える。クラシックは 0 まで——見出しが字だけで行も詰まって
  /// いるので、少しでも空くと切れて見える。他の組み方は見出しに絵が立っていて、
  /// 0 にすると絵の上端が引用行の字に触れるので、わずかに残す。
  final bool attachedToQuote;

  /// レス番号から、そのレスを引くもの。
  ///
  /// **本文の中で行を丸ごと使って指している `>>N`**（`>>5` だけの行）を、その
  /// 位置で返信先の再掲に差し替えるために要る（`PostBodyQuote`）。渡さない場所
  /// では差し替えず、`>>N` の文字のまま出る——会話シートや同一 ID の一覧のように
  /// スレ全体を持っていない場所では、指し先を引けないため。
  final Res? Function(int number)? quotedRes;

  /// 本文の中へ返信先の再掲を差し込むレス番号（`ThreadTreeRow.inlineQuotes`）。
  ///
  /// 行を丸ごと使って指している `>>N` のうち、**並びがまだ示していない相手**
  /// だけが入る。ツリーの親（字下げが示す）や、手前に引用行として出る相手は
  /// 入らない——同じことを 2 か所で言うと、ツリーでは返信のたびに親の再掲が
  /// 挟まって画面が引用だらけになる。
  final Set<int> inlineQuotes;

  /// 返信としてぶら下がっている（字下げされた）行か。
  ///
  /// 字下げのぶん幅が狭いので、画面端から本文までの余白を詰める
  /// （[nestedResLeftPadding]）。identicon の大きさは変えない（[_idGutterSize]）。
  final bool nested;

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

  /// レスを長押ししたとき。レス全体のコピーや ID 操作のメニューを出す。
  ///
  /// タップでは開かない。本文の `>>N` や URL を狙って触れただけ、スクロールを
  /// 止めるために触れただけでメニューが出ると邪魔になるため。押している間は指の
  /// 位置から沈み込みが広がって、離す前に「今どのレスを掴んでいるか」が分かる。
  final VoidCallback? onLongPress;

  /// 本文を範囲選択できるようにするか。**既定は false。**
  ///
  /// レスを並べる場所（一覧・会話シート・同一 ID 一覧）では、レスは横スワイプで
  /// 返信、縦スクロールで移動と、指の操作をすでに使い切っている。本文が選択でき
  /// ると、なぞった指が選択範囲の伸縮に持っていかれて返信スワイプが出ない。
  /// 選択したいときはレスを長押ししてメニューを開けば、その中のレスで選べる。
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

  /// 左のアクセント帯（自分宛・検索の現在位置）をこのレス内で描くか。
  ///
  /// **外側に自前の帯を持つ入れ物では false にする。** 会話シートの枠は、その
  /// 帯自体に色を移して 1 本にまとめる——2 本並べると数 px ずれた縦線が 2 本
  /// 走ることになる。一覧では字下げした行（[ThreadTreeTier]）でもレス側が
  /// 描く。字下げは余白だけで表していて、色を移せる帯が無いため。
  final bool showAccentBar;

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

  /// 長いレスを途中で畳み、「続きを読む」で伸ばせるようにするか。
  ///
  /// **スレ一覧でだけ真にする。** 会話シートや同一 ID の一覧は、そのレスを
  /// 見たくて開いた場所なので、そこで畳むと開き直す手間が増えるだけになる。
  final bool collapseLongBody;

  /// 既に「続きを読む」が押されているか（[collapseLongBody] のときだけ効く）。
  ///
  /// **一覧の行は画面外へ出ると捨てられる**ので、開いたかどうかは画面側が
  /// 覚える。ここで持つと、スクロールで離れて戻るたびに畳み直される。
  final bool bodyExpanded;

  /// 「続きを読む」を押したとき。画面側が [bodyExpanded] を立て直す。
  final VoidCallback? onExpandBody;

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
    // スレ立てのコマンド（`!metadent:vv - configured` 等）は板への指示であって
    // 読む文ではない。本文からは外し、意味だけ札にして下に出す。
    final rawBody = htmlToText(res.body);
    final command = parseThreadCommand(rawBody);
    // AA はインデントや上下の余白が絵の一部になるのでそのまま残し、普通のレスは
    // 前後の空白・空行を落として詰める。
    // 本文の `>>N` はどれも消さない。行を丸ごと使って書かれたものは返信先の
    // 再掲に差し替わり（[PostBodyQuote]）、文と同じ行にあるものは文の部品
    // （`今日は>>5を>>6個食べる！`）なので、そのまま残す。
    final body = trimUnlessAsciiArt(
      command == null ? rawBody : stripThreadCommand(rawBody, command),
    );
    // スレ URL は OGP の設定に関わらずカードにする（中身は掲示板サーバから
    // 取るので、リンク先へ通信が広がらない。詳しくは [ThreadLinks]）。
    final segments = splitPostBody(
      body,
      linkPreviews: linkPreviews,
      isThreadLink: (url) => ThreadLinks.targetOf(url) != null,
      // 指し先を引ける場所で、かつ並びがまだ示していない相手だけ、行を単独で
      // 占める `>>N` を再掲に差し替える。
      inlineQuotes: quotedRes == null ? const {} : inlineQuotes,
    );
    // 全画面ビューアはレス内の全画像・全動画をひと続きに送れるようにする。
    // 本文の途中で区画に分かれても、どのサムネイルから開いても並びは同じ。
    final allMedia = viewerMediaIn(body);

    void openUrl(Uri url) {
      if (allMedia.any((item) => item.url == url)) {
        openViewerAt(
          context,
          allMedia,
          url,
          // 動画はシステムブラウザへ回す。[onTapUrl] は動画 URL を見ると
          // アプリ内プレーヤーへ送り返すので、ビューアへ戻ってしまう。
          onOpenExternally: viewerBrowserHandoff(onTapUrl, null),
        );
        return;
      }
      onTapUrl?.call(url);
    }

    final gutter = resLayout == ResLayout.gutter;
    final classic = resLayout == ResLayout.classic;

    // 「何者か」の 3 つ。柱の組み方では絵に重ねた印（[_IdBadge]）に、ヘッダに
    // まとめる組み方では文字の札（[_OwnChip]）になる。
    final marks = (
      owner: isThreadOwner,
      own: isOwn,
      replyToOwn: isReplyToOwn && !isOwn,
    );

    // ヘッダの行に出すものがあるか。名無し・返信なしのレス——実際の板でいちばん
    // 多い形——では**何も無い**ので、行ごと省く。柱の組み方では時刻をヘッダに
    // 置いていないので、省いても行き場を失うものはない。ヘッダにまとめる組み方
    // では ID の絵と時刻がそこにあるので、常に出す。
    //
    // スレ主・自分・自分宛はここに数えない。柱の組み方ではこの 3 つを絵に重ねた
    // 印で出す（[_IdBadge]）ので、ヘッダに出すものは増えない。
    final headerName = _headerName(name);
    final hasHeaderLine =
        !gutter || headerName.text.isNotEmpty || replyCount > 0;

    // 本文の最後が箱——リンクのカード・画像・スレ立てコマンドの札——で終わる
    // レスは、その下の縁と足元の時刻が直に接する。文章で終わるなら行の下に
    // 余白があるので気にならないが、箱は縁がそのまま当たって窮屈に見える。
    // 箱で終わるときだけ間を入れる。**箱の側に下マージンを持たせない**のは、
    // 箱の後ろに本文が続くとき（段落間の 8 がすでに入る）に二重になるため。
    final endsWithBox = segments.isEmpty
        ? command != null
        : segments.last is! PostBodyText;

    /// 本文に差し込む返信先の再掲。そのレスが手元に無ければ（会話シートなど、
    /// 引ける一覧を持たない場所）、書かれていた `>>N` の文字のまま出す。
    Widget buildQuote({
      required int number,
      required String raw,
      required bool first,
      required bool joinsPrevious,
    }) {
      final target = quotedRes?.call(number);
      if (target == null) {
        return Padding(
          padding: EdgeInsets.only(top: first ? 3 : 8),
          child: ResBody(
            text: raw,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: _bodyFontSize,
              height: _bodyLineHeight,
            ),
            onTapRes: (n) => onTapRes?.call(n),
            onTapResRange: (numbers) => onTapResRange?.call(numbers),
            onTapUrl: openUrl,
            onTapId: onTapId,
            selectable: bodySelectable,
            highlightQuery: highlightQuery,
          ),
        );
      }
      return QuotedResRow(
        res: target,
        inline: true,
        resLayout: resLayout,
        joinsPrevious: joinsPrevious,
        blurImages: blurImages,
        onTap: () => onTapRes?.call(number),
      );
    }

    final bodyChildren = <Widget>[
      if (command != null) _ThreadCommandChip(command: command),
      // 本文は貼られた URL の位置でサムネイルを挟みながら、上から順に
      // 積む。メディアの区画（PostImages）は自前で上の余白を持つので、
      // 文章の区画だけ手前に間を入れる。
      for (var i = 0; i < segments.length; i++)
        switch (segments[i]) {
          PostBodyText(:final text) => Padding(
            padding: EdgeInsets.only(top: i == 0 ? 3 : 8),
            child: ResBody(
              text: text,
              // 本文は一覧のタイトル（14px）寄りに詰めつつ、読む主役
              // テキストなので 1px 大きい 15px・行高 1.4 に留めて
              // 読みやすさを確保する。
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: _bodyFontSize,
                height: _bodyLineHeight,
              ),
              onTapRes: (n) => onTapRes?.call(n),
              onTapResRange: (numbers) => onTapResRange?.call(numbers),
              onTapUrl: openUrl,
              onTapId: onTapId,
              selectable: bodySelectable,
              highlightQuery: highlightQuery,
            ),
          ),
          // 行を単独で占める `>>N`。書かれた位置に返信先を差し込む。
          PostBodyQuote(:final number, :final raw) => buildQuote(
            number: number,
            raw: raw,
            first: i == 0,
            joinsPrevious: i > 0 && segments[i - 1] is PostBodyQuote,
          ),
          PostBodyLink(:final url, :final raw) => Padding(
            padding: EdgeInsets.only(top: i == 0 ? 3 : 8),
            child: LinkCard(
              url: url,
              raw: raw,
              onTap: openUrl,
              // OGP を取りに行くかは設定次第。スレカードはこの値に
              // 関わらず [LinkCard] 側で出す。
              enabled: linkPreviews,
              // 「グロ」注意の付いたレスでは、リンク先の絵まで不意に
              // 出さない（見出しだけのカードになる）。
              showImage: !blurImages,
              linkStyle: theme.textTheme.bodyLarge?.copyWith(
                fontSize: _bodyFontSize,
                height: _bodyLineHeight,
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
              viewerMedia: allMedia,
              onOpenImageExternally: onTapUrl,
              onTapEmbed: (video) =>
                  openEmbedPlayer(context, video, onOpenExternally: onTapUrl),
              blurImages: blurImages,
            ),
        },
    ];

    // AA は途中で切ると絵として成立しない（顔の下半分が消えたものを見せられて
    // も、開くかどうかの判断すらできない）。長くても畳まない。
    final hasAsciiArt = segments.any(
      (segment) => segment is PostBodyText && looksLikeAsciiArt(segment.text),
    );
    // 現在ジャンプ中の一致レスは、左のアクセント帯と薄い背景でひと目で分かる
    // ようにする（左パディングを帯の分だけ詰めて本文位置は揃える）。
    final showAccent =
        showAccentBar && (isCurrentMatch || (isReplyToOwn && !isOwn));

    final stack = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasHeaderLine)
          _Header(
            res: res,
            name: headerName,
            fullName: name.isNotEmpty ? name : (defaultName ?? '名無し'),
            wacchoi: wacchoiOf(name),
            resLayout: resLayout,
            idCount: idCount,
            idOrdinal: idOrdinal,
            onTapId: onTapId,
            onTapWacchoi: onTapWacchoi,
            isOwn: isOwn,
            isThreadOwner: isThreadOwner,
            isReplyToOwn: isReplyToOwn,
            replyCount: replyCount,
            onTapReplies: onTapReplies,
            highlightQuery: highlightQuery,
          ),
        if (!collapseLongBody || hasAsciiArt)
          ...bodyChildren
        else
          CollapsingBody(
            expanded: bodyExpanded,
            onExpand: () => onExpandBody?.call(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: bodyChildren,
            ),
          ),
        // 時刻はレスの足元、右端。**ヘッダではなくここに置く**のは、ヘッダに
        // 他に出すものが無いレスでも位置が動かないようにするため。ヘッダ側に
        // 置くと、名前もスレ主印も無いレスでは時刻だけの空の行ができるか、
        // 本文の横へ逃がすかのどちらかになり、レスごとに時刻の居場所が変わって
        // しまう。ヘッダにまとめる組み方（[ResLayout.header]）では、そもそも
        // ヘッダを必ず出すのでこの問題が起きず、時刻もそちらに乗っている。
        //
        // 1 行のレスではこの行はほぼタダで付く。左の柱（絵と連投数）がすでに
        // 本文 1 行より高く、行の高さを決めているため。
        if (gutter)
          Padding(
            padding: EdgeInsets.only(top: endsWithBox ? 6 : 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: _TimeLabel(res: res),
            ),
          ),
      ],
    );

    // 柱の組み方だけ、左に「誰が」の列を立てて本文をその右へ寄せる。
    final column = !gutter
        ? stack
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ヘッダの行と本文の 1 行目にまたがるので、絵を大きくしてもレスの
              // 高さは増えない。
              if (res.id != null)
                _IdGutter(
                  id: res.id!,
                  count: idCount,
                  ordinal: idOrdinal,
                  size: _idGutterSize,
                  marks: marks,
                  onTap: onTapId,
                )
              else
                _NoIdGutter(size: _idGutterSize, marks: marks),
              const SizedBox(width: _idGutterGap),
              Expanded(child: stack),
            ],
          );

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
        border: !showAccent
            ? null
            : isCurrentMatch
            ? Border(left: BorderSide(color: scheme.tertiary, width: 3))
            : Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      // ぶら下がった返信の左は詰める。字下げ（[ThreadTreeTier]）がその行の
      // 左端をすでに右へ送っているので、画面端からの余白として決めた 16 を
      // そのまま使うと、深さ 0 の行（画面端から 16）より字下げした行のほうが
      // 余白が広い逆転になる。
      //
      // アクセント帯を自分で描くときは、その太さ（3）ぶん詰めて中身の位置を
      // 保つ。
      //
      // 上下は、クラシックの組み方だけ詰める（[_classicResVerticalPadding]）。
      padding: EdgeInsets.fromLTRB(
        (nested ? nestedResLeftPadding : resLeftPadding) - (showAccent ? 3 : 0),
        attachedToQuote
            ? (classic ? 0 : _quotedResTopPadding)
            : (classic ? _classicResVerticalPadding : _resVerticalPadding),
        resLeftPadding,
        classic ? _classicResVerticalPadding : _resVerticalPadding,
      ),
      child: column,
    );

    // 返信の左スワイプ（`SwipeToReply`）はここでは掛けない。字下げや会話の枠
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

/// スレ立てのコマンドを、読める言葉に置き換えて出す小さな札。
///
/// `!metadent:vv - configured` のような綴りは板への指示なので、そのまま出しても
/// 読む人には意味が取れない。かといって黙って消すと、**そのスレの名前欄に何が
/// 出るのか**という 1 レス目にしか無い情報まで消える。言葉に置き換えて残す。
///
/// 板の設定で強制されたもの（`forced`）はスレ立て人が選んだものではないので、
/// そう分かるように書き添える。
class _ThreadCommandChip extends StatelessWidget {
  const _ThreadCommandChip({required this.command});

  final ThreadCommand command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.badge_outlined,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                command.isForced ? '${command.label}（板の設定）' : command.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 指の位置からレスの端まで広がりきるまでの時間。ゆっくり見せたいので
/// [menuLongPressDuration] より長いが、easeOutCubic の出足が速いぶん、メニューが
/// 出る頃には端まで届いて見える。
const _pressSpreadDuration = Duration(milliseconds: 450);

/// 指を離してから沈み込みが消えるまでの時間。
const _pressFadeOutDuration = Duration(milliseconds: 140);

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

  /// 指を置いた位置。ここから [pressMoveSlop] 離れたらスワイプとみなす。
  Offset? _downAt;

  /// この押しを内側（レスの中のサムネイル）が引き受けたか。
  bool _claimed = false;

  @override
  void dispose() {
    _timer?.cancel();
    _spread.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// 内側が引き受けた・手放した（[LongPressClaimed]）。
  ///
  /// 引き受けられている間はレスを広げない。開くのはサムネイルのメニューなので、
  /// レス全体が沈み込むと的が違って見える。合図は押し始めに来るので、たいていは
  /// 広げる前に降りられる（間に合わなかったときのために、出ていれば消す）。
  void _claim(bool pressed) {
    _claimed = pressed;
    if (!pressed) return;
    _timer?.cancel();
    _downAt = null;
    _fade.value = 0;
  }

  void _press(Offset position) {
    if (_claimed) return;
    _timer?.cancel();
    _downAt = position;
    _timer = Timer(pressFeedbackDelay, () {
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
    if ((position - downAt).distance <= pressMoveSlop) return;
    _timer?.cancel();
    _downAt = null;
    _fade.value = 0;
  }

  /// 指を離した・スクロールに取られた、どちらでも沈み込みを消す。
  void _release() {
    _timer?.cancel();
    _downAt = null;
    _claimed = false;
    if (_origin != null) _fade.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gestures = deviceGesturesOf(context);
    // 指の動きは長押しの判定を待たずに自分で見る（[_move] 参照）。スクロールに
    // 取られた後もこのレスへ届くので、途中で引っ込める判断ができる。
    return NotificationListener<LongPressClaimed>(
      // レスの中のレスは無いので、ここで受け止めて上へは流さない。
      onNotification: (notification) {
        _claim(notification.pressed);
        return true;
      },
      child: Listener(
        onPointerMove: (event) => _move(event.localPosition),
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            // 長押しの長さを変えたいので GestureDetector ではなく直接組み立てる。
            // 指が動いて長押しが外れる距離も端末に合わせる
            // （`device_gestures.dart`）。
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: menuLongPressDuration,
                    debugOwner: this,
                  ),
                  (recognizer) {
                    recognizer.gestureSettings = gestures;
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
/// ヘッダの他の要素（ID アイコン 22px・名前と時刻 20px）より数 px 高いので、返信の
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
    required this.fullName,
    required this.wacchoi,
    required this.resLayout,
    required this.idCount,
    required this.idOrdinal,
    required this.onTapId,
    required this.onTapWacchoi,
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

  /// 省略しない名前。名前欄が空なら板の既定名（それも無ければ「名無し」）。
  /// クラシックの組み方だけがこちらを使う——dat の見出しには必ず名前があり、
  /// 毎行同じ名前が並ぶ形そのものが「クラシック」だから。
  final String fullName;

  /// 名前から切り出したワッチョイ（[wacchoiOf]）。無ければ null。
  final String? wacchoi;

  /// レスの組み方（[PostItem.resLayout]）。[ResLayout.header] のときだけ、この
  /// 行が ID の絵と時刻も抱える。柱の組み方ではどちらも行の外にある。
  /// [ResLayout.classic] では並びそのものが変わる（[_classicChildren]）。
  final ResLayout resLayout;
  final int idCount;
  final int idOrdinal;
  final ValueChanged<String>? onTapId;
  final ValueChanged<String>? onTapWacchoi;
  final int replyCount;
  final ValueChanged<int>? onTapReplies;
  final bool isOwn;
  final bool isThreadOwner;
  final bool isReplyToOwn;
  final String highlightQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineHeight = _headerLineHeight(theme);
    // 返信件数が押せるときだけ、件数のスロットを当たり判定の高さまで広げる。
    // 押せないレスは今までどおり 1 行分のままにして、一覧の詰まりを保つ。
    final classic = resLayout == ResLayout.classic;
    // クラシックの 1 段の高さは、そこに並ぶ字（labelMedium）ちょうどに落とす。
    // 名前・日時・ID はどれもこの字で、札のような箱は無い。名前用の行高（20）を
    // 使うと、字の上下に 2px ずつ空いたぶんが**段の間に二重で乗る**。
    final slotHeight = classic ? _classicLineHeight(theme) : lineHeight;
    final replyCountSlotHeight =
        onTapReplies != null && slotHeight < _replyCountTapHeight
        ? _replyCountTapHeight
        : slotHeight;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左グループ（名前・スレ主・自分）を Expanded で残り幅ごと占有させる。
        // 幅が足りないときは、要素を省略せず Wrap で 2 行目へ折り返す。
        // **時刻はここには無い**（レスの足元、[PostItem] 側の行に置いている）。
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              // クラシックは dat の 1 行を写したものなので、要素の間は語と語の
              // 間くらいに詰める。他の組み方は札が並ぶので広く取る。
              spacing: classic ? 5 : 8,
              // 折り返した段の間。**クラシックでは空けない**——長い日時のせいで
              // 2 段になるのが常態で、ここが空くと 1 レスのヘッダが 2 つの行に
              // 見えてしまう。段の中身はもともと字の高さちょうどなので、0 でも
              // 字どうしはくっつかない。
              runSpacing: classic ? 0 : 1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: classic
                  ? _classicChildren(
                      context,
                      constraints,
                      lineHeight: slotHeight,
                      replyCountSlotHeight: replyCountSlotHeight,
                    )
                  : _modernChildren(
                      context,
                      constraints,
                      lineHeight: slotHeight,
                      replyCountSlotHeight: replyCountSlotHeight,
                    ),
            ),
          ),
        ),
        // ヘッダにまとめる組み方の時刻。柱の組み方ではレスの足元、クラシックでは
        // 日付として左の並びの中にある。
        if (resLayout == ResLayout.header) ...[
          const SizedBox(width: 8),
          _HeaderSlot(
            height: lineHeight,
            child: _TimeLabel(res: res),
          ),
        ],
      ],
    );
  }

  /// dat の見出しをそのまま並べる（[ResLayout.classic]）。
  ///
  /// 順序は dat の 1 行と同じ——**番号・名前・日時・ID**。読む人がすでに知って
  /// いる並びなので、目が迷わない。
  ///
  /// dat に無いもの（このアプリが足したもの）は、**それが掛かっている語の直後**
  /// に差す。返信数はレス番号の後ろ（`>>N` が集めた数なので番号に掛かる）、
  /// その ID の何本目か（`n/m`）は ID の後ろ。専ブラが昔からこの位置に置いて
  /// いるので、置き場所を覚え直さずに読める。「何者か」の札だけは dat の語に
  /// 掛からないので末尾へ回す。
  List<Widget> _classicChildren(
    BuildContext context,
    BoxConstraints constraints, {
    required double lineHeight,
    required double replyCountSlotHeight,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 名前だけは他より 1 段大きい字（[_NameLabel] は labelLarge）なので、枠も
    // その行の高さで取る。ほかと同じ 16 に押し込めると、字が枠から数 px はみ出て
    // 下の段に触れる。
    final nameHeight = _headerLineHeight(theme);
    return [
      _HeaderSlot(
        height: lineHeight,
        child: _ClassicNumber(number: res.number),
      ),
      if (replyCount > 0)
        _HeaderSlot(
          height: replyCountSlotHeight,
          child: _ReplyCount(
            number: res.number,
            replyCount: replyCount,
            onTap: onTapReplies,
          ),
        ),
      // 名無しも省かずに出す。**この組み方だけは省略しない**——毎行同じ名前が
      // 並ぶ冗長さこそが dat の見出しの形で、そこを削ると他の組み方に寄る。
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth),
        child: _HeaderSlot(
          height: nameHeight,
          child: _NameLabel(
            name: fullName,
            // 名前の後ろの括弧（ワッチョイ等）だけ 1 段落とす。
            smallSuffix: true,
            highlightQuery: highlightQuery,
            wacchoi: wacchoi,
            onTapWacchoi: onTapWacchoi,
          ),
        ),
      ),
      _HeaderSlot(
        height: lineHeight,
        child: _ClassicDate(res: res),
      ),
      if (res.id != null)
        _HeaderSlot(
          height: lineHeight,
          child: _ClassicId(
            id: res.id!,
            count: idCount,
            ordinal: idOrdinal,
            isThreadOwner: isThreadOwner,
            onTap: onTapId,
          ),
        )
      // ID を出さない板では星の行き先が無いので、単独で置く。（この板でスレ主と
      // 分かるのはレス番号 1 だけ——判定は `>>1` と同じ ID かどうかなので、ID が
      // 無ければ他のレスでは立たない。）
      else if (isThreadOwner)
        _HeaderSlot(height: lineHeight, child: const _OwnerStar()),
      if (_selfChip(scheme) case final chip?) chip,
    ];
  }

  /// 自分・自分宛の札。両方立つことはない（自分のレスは自分宛にならない）。
  ///
  /// **柱の組み方では出さない。** あちらは絵に重ねた印（[_IdBadge]）が同じことを
  /// 言う。スレ主と違い、この 2 つはヘッダにまとめる組み方・クラシックでは札の
  /// まま——★ のような定着した記号が無く、「自分」「自分宛」の字自体はくだけた
  /// 言い方でもないため。
  Widget? _selfChip(ColorScheme scheme) {
    if (resLayout == ResLayout.gutter) return null;
    if (isOwn) return _OwnChip(color: scheme.secondary);
    if (isReplyToOwn) {
      return _OwnChip(
        color: scheme.primary,
        onColor: scheme.onPrimary,
        label: '自分宛',
        icon: Icons.reply,
        filled: true,
      );
    }
    return null;
  }

  List<Widget> _modernChildren(
    BuildContext context,
    BoxConstraints constraints, {
    required double lineHeight,
    required double replyCountSlotHeight,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return [
      // ヘッダは「どれだけ反応され・誰が・何者で・いつ」の順に読ませる。
      //
      // **レス番号は出さない。** 番号は `>>N` から辿るための参照値で、読むときには
      // 要らない。レスを指定する操作は左スワイプ（返信・`SwipeToReply`）と長押し
      // メニューが受け持つ。番号が要る読み方のためにクラシックの組み方がある。
      if (replyCount > 0)
        _HeaderSlot(
          height: replyCountSlotHeight,
          child: _ReplyCount(
            number: res.number,
            replyCount: replyCount,
            onTap: onTapReplies,
          ),
        ),
      // その ID の何本目か（`n/m`）はヘッダに出さない。**連投の多さは左の柱の
      // 外周リングの色が持っている**ので、ヘッダに数字で足すと同じことを二度
      // 言うことになる。正確なレス数は ID をタップしたシートの見出しに出る。
      //
      // ヘッダにまとめる組み方では、ID の絵もこの行に並ぶ。固定高さのスロットには
      // 入れない——狭いときは中身に応じて縦に伸び、それでも入らなければ折り返す。
      // スロットで 1 行に固定すると潰れる。
      //
      // スレ主の印はこの絵の角に載る（[_IdChip.isThreadOwner]）。「誰が」に
      // 掛かる情報なので、どの組み方でも ID から離さない。
      if (resLayout == ResLayout.header)
        if (res.id != null)
          _IdChip(
            id: res.id!,
            count: idCount,
            ordinal: idOrdinal,
            isThreadOwner: isThreadOwner,
            onTap: onTapId,
          )
        else
          // ID なしの板。アイコンごと省くと、名無し・返信なしのレスはヘッダが
          // 時刻だけになってレスの切れ目が読めなくなる。
          _NoIdChip(isThreadOwner: isThreadOwner),
      // Wrap の子は Flexible にできないので、極端に長い名前だけは行幅で頭打ちに
      // して省略する（通常の名前はそのまま 1 チャンク）。名無しは空文字で渡って
      // くるので、枠ごと出さない。
      if (name.text.isNotEmpty)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: _HeaderSlot(
            height: lineHeight,
            child: _NameLabel(
              name: name.text,
              muted: name.muted,
              highlightQuery: highlightQuery,
              wacchoi: wacchoi,
              onTapWacchoi: onTapWacchoi,
            ),
          ),
        ),
      if (_selfChip(scheme) case final chip?) chip,
    ];
  }

  /// クラシックの 1 段の高さ。並ぶ字（[TextTheme.labelMedium]）の行の高さ。
  double _classicLineHeight(ThemeData theme) {
    final style = theme.textTheme.labelMedium;
    final fontSize = style?.fontSize ?? 12;
    return fontSize * (style?.height ?? 16 / fontSize);
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
    this.smallSuffix = false,
    this.highlightQuery = '',
    this.wacchoi,
    this.onTapWacchoi,
  });
  final String name;

  /// 名乗っていない人の付随情報（ワッチョイ等）か。時刻と同じ「添え物」の見た目に
  /// 落として、コテハンだけが名前として目立つようにする。
  final bool muted;

  /// 名前の末尾の括弧（`エッヂの名無し (L20 ipkW-6PVw)` の後半）を 1 段落として
  /// 出すか。**名前を省略しないクラシックの組み方のためのもの。**
  ///
  /// 他の組み方は [PostItem._headerName] が既定名を落として括弧だけを残すので、
  /// 出るものがそもそも「添え物」しかない。クラシックは名乗りごと全部出すため、
  /// ワッチョイまで名前と同じ強さで並ぶ——匿名の掲示板で、名前より長い識別子が
  /// 毎行太字で載ることになる。**括弧の中だけ**時刻や ID と同じ大きさ・色に
  /// 落として、名前の後ろの添え物として読ませる。
  final bool smallSuffix;
  final String highlightQuery;

  /// この名前に含まれるワッチョイ（[PostItem.onTapWacchoi] と両方揃うと押せる）。
  final String? wacchoi;
  final ValueChanged<String>? onTapWacchoi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wacchoi = this.wacchoi;
    final onTapWacchoi = this.onTapWacchoi;
    final tappable = wacchoi != null && onTapWacchoi != null;
    final base = muted
        ? theme.textTheme.labelMedium
        : theme.textTheme.labelLarge;
    final style = base?.copyWith(
      color: muted
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
      fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
      // 押せる名前は点線の下線で示す。実線にすると本文中のリンクと同じ強さに
      // なってヘッダが騒がしくなるし、何も出さないと押せることに気付けない。
      decoration: tappable ? TextDecoration.underline : null,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: theme.colorScheme.onSurfaceVariant.withValues(
        alpha: 0.6,
      ),
    );
    final queryLower = highlightQuery.trim().toLowerCase();
    // 末尾の括弧を切り離す。切れなければ（コテハンだけの名前など）今までどおり
    // 1 つの字で出す。
    final suffix = smallSuffix ? _nameSuffixRe.firstMatch(name) : null;
    final Widget label;
    if (suffix != null) {
      final suffixStyle = theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        leadingDistribution: TextLeadingDistribution.even,
        decoration: style?.decoration,
        decorationStyle: style?.decorationStyle,
        decorationColor: style?.decorationColor,
      );
      label = Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(children: _spans(theme, suffix.group(1)!, queryLower)),
            // 名前と括弧の間の空白は元の綴りのまま残す（`_nameSuffixRe` は
            // 空白を group から外すので、ここで 1 つ入れ直す）。
            const TextSpan(text: ' '),
            TextSpan(
              style: suffixStyle,
              children: _spans(theme, suffix.group(2)!, queryLower),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (queryLower.isEmpty) {
      label = Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    } else {
      label = Text.rich(
        TextSpan(style: style, children: _spans(theme, name, queryLower)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (name.isEmpty) return label;
    if (tappable) {
      // 押せるときは長押しの吹き出し（省略された名前の全文）を出さない。同じ
      // 「名前を押す」がタップとで別のものに繋がると、どちらが起きるか読めない。
      // 名前の全文はワッチョイのシートの見出しに出る。
      return Semantics(
        button: true,
        label: 'ワッチョイ:$wacchoi $name',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => onTapWacchoi(wacchoi),
          borderRadius: BorderRadius.circular(4),
          child: label,
        ),
      );
    }
    return Tooltip(
      message: name,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      child: label,
    );
  }

  /// [text] を、スレ内検索の一致だけ塗り分けた span に開く。検索していなければ
  /// そのまま 1 つの span。
  List<InlineSpan> _spans(ThemeData theme, String text, String queryLower) {
    if (queryLower.isEmpty) return [TextSpan(text: text)];
    final spans = <InlineSpan>[];
    appendHighlighted(
      spans,
      text,
      queryLower,
      searchHighlightStyle(theme.colorScheme),
    );
    return spans;
  }
}

/// クラシックの組み方のレス番号（[ResLayout.classic]）。dat の行頭と同じ位置。
///
/// **押せない。** 番号を押して開くもの（返信一覧）は隣の件数が持っていて、同じ
/// 行で 2 つが同じ場所へ繋がると、どちらを押したのか分からなくなる。番号はここ
/// では読むためだけのもの——`>>N` を手で書くとき、必死チェッカーの結果と突き
/// 合わせるときに要る。
class _ClassicNumber extends StatelessWidget {
  const _ClassicNumber({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '$number',
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        leadingDistribution: TextLeadingDistribution.even,
        // 番号の桁が変わっても後ろの語がずれないよう、数字の幅を揃える。
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// クラシックの組み方の日時。**dat の表記そのまま**（秒・コンマ以下まで）。
///
/// 他の組み方は「たった今 / 3分前」に置き換えているが、それは読んでいる最中に
/// 効く形であって、連投の間隔を秒で見る・同じ時刻のレスを突き合わせるといった
/// 読み方には使えない。クラシックは後者のための組み方なので、丸めずに出す。
class _ClassicDate extends StatelessWidget {
  const _ClassicDate({required this.res});

  final Res res;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      res.dateText.trim(),
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// クラシックの組み方の ID。**絵にせず `ID:xxxx` の文字列のまま**出す。
///
/// 必死チェッカーに貼る・NG リストと突き合わせる・目で拾って覚える、といった
/// 「文字列として使う」読み方のための組み方なので、ここで絵に置き換えると
/// この組み方を選ぶ理由そのものが無くなる。
///
/// 押すと同一 ID 抽出（他の組み方の絵と同じ）。押せることは点線の下線で示す
/// ——実線は本文のリンクと同じ強さになり、ヘッダが騒がしくなる。
///
/// 何本目か（`n/m`）は **ID の直後**。専ブラが昔からこの位置に置いていて、
/// 「この ID は何回書いているか」を ID から目を動かさずに読める。色は本数の
/// 段階色（[idColorForCount]）で、ID の文字ごと染める。
///
/// スレ主は **ID に星を添えて**示す（[isThreadOwner]）。この組み方では札を出さ
/// ない——並びが dat の見出しの形をしているところへ、丸い札が 1 つ割り込むと
/// そこだけ別のアプリの部品に見える。スレ主かどうかは ID で判定しているもの
/// （`>>1` と同じ ID）なので、その ID に付ければ理屈も見た目も合う。書き方は
/// スレ主 NG の `[xxxx★]` と同じ。**星だけ別の色**にして、ID 文字列の一部と
/// 読まれないようにする。
class _ClassicId extends StatelessWidget {
  const _ClassicId({
    required this.id,
    required this.count,
    required this.ordinal,
    required this.isThreadOwner,
    required this.onTap,
  });

  final String id;
  final int count;
  final int ordinal;
  final bool isThreadOwner;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = idColorForCount(scheme, count);
    final tappable = onTap != null;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: count > 1 ? FontWeight.w600 : FontWeight.w400,
      leadingDistribution: TextLeadingDistribution.even,
      decoration: tappable ? TextDecoration.underline : null,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: color.withValues(alpha: 0.6),
    );
    final label = Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: 'ID:$id'),
          if (isThreadOwner)
            TextSpan(
              text: '★',
              style: TextStyle(
                color: scheme.tertiary,
                decorationColor: scheme.tertiary.withValues(alpha: 0.6),
              ),
            ),
          if (count > 1) TextSpan(text: ' ($ordinal/$count)'),
        ],
      ),
    );
    if (!tappable) return label;
    return Semantics(
      button: true,
      // 星は読み上げられないので、元の札の文言をここで言う。
      label: [
        count > 1 ? 'ID:$id ($ordinal/$count)' : 'ID:$id',
        if (isThreadOwner) 'スレ主',
      ].join(' '),
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onTap!(id),
        borderRadius: BorderRadius.circular(4),
        child: label,
      ),
    );
  }
}

/// 単独で立てるスレ主の星。**ID を出さない板でのクラシックだけ**が使う——他は
/// 印の行き先（絵の角、あるいは ID 文字列の後ろ）があるが、ここには無い。
/// [_ClassicId] の中の星と同じ形・同じ色。
///
/// **字は出さない。** 「スレ主」という言い方はくだけていて、読んでいる間じゅう
/// 目に入る場所に置くには強すぎる。★ はスレ主 NG の `[xxxx★]` と同じ記号で、
/// 言葉のほうは NG のメニューと NG 管理の画面に残っているので、意味はそこから
/// 辿れる。読み上げにだけ言葉を渡す。
class _OwnerStar extends StatelessWidget {
  const _OwnerStar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'スレ主',
      child: Text(
        '★',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.tertiary,
          height: 1,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
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
    // 幅は中身に合わせて縮める（Wrap 内で全幅化させない）が、**高さは ID の
    // チップに合わせる**（[_headerChipHeight]）。字の高さなりにすると 3px 低く
    // なり、同じ行に並ぶ枠付きの箱どうしで上下の辺が食い違う。
    //
    // 固定ではなく下限にしておくのは、端末の文字を大きくする設定のため。ID の
    // チップは中身が絵なので伸びないが、こちらは字なので伸びる——固定すると
    // そこで文字が切れる。
    //
    // **[Container.alignment] は使わない。** 揃え位置を渡すと箱が「与えられた
    // 制約いっぱい」に育ち、Wrap の中では横幅いっぱいの札になって 1 個ずつ縦に
    // 積まれる。下限だけ渡せば、中の Row（既定で縦中央揃え）が字を真ん中に置く。
    return Container(
      constraints: const BoxConstraints(minHeight: _headerChipHeight),
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

/// レス時刻。24 時間以内は「たった今 / n分前 / n時間前」、それより古ければ
/// HH:MM。タップでコンマ以下・日付まで含む完全な日時をその場に出す。
///
/// 直近を相対にするのは、読んでいる最中に効く情報が「何時に書かれたか」より
/// 「どれくらい前か」だから。1 日以上前は逆で、「3日前」が並ぶより時刻の方が
/// 位置を掴めるので絶対表記に戻す。
///
/// 絶対表記で秒を落とすのは、ヘッダの右端で幅を 1 文字分でも空けるため（左の
/// 名前・ID の幅がその分増え、ID の位置が揃いやすくなる）。秒が要る場面（連投の
/// 間隔を見るなど）はタップで完全な日時が出るので、情報自体は失われない。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.res});
  final Res res;

  /// レスの足元に置くときの、字の上下の余白。
  ///
  /// **本文にぴったり付ける。** ここが空くと、時刻が本文と次のレスの真ん中に
  /// 浮いて、どちらのレスのものか読めなくなる。
  static const _footerVerticalPadding = 0.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final full = res.dateText.trim();
    final label = LiveResTime(
      when: res.dateTime,
      text: (now) => relativeResTime(res.dateTime, now: now) ?? _short(res),
      builder: (context, text) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 4,
          vertical: _footerVerticalPadding,
        ),
        child: Text(text, style: style?.copyWith(height: 1)),
      ),
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

/// ヘッダの行に並ぶ小箱（ID のチップと「自分」の札）の枠と、中身までの余白。
const double _headerChipBorder = 1.2;
const double _headerChipPadding = 1;

/// その小箱の高さ。ID のチップは中の絵（16）＋余白＋枠でこの寸法になるので、
/// 札のほうをここへ合わせる。
///
/// **揃えないと同じ行に高さの違う箱が並ぶ。** 枠を持つものどうしが 3px 違うと、
/// 縦中央で揃えても上下の辺が食い違って、行が波打って見える。
const double _headerChipHeight =
    16 + (_headerChipBorder + _headerChipPadding) * 2;

/// ヘッダのチップ（16px の絵）に載せる印の外径。柱の 13 をそのまま持ってくると
/// 絵の面積の大半を覆うので、絵の縮小に合わせて詰める。
const double _headerBadgeSize = 11;

/// ID なしの板でのアイコン枠。[_IdChip] と同じ大きさ・同じ位置を占め、
/// ヘッダの左端とレスの切れ目だけを保つ。
///
/// 押せない（絞り込む ID が無い）し、輪も色を持たない（連投を数えられない）。
/// 誰が書いたかは分からないが、スレ主かどうかは ID とは別の手掛かり（レス番号
/// 1）から分かるので、印はここにも載る。
class _NoIdChip extends StatelessWidget {
  const _NoIdChip({required this.isThreadOwner});

  final bool isThreadOwner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final marks = (owner: isThreadOwner, own: false, replyToOwn: false);
    return Semantics(
      label: 'IDなし${_marksLabel(marks)}',
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: _MarkedIdIcon(
          marks: marks,
          badgeSize: _headerBadgeSize,
          child: Container(
            padding: const EdgeInsets.all(_headerChipPadding),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.8),
                width: _headerChipBorder,
              ),
            ),
            child: const IdIconPlaceholder(),
          ),
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
    required this.isThreadOwner,
    required this.onTap,
  });
  final String id;
  final int count;
  final int ordinal;

  /// スレ主のレスか。**この組み方でも印は絵に載せる**（[_MarkedIdIcon]）——
  /// 柱の組み方・クラシックと揃えて、「何者か」は必ず ID の側に付ける。絵は
  /// 16px と小さいので、印もそのぶん小さくする。
  ///
  /// 自分・自分宛はこの組み方では文字の札のまま（[_Header._selfChip]）。★ と
  /// 違って定着した記号が無く、「自分」「自分宛」の字自体はくだけた言い方でも
  /// ないので、読める形で残している。
  final bool isThreadOwner;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final color = idColorForCount(Theme.of(context).colorScheme, count);
    final marks = (owner: isThreadOwner, own: false, replyToOwn: false);
    return Semantics(
      // 絵には読み上げるものが無いので、元のチップの文言をここに持たせる。
      // ウィジェットテストもこのラベルでアイコンを掴む。
      label:
          (count > 1 ? 'ID:$id ($ordinal/$count)' : 'ID:$id') +
          _marksLabel(marks),
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
              _MarkedIdIcon(
                marks: marks,
                badgeSize: _headerBadgeSize,
                child: Container(
                  padding: const EdgeInsets.all(_headerChipPadding),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    // レス数で色を変えるのは外周のリングと下の数だけ。中の絵は
                    // ID ごとの色なので、そこに連投の多さを混ぜると両方読めなく
                    // なる。
                    border: Border.all(
                      color: color.withValues(alpha: 0.75),
                      width: _headerChipBorder,
                    ),
                  ),
                  child: IdIcon(id: id),
                ),
              ),
              if (count > 1) ...[
                // 印が右へはみ出すぶん、数との間を空ける。詰めたままだと星と
                // 数字がくっついて、星が数字の一部に見える。
                SizedBox(width: isThreadOwner ? 7 : 4),
                // 上のラベルが「ID:xxx (1/2)」まで読み上げるので、同じことを
                // 言うこの数字は読み上げから外す。見た目の要約でしかない。
                ExcludeSemantics(
                  child: Text(
                    '$ordinal/$count',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      leadingDistribution: TextLeadingDistribution.even,
                      // リングと同じ段階色。同じことを言っている 2 つなので、
                      // 色を揃えて 1 つの目印として読ませる。
                      color: color,
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

/// 左の柱に立てる identicon の一辺。ぶら下がった返信（[PostItem.nested]）でも
/// 同じ大きさにする。
///
/// ヘッダの行と本文の 1 行目にまたがって置くので、ここを大きくしてもレスの
/// 高さは増えない。文字と行を共有していた頃（ヘッダのチップ）は行の高さが
/// 上限だったが、柱にしたことでその縛りが外れている。
///
/// とはいえ上限が無いから大きく取る、ではない。柱は「誰が」を照合するための
/// 目印で、本文より目立つと読む順が狂う。5 の倍数にしておくと 5x5 のマスが
/// 整数 px に乗って形も締まる（24 では 1 マス 4.8px で滲む）。
///
/// 返信を一回り小さくしていた時期があるが、字下げがすでに従属を示しているうえ、
/// 親と子で絵の大きさが違うと同じ ID かどうかの照合がしにくかったのでやめた。
const double _idGutterSize = 20;

/// レスの左右の余白。画面端から本文までの距離。
///
/// レス間の区切り線もここに合わせて引く（`thread_screen.dart`）ので公開して
/// ある——線がレスの中身の左端から始まると、その線が下のレスの上端の縁として
/// 読める。
const double resLeftPadding = 16;

/// ぶら下がった返信（[PostItem.nested]）での左の余白。字下げがすぐ左にあるぶん、
/// 画面端から始まる行より詰める。[resLeftPadding] と同じ理由で公開してある。
const double nestedResLeftPadding = 8;

/// 柱と本文の間。
const double _idGutterGap = 10;

/// レスの上下の余白。
const double _resVerticalPadding = 6;

/// 返信先の引用行がすぐ上にあるレスの、上の余白（[PostItem.attachedToQuote]）。
///
/// 引用行はこのレスのものなので、間を詰めて 1 かたまりに見せる。0 にしないのは、
/// 柱・ヘッダの組み方では見出しに identicon が立っていて、その上端が引用行の字に
/// 触れてしまうため。
const double _quotedResTopPadding = 2;

/// クラシックの組み方でのレスの上下の余白。
///
/// 見出しが字だけ・行も詰まっているので、他と同じ 6 を空けるとレスの中の行間と
/// レスとレスの間が同じに見える。**返信先の引用行（`QuotedResRow`）との間**が
/// とくに響く——引用行はその下のレスのものなのに、間が空くと上のレスに付いて
/// いるようにも見える。詰めたぶんの切れ目は、各行の頭に立つレス番号が受け持つ。
const double _classicResVerticalPadding = 4;

/// 本文の字の大きさと行の高さ。一覧のタイトル（14px）寄りに詰めつつ、読む主役の
/// テキストなので 1px 大きくして行間を確保する。
const double _bodyFontSize = 15;
const double _bodyLineHeight = 1.4;

/// 柱の絵の下に添える連投数（`n/m`）の字の大きさ。
const double _idGutterCountSize = 10;

/// そのレスが「何者の発言か」。柱の絵に重ねる印（[_IdBadge]）になる。
typedef _ResMarks = ({bool owner, bool own, bool replyToOwn});

/// 印を読み上げ用の文言にする。絵には読み上げるものが無いので、柱のラベルへ
/// 足して文字の札だったときと同じことを言わせる。
String _marksLabel(_ResMarks marks) {
  final words = [
    if (marks.owner) 'スレ主',
    if (marks.own) '自分',
    if (marks.replyToOwn) '自分宛',
  ];
  return words.isEmpty ? '' : ' ${words.join(' ')}';
}

/// ID の絵の角に載せる小さな印。★＝スレ主、人＝自分、矢印＝自分宛。
///
/// 文字の札（[_OwnChip]）を置き換えたもの。札は「スレ主」の 3 文字のために
/// ヘッダの行を 1 つ要求していて、名無し・返信なしのレス——板でいちばん多い
/// 形——では**その札だけのために行が増えていた**。印を絵に載せれば行は消え、
/// 「誰が」を語るものが 1 か所にまとまる。
///
/// 地色で縁取るのは、印を絵から浮かせるため。囲いが無いと identicon のドットと
/// 混ざって、絵の一部（マスの塗り）に見える。
class _IdBadge extends StatelessWidget {
  const _IdBadge({
    required this.icon,
    required this.color,
    required this.onColor,
    required this.size,
  });

  final IconData icon;
  final Color color;
  final Color onColor;

  /// 外径。絵に対してこれ以上大きいと、絵そのものが読めなくなる。柱（20px の
  /// 絵）で 13、ヘッダのチップ（16px の絵）で 11。
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: size < 12 ? 1.2 : 1.5,
        ),
      ),
      // 字形が単純で中の詰まったものだけを使う。この大きさでは線の細いアイコンは
      // 消える。
      child: Icon(icon, size: size * 0.62, color: onColor),
    );
  }
}

/// ID の絵に印を重ねる。付くものが無ければ [child] をそのまま返す。
///
/// スレ主は右上、自分・自分宛は右下。**自分と自分宛は同時に立たない**ので、
/// 同時に出るのは最大 2 つ（自分が立てたスレでの自分のレス）。
class _MarkedIdIcon extends StatelessWidget {
  const _MarkedIdIcon({
    required this.marks,
    required this.child,
    this.badgeSize = 13,
  });

  final _ResMarks marks;
  final Widget child;

  /// 印の外径。絵の大きさに合わせて渡す（[_IdBadge.size]）。
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    if (!marks.owner && !marks.own && !marks.replyToOwn) return child;
    final scheme = Theme.of(context).colorScheme;
    // はみ出す量は印の大きさなり。小さい印を大きくはみ出させると、絵から離れて
    // 「隣にある別のもの」に見える。
    final out = badgeSize / 4;
    return Stack(
      // 印は絵の角から少しはみ出す。絵の中へ収めると絵の面積の大半を印が占めて、
      // 肝心の identicon が読めなくなる。
      clipBehavior: Clip.none,
      children: [
        child,
        if (marks.owner)
          Positioned(
            top: -out,
            right: -out,
            child: _IdBadge(
              icon: Icons.star_rounded,
              color: scheme.tertiary,
              onColor: scheme.onTertiary,
              size: badgeSize,
            ),
          ),
        if (marks.own)
          Positioned(
            bottom: -out / 3,
            right: -out,
            child: _IdBadge(
              icon: Icons.person_rounded,
              color: scheme.secondary,
              onColor: scheme.onSecondary,
              size: badgeSize,
            ),
          )
        else if (marks.replyToOwn)
          Positioned(
            bottom: -out / 3,
            right: -out,
            child: _IdBadge(
              icon: Icons.reply,
              color: scheme.primary,
              onColor: scheme.onPrimary,
              size: badgeSize,
            ),
          ),
      ],
    );
  }
}

/// ID なしの板での柱。[_IdGutter] と同じ幅を占め、本文の左端を揃える。
///
/// 押せない（絞り込む ID が無い）し、輪も色を持たない（連投を数えられない）。
/// 誰が書いたかは分からないが、スレ主・自分の印は ID とは別の手掛かりから
/// 分かるので、ここでも出す。
class _NoIdGutter extends StatelessWidget {
  const _NoIdGutter({required this.size, required this.marks});

  final double size;
  final _ResMarks marks;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'IDなし${_marksLabel(marks)}',
      child: Padding(
        // ヘッダの文字（行高 20）の中心と絵の中心を合わせる。
        padding: const EdgeInsets.only(top: 2),
        child: _MarkedIdIcon(
          marks: marks,
          child: IdIconPlaceholder(size: size),
        ),
      ),
    );
  }
}

/// レスの左に立てる「誰が」の柱。identicon と、その ID の何レス目かを縦に積む。
///
/// ヘッダの文字列（名前・時刻・返信数）と同じ行に並べず、行の外へ出している。
/// 絵と文字を同じ行に混ぜると、絵の大きさが行の高さに縛られて小さくしか
/// できず、しかも文字と近い大きさになって「行内の記号」に見えてしまう。柱に
/// すれば大きさを行から切り離せて、役割の違いも見た目に出る。
class _IdGutter extends StatelessWidget {
  const _IdGutter({
    required this.id,
    required this.count,
    required this.ordinal,
    required this.size,
    required this.marks,
    required this.onTap,
  });
  final String id;
  final int count;
  final int ordinal;
  final double size;
  final _ResMarks marks;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final color = idColorForCount(Theme.of(context).colorScheme, count);
    return Semantics(
      // 絵には読み上げるものが無いので、元のチップの文言をここに持たせる。
      // ウィジェットテストもこのラベルでアイコンを掴む。
      label:
          (count > 1 ? 'ID:$id ($ordinal/$count)' : 'ID:$id') +
          _marksLabel(marks),
      button: onTap != null,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(id),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          // ヘッダの文字（行高 20）の中心と絵の中心を合わせる。
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MarkedIdIcon(
                marks: marks,
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    // レス数で色を変えるのは外周のリングと下の数だけ。中の絵は
                    // ID ごとの色なので、そこに連投の多さを混ぜると両方読めなく
                    // なる。
                    border: Border.all(
                      color: color.withValues(alpha: 0.75),
                      width: 1.5,
                    ),
                  ),
                  child: IdIcon(id: id, size: size),
                ),
              ),
              if (count > 1)
                // 上のラベルが「ID:xxx (1/15)」まで読み上げるので、同じことを
                // 言うこの数字は読み上げから外す。見た目の要約でしかない。
                ExcludeSemantics(
                  child: Text(
                    '$ordinal/$count',
                    style: TextStyle(
                      fontSize: _idGutterCountSize,
                      // 行の高さを字の高さちょうどにして、絵との間を詰める。
                      // ここが空くと柱が本文より高くなり、1 行だけのレスが
                      // 絵の分だけ間延びする。
                      height: 1,
                      leadingDistribution: TextLeadingDistribution.even,
                      // リングと同じ段階色。数と輪は同じことを言っているので、
                      // 色を揃えて 1 つの目印として読ませる。
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
