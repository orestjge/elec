/// 「反応が集まったレス」の段階。
///
/// スレマップの目印（`thread_map.dart`）とレス本体のレス番号（`post_item.dart`）
/// で同じ基準を使い、マップで見つけた場所とレスの見た目が対応するようにする。
///
/// **色はここで持たない。** 面（マップの細いバー）は淡い色でも読めるので濃さ
/// 2 段階で示せるが、テキスト（レス番号）は淡くすると読めないので色 1 段階＋
/// 太さで示す、というように媒体ごとに最適な出し方が違うため。
library;

/// この件数以上の返信を集めたレスを「反応が集まった」とみなす。
const manyRepliesThreshold = 5;

/// さらに上の段階。
const veryManyRepliesThreshold = 10;

enum ReplyTier { none, many, veryMany }

ReplyTier replyTierOf(int replyCount) => switch (replyCount) {
  >= veryManyRepliesThreshold => ReplyTier.veryMany,
  >= manyRepliesThreshold => ReplyTier.many,
  _ => ReplyTier.none,
};
