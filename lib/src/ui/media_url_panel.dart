/// 全画面ビューア・プレーヤーの題名まわり。
///
/// 題名に出るのは**ファイル名だけ**（`2/5  a.jpg`）なので、どこから来たものかが
/// 読めない。同じ `image.jpg` でもホストを見ないと素性は分からないし、あとで元を
/// 辿りたいこともある。押すと題名の下に URL 全体を開き、写せるようにする。
///
/// 画像（`post_images.dart` の `MediaViewerView`）と動画（`video_player_view.dart`）
/// で同じ部品を使う——どちらも同じ並びの中を送っていくので、片方だけ URL を出せる
/// のは覚え方として筋が悪い。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// タップで [MediaUrlPanel] を出し入れする題名。右の ▽ が「まだ下がある」印。
class MediaTitleButton extends StatelessWidget {
  const MediaTitleButton({
    super.key,
    required this.title,
    required this.open,
    required this.onTap,
  });

  final String title;

  /// URL を開けているか。印（▽／△）と説明を切り替える。
  final bool open;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: open ? 'URLを閉じる' : 'URLを見る',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            Icon(
              open ? Icons.expand_less : Icons.expand_more,
              color: Colors.white,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

/// 題名の下に開く、表示中の URL 全体。
///
/// 暗幕（[TopScrim]）は下へ抜けていく途中なので、ここだけは自前の下敷きを持つ
/// （長い URL が薄いところまで伸びても読めるように）。写せるようにしてあるのは
/// URL そのものを他所へ渡したいときのため——ブラウザで開くだけでは手元に残らない。
class MediaUrlPanel extends StatefulWidget {
  const MediaUrlPanel({super.key, required this.url});

  final Uri url;

  @override
  State<MediaUrlPanel> createState() => _MediaUrlPanelState();
}

class _MediaUrlPanelState extends State<MediaUrlPanel> {
  /// 直前に写した。押した手応えとして印を出す。
  bool _copied = false;

  Timer? _timer;

  @override
  void didUpdateWidget(MediaUrlPanel old) {
    super.didUpdateWidget(old);
    // 開けたまま隣へ送られた。写した印は前の URL のものなので消す。
    if (old.url != widget.url) _clearCopied();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _clearCopied() {
    _timer?.cancel();
    if (_copied) setState(() => _copied = false);
  }

  /// 表示中の URL を写す。
  ///
  /// ビューアは Navigator の外に載っていて、SnackBar は下（アプリ側）へ出るので
  /// この黒い画面には届かない。知らせはボタンの見た目そのもので返す。
  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url.toString()));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  widget.url.toString(),
                  // 折り返して全部見せる。ここまで長い URL はまず無いが、
                  // 際限なく伸ばして絵を隠すこともしない。
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'URLをコピー',
                color: Colors.white,
                visualDensity: VisualDensity.compact,
                onPressed: _copy,
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
