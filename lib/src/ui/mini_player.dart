/// 動画を小窓に残したままスレを読めるようにする、アプリ内ミニプレーヤー。
///
/// **OS の PiP は使わない。** YouTube / ニコニコは WebView 再生なので Android の
/// Activity PiP にも iOS の `AVPictureInPicture` にも載せられない（載る先は
/// ExoPlayer / AVPlayer のレイヤであって WKWebView の中の `<video>` ではない）。
/// そもそも OS の PiP は**アプリの外へ出る**仕組みで、「スレを読みながら流す」と
/// いう目的とは向きが逆になる。
///
/// 作りの要は **プレーヤーを作り直さないこと**。`WebViewWidget` を別の場所へ
/// 組み直すとネイティブの WebView ごと作り直され、再生が頭に戻る。そこで映像は
/// 最初から [MiniPlayerHost]（`MaterialApp.builder` の層＝Navigator の外）に置き、
/// 全画面と小窓は**同じウィジェットの位置と大きさを変えるだけ**にしてある。
/// Navigator の外にいるので、別のスレへ移っても再生は続く。
///
/// 全画面のときだけ真っ黒なルートを 1 枚 push する。これは絵のためではなく
/// **「戻る」を受けるため**で（Overlay 層はルートではないので戻るキーが届かない）、
/// 映像そのものは常に Overlay 側にある。戻ると小窓へ落ちる＝終了ではない。
library;

import 'package:flutter/material.dart';

import '../net/auth_launcher.dart';
import 'embed_player.dart';
import 'embed_urls.dart';
import 'video_player_view.dart';

/// プレーヤーの見せ方。
enum MiniPlayerMode { fullscreen, mini }

/// いま再生しているもの 1 件。
sealed class MiniPlayerMedia {
  const MiniPlayerMedia({this.onOpenExternally});

  /// 「ブラウザで開く」の実処理。未指定ならシステムブラウザで開く。
  final ValueChanged<Uri>? onOpenExternally;
}

/// YouTube / ニコニコなどのサービス動画（WebView 再生）。
class EmbedMedia extends MiniPlayerMedia {
  const EmbedMedia(this.video, {super.onOpenExternally});

  final EmbedVideo video;
}

/// mp4 等の直リンク（`video_player` 再生）。
class FileMedia extends MiniPlayerMedia {
  const FileMedia(this.url, {super.onOpenExternally});

  final Uri url;
}

/// 再生中のメディアと見せ方を持つ。アプリに 1 つだけ（[shared]）。
///
/// 「戻る」を受けるためのルートもここで出し入れする。ルートは黒い板 1 枚で、
/// 映像は [MiniPlayerHost] 側にあることに注意。
class MiniPlayerController extends ChangeNotifier {
  MiniPlayerController();

  static final MiniPlayerController shared = MiniPlayerController();

  MiniPlayerMedia? _media;
  MiniPlayerMode _mode = MiniPlayerMode.fullscreen;
  int _session = 0;
  Offset? _miniTopLeft;

  NavigatorState? _navigator;
  Route<void>? _route;

  MiniPlayerMedia? get media => _media;
  MiniPlayerMode get mode => _mode;

  /// 再生ごとに増える通し番号。プレーヤーのウィジェット key に使い、**別の動画に
  /// 差し替わったときだけ**作り直されるようにする（全画面⇔小窓では作り直さない）。
  int get session => _session;

  /// 利用者がドラッグして決めた小窓の左上位置。未設定なら既定位置に置く。
  Offset? get miniTopLeft => _miniTopLeft;

  bool get isPlaying => _media != null;

  /// [media] を全画面で開く。すでに何か流れていれば差し替える。
  void open(BuildContext context, MiniPlayerMedia media) {
    _media = media;
    _session++;
    _mode = MiniPlayerMode.fullscreen;
    _miniTopLeft = null;
    notifyListeners();
    if (_route == null) _pushBackdrop(Navigator.of(context));
  }

  /// 小窓へ落とす（再生は続く）。
  void minimize() {
    if (_media == null || _mode == MiniPlayerMode.mini) return;
    _mode = MiniPlayerMode.mini;
    _removeBackdrop();
    notifyListeners();
  }

  /// 小窓から全画面へ戻す。
  void expand() {
    if (_media == null || _mode == MiniPlayerMode.fullscreen) return;
    _mode = MiniPlayerMode.fullscreen;
    notifyListeners();
    final navigator = _navigator;
    if (_route == null && navigator != null && navigator.mounted) {
      _pushBackdrop(navigator);
    }
  }

  /// 再生をやめて片付ける。
  void close() {
    if (_media == null) return;
    _media = null;
    _mode = MiniPlayerMode.fullscreen;
    _miniTopLeft = null;
    _removeBackdrop();
    notifyListeners();
  }

  /// 小窓をドラッグで動かす。画面内に収める丸めは [MiniPlayerHost] 側で行う。
  void moveMini(Offset topLeft) {
    if (_miniTopLeft == topLeft) return;
    _miniTopLeft = topLeft;
    notifyListeners();
  }

  /// 全画面の間だけ、「戻る」を受け取るためのルートを重ねる。
  ///
  /// 遷移は付けない（黒い板が出入りするだけで、見えている映像は Overlay 側の
  /// [AnimatedPositioned] が動かす）。
  void _pushBackdrop(NavigatorState navigator) {
    _navigator = navigator;
    final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) =>
          const ColoredBox(color: Colors.black, child: SizedBox.expand()),
    );
    _route = route;
    navigator.push(route).then((_) {
      // 「戻る」で全画面を抜けたときだけここへ来る。自分で外したときは
      // _route を先に null にしてあるので素通りする。
      if (!identical(_route, route)) return;
      _route = null;
      minimize();
    });
  }

  void _removeBackdrop() {
    final route = _route;
    _route = null;
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    // 全画面のときは映像が画面を覆っていて上に何も積めないので、普通は最前面。
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @visibleForTesting
  void debugReset() {
    _media = null;
    _mode = MiniPlayerMode.fullscreen;
    _miniTopLeft = null;
    _navigator = null;
    _route = null;
  }
}

/// [video]（YouTube / ニコニコ）をアプリ内プレーヤーで開く。
///
/// [onOpenExternally] を渡すと「ブラウザで開く」をそのハンドラに委ねる。
void openEmbedPlayer(
  BuildContext context,
  EmbedVideo video, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  if (!supportsEmbedWebView) {
    // macOS など WebView を持たない環境ではブラウザへ回す（従来どおり）。
    if (onOpenExternally != null) {
      onOpenExternally(video.url);
    } else {
      const SystemBrowserLauncher().open(video.url);
    }
    return;
  }
  MiniPlayerController.shared.open(
    context,
    EmbedMedia(video, onOpenExternally: onOpenExternally),
  );
}

/// [url]（mp4 等の直リンク）をアプリ内プレーヤーで開く。
void openVideoPlayer(
  BuildContext context,
  Uri url, {
  ValueChanged<Uri>? onOpenExternally,
}) {
  MiniPlayerController.shared.open(
    context,
    FileMedia(url, onOpenExternally: onOpenExternally),
  );
}

/// アプリ全体を包み、その上にプレーヤーを浮かせる層。`MaterialApp.builder` に置く。
class MiniPlayerHost extends StatefulWidget {
  const MiniPlayerHost({super.key, required this.child, this.controller});

  final Widget child;

  /// 差し替え用（テスト）。既定は [MiniPlayerController.shared]。
  final MiniPlayerController? controller;

  @override
  State<MiniPlayerHost> createState() => _MiniPlayerHostState();
}

class _MiniPlayerHostState extends State<MiniPlayerHost> {
  /// 小窓の余白と大きさ。16:9 固定で、映像はこの中に収める（比率はまちまちなので
  /// 窓の形まで動かすと置き場所が定まらない）。
  static const _margin = 12.0;
  static const _maxMiniWidth = 220.0;
  static const _minMiniWidth = 160.0;

  /// 全画面⇔小窓の移動時間。[Material] の角丸・影もこれに合わせる。
  static const _moveDuration = Duration(milliseconds: 240);

  /// 全画面用の操作（閉じる・小さくする・シークバー等）を出す下限の幅。
  ///
  /// 全画面と小窓を行き来する間、枠の大きさはアニメーションで連続的に変わる。
  /// 見せ方を**モードではなく実際の幅で決める**と、まだ小さい枠に全画面用の
  /// 操作を詰め込んで溢れることがない。小窓は最大 220dp、実機の画面は最小でも
  /// 320dp なので、この値でどちらか一方に必ず落ちる。
  static const _chromeMinWidth = 280.0;

  late final MiniPlayerController _controller =
      widget.controller ?? MiniPlayerController.shared;

  /// プレーヤーを載せる Overlay の口。**この層は Navigator の外**にいるので、
  /// Tooltip のように直近の Overlay を探すウィジェットは自前で用意しないと
  /// 見つけられない（アプリ側の Overlay はこの下にある）。
  ///
  /// 口はアプリと同じ寿命なので remove/dispose はしない。
  late final OverlayEntry _entry = OverlayEntry(builder: _buildLayer);

  final _dragging = ValueNotifier(false);
  Offset _dragTopLeft = Offset.zero;

  @override
  void dispose() {
    _dragging.dispose();
    super.dispose();
  }

  Size _miniSize(Size screen) {
    final width = (screen.width * 0.55).clamp(_minMiniWidth, _maxMiniWidth);
    return Size(width, width * 9 / 16);
  }

  /// 既定の置き場は**右上**。右下は「最新へ」ボタンと入力欄があり、下端は
  /// キーボードで隠れる。掴んで動かせるので、初期位置は邪魔が少ない側に置く。
  Offset _defaultTopLeft(Size screen, EdgeInsets padding, Size mini) => Offset(
    screen.width - mini.width - _margin,
    padding.top + kToolbarHeight + _margin,
  );

  /// 小窓を画面内（キーボードが出ていればその上）に収める。
  Offset _clamp(
    Offset topLeft,
    Size screen,
    EdgeInsets padding,
    EdgeInsets insets,
    Size mini,
  ) {
    final minX = _margin;
    final maxX = screen.width - mini.width - _margin;
    final minY = padding.top + _margin;
    final maxY =
        screen.height - insets.bottom - padding.bottom - mini.height - _margin;
    return Offset(
      maxX < minX ? minX : topLeft.dx.clamp(minX, maxX),
      maxY < minY ? minY : topLeft.dy.clamp(minY, maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // アプリ本体は常に children[0]。ここを出し入れするとスレ画面の State が
        // 捨てられるので、プレーヤーが無いときも Stack ごと畳まない。
        widget.child,
        Overlay(initialEntries: [_entry]),
      ],
    );
  }

  /// プレーヤーの層。何も再生していないときは空の [Stack] で、当たり判定を
  /// 持たない＝下のアプリがそのまま触れる。
  Widget _buildLayer(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, _dragging]),
    builder: (context, _) {
      final media = _controller.media;
      return Stack(
        fit: StackFit.expand,
        children: [if (media != null) _player(context, media)],
      );
    },
  );

  Widget _player(BuildContext context, MiniPlayerMedia media) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final fullscreen = _controller.mode == MiniPlayerMode.fullscreen;
    final mini = _miniSize(screen);
    final topLeft = _clamp(
      _controller.miniTopLeft ?? _defaultTopLeft(screen, padding, mini),
      screen,
      padding,
      insets,
      mini,
    );

    return AnimatedPositioned(
      left: fullscreen ? 0 : topLeft.dx,
      top: fullscreen ? 0 : topLeft.dy,
      width: fullscreen ? screen.width : mini.width,
      height: fullscreen ? screen.height : mini.height,
      duration: _dragging.value ? Duration.zero : _moveDuration,
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.black,
        elevation: fullscreen ? 0 : 8,
        borderRadius: BorderRadius.circular(fullscreen ? 0 : 12),
        clipBehavior: Clip.antiAlias,
        animationDuration: _moveDuration,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              // 映像は必ず children[0]。session が変わったときだけ作り直す。
              KeyedSubtree(
                key: ValueKey(_controller.session),
                child: _view(
                  media,
                  mini: constraints.maxWidth < _chromeMinWidth,
                ),
              ),
              if (!fullscreen)
                ..._miniChrome(topLeft, screen, padding, insets, mini),
            ],
          ),
        ),
      ),
    );
  }

  Widget _view(MiniPlayerMedia media, {required bool mini}) => switch (media) {
    EmbedMedia(:final video, :final onOpenExternally) => EmbedPlayerView(
      video: video,
      mini: mini,
      onClose: _controller.close,
      onMinimize: _controller.minimize,
      onOpenExternally: onOpenExternally,
    ),
    FileMedia(:final url, :final onOpenExternally) => VideoPlayerView(
      url: url,
      mini: mini,
      onClose: _controller.close,
      onMinimize: _controller.minimize,
      onOpenExternally: onOpenExternally,
    ),
  };

  /// 小窓の操作は**すべてこちら側が持つ**。中身（WebView）に指を取られると窓を
  /// 動かせなくなるので、映像の上に透明な層を敷いて触らせない。閉じるボタンは
  /// その層より後ろに並べて、当たり判定で勝つようにする。
  List<Widget> _miniChrome(
    Offset topLeft,
    Size screen,
    EdgeInsets padding,
    EdgeInsets insets,
    Size mini,
  ) => [
    Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _controller.expand,
        onPanStart: (_) {
          _dragTopLeft = topLeft;
          _dragging.value = true;
        },
        onPanUpdate: (details) {
          _dragTopLeft = _clamp(
            _dragTopLeft + details.delta,
            screen,
            padding,
            insets,
            mini,
          );
          _controller.moveMini(_dragTopLeft);
        },
        onPanEnd: (_) => _dragging.value = false,
        onPanCancel: () => _dragging.value = false,
      ),
    ),
    Positioned(
      top: 0,
      right: 0,
      child: IconButton(
        tooltip: '閉じる',
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: Colors.white,
        onPressed: _controller.close,
        icon: const Icon(Icons.close),
      ),
    ),
  ];
}
