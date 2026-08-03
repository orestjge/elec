import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'back_swipe.dart';
import 'image_edit.dart';
import 'image_edit_render.dart';

/// 画像を編集してから返す。編集せず送るなら元の [file] がそのまま返り、
/// やめたときは null。
Future<XFile?> pushImageEditor(BuildContext context, XFile file) async {
  final bytes = await file.readAsBytes();
  if (!context.mounted) return null;
  return Navigator.of(context).push<XFile>(
    SwipeBackPageRoute<XFile>(
      pageBuilder: (_, _, _) => ImageEditorScreen(source: file, bytes: bytes),
    ),
  );
}

/// アップロード前に画像をトリミング・回転・モザイク・縮小するための画面。
///
/// 選んだ画像は必ずこの画面を通す。**何も触らずに「完了」を押せば、再エンコード
/// もせず元のバイト列がそのまま送られる**（見ただけで画質が落ちない）。編集せずに
/// 送るための専用ボタンは置いていない——「完了」と役割が重なるため。
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({
    super.key,
    required this.source,
    required this.bytes,
  });

  /// 選択された元ファイル。無編集のときはこれをそのまま返す。
  final XFile source;

  final Uint8List bytes;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _Tab { transform, mask, size }

/// マスクタブで指 1 本に割り当てる役割。
enum _MaskTool { mosaic, fill, move }

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  /// プレビューに使う画像の長辺の上限（px）。原寸で持つと 12MP の写真で
  /// 数十 MB になるため、表示用には落とす。出力は常に元のバイト列から作る。
  static const _previewLongSide = 1600;

  /// 隅のつまみに指が届いたと見なす距離（論理 px）。
  ///
  /// 見えているつまみ（腕 18px の角マーク）よりずっと大きく取る。指の腹は
  /// 40px 近くあり、見えている線をぴったり狙わせると掴み損ねるため。枠の外側
  /// からでもこの距離まで掴める。
  static const _handleTouchSlop = 44.0;

  /// 操作パネル（タブごとの中身）の高さ。3 タブで共通。
  static const _controlsHeight = 92.0;

  ui.Image? _image;
  ui.Image? _mosaic;
  String? _decodeError;

  ImageEdit _edit = const ImageEdit();
  _Tab _tab = _Tab.transform;
  MaskKind _maskKind = MaskKind.mosaic;

  /// 筆の太さ。元画像の長辺に対する割合。
  double _brush = 0.06;

  MaskStroke? _drawing;
  CropCorner? _dragCorner;
  bool _dragMoving = false;
  Offset _dragPointer = Offset.zero;

  bool _busy = false;

  /// 編集内容の版。書き出し結果が今の編集のものかを見分けるのに使う。
  int _editSeq = 0;

  /// 実際に書き出したバイト列と、その表示用画像。どの版のものかを [_outputSeq]
  /// で覚えておき、古くなったら捨てる。
  Uint8List? _outputBytes;
  ui.Image? _outputImage;
  int _outputSeq = -1;
  Timer? _renderDebounce;

  /// 書き出し結果がいまの編集に追いついているか。
  bool get _outputIsFresh => _outputSeq == _editSeq;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    _image?.dispose();
    _mosaic?.dispose();
    _outputImage?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final long = math.max(descriptor.width, descriptor.height);

      final previewCodec = await descriptor.instantiateCodec(
        targetWidth: long > _previewLongSide
            ? math.max(1, descriptor.width * _previewLongSide ~/ long)
            : null,
      );
      final preview = (await previewCodec.getNextFrame()).image;

      // モザイクのプレビューは、出力と同じブロック数まで縮めた画像を
      // 補間なしで引き伸ばして作る。
      final mosaicCodec = await descriptor.instantiateCodec(
        targetWidth: math.max(
          1,
          (mosaicBlocksOnLongSide * descriptor.width / long).round(),
        ),
      );
      final mosaic = (await mosaicCodec.getNextFrame()).image;
      descriptor.dispose();

      if (!mounted) {
        preview.dispose();
        mosaic.dispose();
        return;
      }
      setState(() {
        _image = preview;
        _mosaic = mosaic;
      });
    } catch (_) {
      if (mounted) setState(() => _decodeError = 'この画像は編集できません');
    }
  }

  Size get _sourceSize {
    final image = _image;
    return image == null
        ? Size.zero
        : Size(image.width.toDouble(), image.height.toDouble());
  }

  bool get _isPng => isPng(widget.bytes);

  bool get _isGif =>
      widget.bytes.length >= 3 &&
      widget.bytes[0] == 0x47 &&
      widget.bytes[1] == 0x49 &&
      widget.bytes[2] == 0x46;

  // ---- 書き出しプレビュー ----

  /// 出力タブでは、**実際にアップロードするバイト列そのもの**を作ってプレビュー
  /// に出す。解像度を落とした甘さも JPEG のブロックノイズも、こうしないと画面に
  /// 出ない（元画像を画面幅に合わせて描いているだけでは何も変わらない）。
  ///
  /// つまみを動かすたびに走らせると重いので、手が止まってから作る。
  void _scheduleOutputRender() {
    _renderDebounce?.cancel();
    if (_tab != _Tab.size || _image == null) return;
    if (_outputIsFresh) return;
    if (_edit.isIdentity) {
      // 無編集なら元のバイト列がそのまま出力になる。作り直す必要はない。
      setState(() {
        _outputImage?.dispose();
        _outputImage = null;
        _outputBytes = widget.bytes;
        _outputSeq = _editSeq;
      });
      return;
    }
    _renderDebounce = Timer(
      const Duration(milliseconds: 300),
      _renderOutputPreview,
    );
  }

  Future<void> _renderOutputPreview() async {
    final seq = _editSeq;
    try {
      final bytes = await applyImageEdit(widget.bytes, _edit);
      final image = await _decodeForPreview(bytes);
      if (!mounted || seq != _editSeq) {
        image.dispose();
        return;
      }
      setState(() {
        _outputImage?.dispose();
        _outputImage = image;
        _outputBytes = bytes;
        _outputSeq = seq;
      });
    } catch (_) {
      // 作れなかったときはプレビューを差し替えないだけ。送信時に改めて試みる。
    }
  }

  /// 画面に出す用にデコードする。原寸で持つ必要はないので長辺を抑える。
  Future<ui.Image> _decodeForPreview(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final long = math.max(descriptor.width, descriptor.height);
    final codec = await descriptor.instantiateCodec(
      targetWidth: long > _previewLongSide
          ? math.max(1, descriptor.width * _previewLongSide ~/ long)
          : null,
    );
    // フレームを取り出す前に descriptor を捨てるとデコードに失敗する。
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    return frame.image;
  }

  /// 書き出し結果の大きさ（例 `82 KB`）。まだ作れていなければ null。
  String? get _outputSizeLabel {
    final bytes = _outputBytes;
    if (bytes == null || !_outputIsFresh) return null;
    final kb = bytes.length / 1024;
    if (kb < 1000) return '${kb.round()} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  // ---- 決定 ----

  /// 無編集のまま返す。加工していないので、元のファイルをそのまま渡す。
  void _sendOriginal() => Navigator.of(context).pop(widget.source);

  Future<void> _sendEdited() async {
    if (_edit.isIdentity) {
      _sendOriginal();
      return;
    }
    setState(() => _busy = true);
    try {
      // 出力タブでプレビュー用に作ったものが今の編集のままなら、そのまま送る。
      final ready = _outputIsFresh ? _outputBytes : null;
      final bytes = ready ?? await applyImageEdit(widget.bytes, _edit);
      if (!mounted) return;
      final ext = editedExtension(widget.bytes);
      Navigator.of(context).pop(
        // path も渡す。端末側の XFile は name を path から作るので、これが無いと
        // アップロード時のファイル名から拡張子が落ちる。中身は bytes を使うので
        // 実在しないパスで構わない。
        XFile.fromData(
          bytes,
          name: 'image.$ext',
          path: 'image.$ext',
          mimeType: ext == 'png' ? 'image/png' : 'image/jpeg',
          length: bytes.length,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('画像を加工できませんでした: $e')));
    }
  }

  // ---- 操作 ----

  /// 編集内容を差し替える。書き出しプレビューの作り直しもここから起こす。
  void _applyEdit(ImageEdit next) {
    setState(() {
      _edit = next;
      _editSeq++;
    });
    _scheduleOutputRender();
  }

  void _rotate() {
    _resetZoom();
    _applyEdit(_edit.rotatedClockwise());
  }

  void _flip() {
    _resetZoom();
    _applyEdit(_edit.flipped());
  }

  void _resetTransform() {
    _resetZoom();
    _applyEdit(_edit.resetTransform());
  }

  void _undoStroke() {
    if (_edit.strokes.isEmpty) return;
    _applyEdit(
      _edit.copyWith(
        strokes: _edit.strokes.sublist(0, _edit.strokes.length - 1),
      ),
    );
  }

  void _clearStrokes() => _applyEdit(_edit.copyWith(strokes: []));

  // ---- 画面 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('画像を編集'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 8),
            child: FilledButton(
              key: const ValueKey('image-editor-done'),
              onPressed: _busy || _image == null ? null : _sendEdited,
              child: const Text('完了'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                // 拡大した絵はこの枠を越えて描かれるので、必ず切り取る。
                // 切らないと下の操作パネルの上にまで画像が乗る。
                child: ClipRect(
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: _preview(),
                  ),
                ),
              ),
              if (_isGif)
                _Notice(
                  text: 'GIF を編集すると、動かない画像になります。',
                  color: theme.colorScheme.tertiaryContainer,
                  textColor: theme.colorScheme.onTertiaryContainer,
                ),
              // 操作パネルは丸ごと別レイヤにする。Material のボタン類は
              // saveLayer → paintChild → restore を行うが、子がレイヤになると
              // save と restore が別のキャンバスに掛かって釣り合わず、同じ
              // ピクチャに描かれた**上のプレビュー**へラベルが漏れて二重に出る。
              SafeArea(
                top: false,
                child: RepaintBoundary(child: _controls(theme)),
              ),
            ],
          ),
          if (_busy)
            const ColoredBox(
              color: Colors.black45,
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _preview() {
    final error = _decodeError;
    if (error != null) return Center(child: Text(error));
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 余白は枠のつまみを外側から掴む余地でもある。既定のトリミング枠は
        // 画像の縁そのものなので、ここが狭いと当たり判定の外側半分が使えない。
        final view = (Offset.zero & constraints.biggest).deflate(24);
        final source = _sourceSize;
        final oriented = orientedSize(source, _edit.quarterTurns);

        // トリミング中は全体を見せ、それ以外は切り抜いた後の絵だけを見せる。
        final shown = _tab == _Tab.transform
            ? Offset.zero & oriented
            : Rect.fromLTRB(
                _edit.crop.left * oriented.width,
                _edit.crop.top * oriented.height,
                _edit.crop.right * oriented.width,
                _edit.crop.bottom * oriented.height,
              );
        // 画面に収めた矩形（拡大前）と、拡大・移動を掛けた後の矩形。
        final fitted = _fitted(shown.size, view);
        final dest = _zoomed(fitted);
        final orientedToView = _zoomMatrix() * _rectToRect(shown, fitted);
        final sourceToView =
            orientedToView *
            _orientMatrix(source, _edit.quarterTurns, _edit.flipHorizontal);

        final preview = Listener(
          onPointerDown: (_) => _pointers++,
          onPointerUp: (_) => _onPointerLifted(),
          onPointerCancel: (_) => _onPointerLifted(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 1 本指はそのタブの操作（枠のドラッグ・マスク描画）。2 本指は拡大と
            // 移動。出力タブは 1 本指でも移動できる（他に操作が無いため）。
            onScaleStart: (d) => _onScaleStart(d, orientedToView, sourceToView),
            onScaleUpdate: (d) => _onScaleUpdate(
              d,
              orientedToView,
              sourceToView,
              fitted,
              constraints.biggest,
            ),
            onScaleEnd: _onScaleEnd,
            // なぞっている間はここだけ描き直せばよい。独立したレイヤにしておくと、
            // 下の操作パネル（Chip などが saveLayer を挟む）と描画が混ざらない。
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('image-editor-preview'),
                size: Size.infinite,
                painter: _EditorPainter(
                  image: image,
                  // 出力タブでは、書き出し済みのものがあればそれを見せる。
                  // トリミングも回転もマスクも焼き込み済みなので、そのまま出す。
                  baked: _tab == _Tab.size && _outputIsFresh
                      ? _outputImage
                      : null,
                  mosaic: _mosaic,
                  source: source,
                  oriented: oriented,
                  dest: dest,
                  sourceToView: sourceToView,
                  orientedToView: orientedToView,
                  strokes: [..._edit.strokes, if (_drawing != null) _drawing!],
                  crop: _tab == _Tab.transform ? _edit.crop : null,
                ),
              ),
            ),
          ),
        );

        if (_tab != _Tab.size) return preview;
        return Stack(
          children: [
            Positioned.fill(child: preview),
            Positioned(
              left: 0,
              right: 0,
              // 絵に付いた注釈として読めるよう、画像のすぐ下に置く。画像が縦に
              // いっぱいのときは下端からはみ出さない位置まで戻す。
              top: math.min(dest.bottom + 8, constraints.maxHeight - 36),
              child: Center(child: _outputBadge(Theme.of(context))),
            ),
          ],
        );
      },
    );
  }

  /// プレビューの下に重ねる、出来上がりのファイルサイズ。
  ///
  /// 掲示板に貼るときは見た目の差より「何 KB になるか」で決めることが多いので、
  /// 絵と一緒に読める位置に置く。
  Widget _outputBadge(ThemeData theme) {
    final size = _outputSizeLabel;
    // 「◯◯ で送信」とは書かない。レスの投稿と読み違えるため、大きさだけ出す。
    final label = size ?? '書き出し中…';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          key: const ValueKey('image-editor-output-size'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onInverseSurface,
          ),
        ),
      ),
    );
  }

  // ---- 拡大・移動 ----

  /// 画面に収めた状態を 1 倍とした拡大率。
  double _zoom = 1;

  /// 拡大した絵を画面上でずらす量（画面 px）。
  Offset _pan = Offset.zero;

  double _gestureZoom = 1;
  Offset _gesturePan = Offset.zero;
  Offset _gestureFocal = Offset.zero;

  /// このジェスチャが拡大・移動か（＝タブの操作ではない）。
  bool _viewGesture = false;

  /// 一度でも 2 本指になったら、全部の指が離れるまで拡大・移動のままにする。
  /// ピンチの片方を先に離したときに、残った指で描き始めてしまうのを防ぐ。
  bool _viewLatched = false;

  /// 1 本指を「絵の移動」に使うか。拡大して隅を直したいときに、枠のドラッグや
  /// マスク描画と持ち替えずに済ませるためのトグル。
  bool _panMode = false;

  /// いま画面に着いている指の数。
  ///
  /// [ScaleGestureRecognizer] の end は指が減っても必ず来るとは限らないので
  /// （2 本目を離した時点では畳まれない）、解除の判断はこちらで数える。
  int _pointers = 0;

  Matrix4 _zoomMatrix() => Matrix4.identity()
    ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
    ..scaleByDouble(_zoom, _zoom, 1, 1);

  Rect _zoomed(Rect fitted) => MatrixUtils.transformRect(_zoomMatrix(), fitted);

  void _resetZoom() {
    if (_zoom == 1 && _pan == Offset.zero) return;
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  void _onScaleStart(
    ScaleStartDetails d,
    Matrix4 orientedToView,
    Matrix4 sourceToView,
  ) {
    _gestureZoom = _zoom;
    _gesturePan = _pan;
    _gestureFocal = d.localFocalPoint;
    // 出力タブには 1 本指の操作が無いので、そのまま移動に使える。
    _viewGesture =
        d.pointerCount >= 2 || _tab == _Tab.size || _panMode || _viewLatched;
    if (_viewGesture) {
      _viewLatched = true;
      return;
    }
    _onPanStart(d.localFocalPoint, orientedToView, sourceToView);
  }

  void _onScaleUpdate(
    ScaleUpdateDetails d,
    Matrix4 orientedToView,
    Matrix4 sourceToView,
    Rect fitted,
    Size viewport,
  ) {
    if (!_viewGesture) {
      _onPanUpdate(d.localFocalPoint, orientedToView, sourceToView);
      return;
    }

    final zoom = (_gestureZoom * d.scale).clamp(1.0, 8.0);
    // つまんだ点が指の下に留まるようにずらす。
    final focalInContent = (_gestureFocal - _gesturePan) / _gestureZoom;
    setState(() {
      _zoom = zoom;
      _pan = _clampPan(
        d.localFocalPoint - focalInContent * zoom,
        zoom,
        fitted,
        viewport,
      );
    });
  }

  void _onPointerLifted() {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) _viewLatched = false;
  }

  /// 1 本指の操作を、結果を残さずに取りやめる。
  void _cancelPanAction() {
    setState(() {
      _drawing = null;
      _dragCorner = null;
      _dragMoving = false;
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // **指が増えたときもここへ来る**（ScaleGestureRecognizer は指の増減で
    // 一度ジェスチャを畳んで開き直す）。つまむときは必ず片方の指が先に着くので、
    // その 1 本指ぶんを確定すると、つまんだ場所に点が残ってしまう。
    if (!_viewGesture) {
      if (d.pointerCount >= 2) {
        _cancelPanAction();
      } else {
        _onPanEnd();
      }
    }
    _viewGesture = false;
  }

  /// 絵が画面から出ていかないようにずらし量を抑える。画面より小さいうちは
  /// 中央に固定する（拡大していないのに動かせると、位置を見失う）。
  Offset _clampPan(Offset pan, double zoom, Rect fitted, Size viewport) {
    double axis(double value, double origin, double size, double extent) {
      if (size <= extent) return (extent - size) / 2 - origin;
      return value.clamp(extent - size - origin, -origin);
    }

    return Offset(
      axis(pan.dx, fitted.left * zoom, fitted.width * zoom, viewport.width),
      axis(pan.dy, fitted.top * zoom, fitted.height * zoom, viewport.height),
    );
  }

  void _onPanStart(Offset local, Matrix4 orientedToView, Matrix4 sourceToView) {
    if (_tab == _Tab.mask) {
      final p = _normalizedSource(local, sourceToView);
      setState(() {
        _drawing = MaskStroke(points: [p], width: _brush, kind: _maskKind);
      });
      return;
    }
    if (_tab != _Tab.transform) return;

    final cropView = _cropInView(orientedToView);
    final corners = {
      CropCorner.topLeft: cropView.topLeft,
      CropCorner.topRight: cropView.topRight,
      CropCorner.bottomLeft: cropView.bottomLeft,
      CropCorner.bottomRight: cropView.bottomRight,
    };
    // 枠が小さいときまで広く取ると、四隅の判定が枠の中で重なって「枠ごと動かす」
    // ができなくなる。短辺の 1/3 を上限にして、真ん中は必ず移動用に残す。
    final slop = math.min(
      _handleTouchSlop,
      math.min(cropView.width, cropView.height) / 3,
    );
    CropCorner? nearest;
    var best = slop;
    for (final entry in corners.entries) {
      final d = (entry.value - local).distance;
      if (d <= best) {
        best = d;
        nearest = entry.key;
      }
    }
    setState(() {
      _dragCorner = nearest;
      _dragMoving = nearest == null && cropView.contains(local);
      _dragPointer = local;
    });
  }

  void _onPanUpdate(
    Offset local,
    Matrix4 orientedToView,
    Matrix4 sourceToView,
  ) {
    if (_tab == _Tab.mask) {
      final drawing = _drawing;
      if (drawing == null) return;
      final p = _normalizedSource(local, sourceToView);
      // 筆の太さに対して十分動いたときだけ点を足す。点が増えすぎると
      // プレビューの合成が重くなる。
      final last = drawing.points.last;
      final long = math.max(_sourceSize.width, _sourceSize.height);
      final step = _brush / 4;
      if ((Offset(
            (p.dx - last.dx) * _sourceSize.width / long,
            (p.dy - last.dy) * _sourceSize.height / long,
          )).distance <
          step) {
        return;
      }
      setState(() {
        _drawing = MaskStroke(
          points: [...drawing.points, p],
          width: drawing.width,
          kind: drawing.kind,
        );
      });
      return;
    }
    if (_tab != _Tab.transform) return;

    final corner = _dragCorner;
    if (corner != null) {
      final p = _normalizedOriented(local, orientedToView);
      _applyEdit(_edit.copyWith(crop: resizeCrop(_edit.crop, corner, p)));
      return;
    }
    if (!_dragMoving) return;

    final from = _normalizedOriented(_dragPointer, orientedToView);
    final to = _normalizedOriented(local, orientedToView);
    setState(() => _dragPointer = local);
    _applyEdit(_edit.copyWith(crop: moveCrop(_edit.crop, to - from)));
  }

  void _onPanEnd() {
    final drawing = _drawing;
    setState(() {
      _drawing = null;
      _dragCorner = null;
      _dragMoving = false;
    });
    if (drawing != null) {
      _applyEdit(_edit.copyWith(strokes: [..._edit.strokes, drawing]));
    }
  }

  Rect _cropInView(Matrix4 orientedToView) {
    final oriented = orientedSize(_sourceSize, _edit.quarterTurns);
    return MatrixUtils.transformRect(
      orientedToView,
      Rect.fromLTRB(
        _edit.crop.left * oriented.width,
        _edit.crop.top * oriented.height,
        _edit.crop.right * oriented.width,
        _edit.crop.bottom * oriented.height,
      ),
    );
  }

  Offset _normalizedOriented(Offset local, Matrix4 orientedToView) {
    final oriented = orientedSize(_sourceSize, _edit.quarterTurns);
    final p = MatrixUtils.transformPoint(
      Matrix4.inverted(orientedToView),
      local,
    );
    return Offset(p.dx / oriented.width, p.dy / oriented.height);
  }

  Offset _normalizedSource(Offset local, Matrix4 sourceToView) {
    final p = MatrixUtils.transformPoint(Matrix4.inverted(sourceToView), local);
    return Offset(
      (p.dx / _sourceSize.width).clamp(0.0, 1.0),
      (p.dy / _sourceSize.height).clamp(0.0, 1.0),
    );
  }

  // ---- 操作パネル ----

  Widget _controls(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 高さは 3 タブとも同じにする。タブを変えるたびにプレビューの高さが
          // 変わると、見ている画像が上下に飛んでしまうため。
          //
          // タブごとに Key を分ける。3 つとも似た形の Row/Column なので、
          // 付けないと切り替えで前のタブの要素がそのまま作り替えられる。
          SizedBox(
            height: _controlsHeight,
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: switch (_tab) {
                _Tab.transform => _transformControls(theme),
                _Tab.mask => _maskControls(theme),
                _Tab.size => _sizeControls(theme),
              },
            ),
          ),
          const SizedBox(height: 8),
          _shrinkToFit(
            SegmentedButton<_Tab>(
              segments: const [
                ButtonSegment(
                  value: _Tab.transform,
                  icon: Icon(Icons.crop_rotate),
                  label: Text('変形'),
                ),
                ButtonSegment(
                  value: _Tab.mask,
                  icon: Icon(Icons.blur_on),
                  label: Text('マスク'),
                ),
                ButtonSegment(
                  value: _Tab.size,
                  icon: Icon(Icons.tune),
                  label: Text('出力'),
                ),
              ],
              selected: {_tab},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                // タブごとに見せる範囲（全体／切り抜き後）が変わるので拡大は戻す。
                _resetZoom();
                setState(() => _tab = s.first);
                _scheduleOutputRender();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _transformControls(ThemeData theme) {
    // 1 行に並べると狭い端末で溢れるので、マスク・出力タブと同じ 2 段にする。
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              // 指 1 本で何が起きるかを選ばせる。トリミングは枠を直接動かす
              // 操作でボタンを持たないので、こう並べて初めて「枠を触るのだ」と
              // 分かる。
              Flexible(
                child: _shrinkToFit(
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.crop),
                        label: Text('トリミング'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.pan_tool_outlined),
                        label: Text('移動'),
                      ),
                    ],
                    selected: {_panMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _panMode = s.first),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: '右に回転',
                onPressed: _rotate,
                icon: const Icon(Icons.rotate_90_degrees_cw),
              ),
              IconButton(
                tooltip: '左右反転',
                onPressed: _flip,
                icon: const Icon(Icons.flip),
              ),
              IconButton(
                tooltip: '変形を戻す',
                onPressed: _resetTransform,
                icon: const Icon(Icons.restart_alt),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 幅が足りないときだけ縮めて収める。連結ボタンは横に長くなりがちで、
  /// 狭い端末では溢れる（溢れると縞模様が出て操作できなくなる）。
  ///
  /// **Row の中で使うときは [Flexible] で包むこと。** Row は子に幅の上限を
  /// 渡さないので、そのままだと [FittedBox] が縮める判断をできない。
  Widget _shrinkToFit(Widget child) => RepaintBoundary(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: child,
    ),
  );

  Widget _maskControls(ThemeData theme) {
    // 「指 1 本で何をするか」は 1 つの軸なので、塗り方と移動を同じ連結ボタンに
    // 並べる。種別と移動で別々のトグルを置くと、狭い端末で横に入らない。
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              // Material のボタン類は saveLayer → paintChild → restore を行い、
              // 子がレイヤになると釣り合わずに上のプレビューへ絵が漏れる。
              // レイヤを分けておけば漏れない。
              Flexible(
                child: _shrinkToFit(
                  SegmentedButton<_MaskTool>(
                    segments: const [
                      ButtonSegment(
                        value: _MaskTool.mosaic,
                        icon: Icon(Icons.blur_on),
                        label: Text('モザイク'),
                      ),
                      ButtonSegment(
                        value: _MaskTool.fill,
                        icon: Icon(Icons.square),
                        label: Text('黒塗り'),
                      ),
                      ButtonSegment(
                        value: _MaskTool.move,
                        icon: Icon(Icons.pan_tool_outlined),
                        label: Text('移動'),
                      ),
                    ],
                    selected: {
                      if (_panMode)
                        _MaskTool.move
                      else if (_maskKind == MaskKind.mosaic)
                        _MaskTool.mosaic
                      else
                        _MaskTool.fill,
                    },
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() {
                      final tool = s.first;
                      _panMode = tool == _MaskTool.move;
                      if (tool == _MaskTool.mosaic) {
                        _maskKind = MaskKind.mosaic;
                      } else if (tool == _MaskTool.fill) {
                        _maskKind = MaskKind.fill;
                      }
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const Icon(Icons.brush, size: 18),
              Expanded(
                child: Slider(
                  value: _brush,
                  min: 0.02,
                  max: 0.25,
                  label: '太さ',
                  // 移動中は塗らないので、太さもいじれないことを示す。
                  onChanged: _panMode
                      ? null
                      : (v) => setState(() => _brush = v),
                ),
              ),
              IconButton(
                tooltip: '1 つ戻す',
                onPressed: _edit.strokes.isEmpty ? null : _undoStroke,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'すべて消す',
                onPressed: _edit.strokes.isEmpty ? null : _clearStrokes,
                icon: const Icon(Icons.layers_clear),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// いま選べる解像度の段階。小さいほうから並べ、右端が原寸。
  ///
  /// 元画像より大きい上限は何も起きない（拡大はしない）ので段階に含めない。
  /// 1200px の画像に「1920」の目盛りがあると、動かしても何も変わらない。
  List<_SizePreset> get _sizePresets {
    final full = editedPixelSize(
      _sourceSize,
      _edit.copyWith(clearMaxLongSide: true),
    );
    final long = math.max(full.width, full.height);
    return [
      for (final preset in _shrinkPresets)
        if (preset.value! < long) preset,
      const _SizePreset('原寸', null),
    ];
  }

  /// [_sizePresets] の中でいま選ばれている段階。
  ///
  /// トリミングで画像が小さくなり、選んでいた上限が効かなくなることがある
  /// （500px に切ってから「小 640」を見る等）。そのときの出力は原寸と同じなので、
  /// 右端＝原寸として示す。
  int get _sizeIndex {
    final presets = _sizePresets;
    final index = presets.indexWhere((p) => p.value == _edit.maxLongSide);
    return index < 0 ? presets.length - 1 : index;
  }

  /// [maxLongSide] を選んだときに出来上がる寸法（例 `1280×960`）。
  String _dimensionsFor(int? maxLongSide) {
    final size = editedPixelSize(
      _sourceSize,
      maxLongSide == null
          ? _edit.copyWith(clearMaxLongSide: true)
          : _edit.copyWith(maxLongSide: maxLongSide),
    );
    return '${size.width.toInt()}×${size.height.toInt()}';
  }

  Widget _sizeControls(ThemeData theme) {
    final presets = _sizePresets;
    final index = _sizeIndex;
    final preset = presets[index];

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 上限の px 値そのものは伝わりにくいので、大きさの度合いだけを目盛りに
        // 置き、選んだ段階で出来上がる解像度を右に出す。
        _sliderRow(
          theme,
          title: '解像度',
          value: '${preset.label} ${_dimensionsFor(preset.value)}',
          // 縮めようがない画像（既に一番小さい段階より小さい）ではつまみを
          // 動かせない。目盛りが 1 つしかないスライダーは作れないので空ける。
          slider: presets.length < 2
              ? const SizedBox.shrink()
              : Slider(
                  value: index.toDouble(),
                  max: (presets.length - 1).toDouble(),
                  divisions: presets.length - 1,
                  label: preset.label,
                  onChanged: (v) {
                    final picked = presets[v.round()];
                    _applyEdit(
                      picked.value == null
                          ? _edit.copyWith(clearMaxLongSide: true)
                          : _edit.copyWith(maxLongSide: picked.value),
                    );
                  },
                ),
        ),
        // PNG は可逆なので品質の指定が無い。行ごと消すと、前に見たスライダーが
        // 無くなった＝壊れた、と見えるので、無効なつまみとして残す。
        _sliderRow(
          theme,
          title: '品質',
          value: _isPng ? '設定不可' : '${_edit.jpegQuality}',
          slider: Slider(
            value: _edit.jpegQuality.toDouble(),
            min: 40,
            max: 100,
            divisions: 12,
            label: '${_edit.jpegQuality}',
            onChanged: _isPng
                ? null
                : (v) => _applyEdit(_edit.copyWith(jpegQuality: v.round())),
          ),
        ),
      ],
    );
  }

  /// 「見出し ─ つまみ ─ いまの値」の 1 行。2 つ並べたときに左右が揃うよう、
  /// 見出しと値の幅は固定にする。
  Widget _sliderRow(
    ThemeData theme, {
    required String title,
    required String value,
    required Widget slider,
  }) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(title, style: theme.textTheme.labelMedium),
          ),
          Expanded(child: slider),
          SizedBox(
            width: 108,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SizePreset {
  const _SizePreset(this.label, this.value);

  final String label;

  /// 長辺の上限（px）。null は原寸。
  final int? value;
}

/// 縮小の段階。長辺の上限で持ち（縦横どちらが長くても効く）、小さい順に並べる。
const _shrinkPresets = [
  _SizePreset('小', 640),
  _SizePreset('中', 1280),
  _SizePreset('大', 1920),
];

class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    required this.color,
    required this.textColor,
  });

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: textColor),
      ),
    );
  }
}

/// [src]（画像の座標）を [dst]（画面の座標）へ写す行列。
Matrix4 _rectToRect(Rect src, Rect dst) {
  return Matrix4.identity()
    ..translateByDouble(dst.left, dst.top, 0, 1)
    ..scaleByDouble(dst.width / src.width, dst.height / src.height, 1, 1)
    ..translateByDouble(-src.left, -src.top, 0, 1);
}

/// 元画像のピクセル座標 → 回転・反転後のピクセル座標。
Matrix4 _orientMatrix(Size source, int quarterTurns, bool flipHorizontal) {
  final m = Matrix4.identity();
  switch (quarterTurns % 4) {
    case 1:
      m.translateByDouble(source.height, 0, 0, 1);
      m.rotateZ(math.pi / 2);
    case 2:
      m.translateByDouble(source.width, source.height, 0, 1);
      m.rotateZ(math.pi);
    case 3:
      m.translateByDouble(0, source.width, 0, 1);
      m.rotateZ(3 * math.pi / 2);
  }
  if (flipHorizontal) {
    m.translateByDouble(source.width, 0, 0, 1);
    m.scaleByDouble(-1, 1, 1, 1);
  }
  return m;
}

/// [size] を [bounds] に収める最大の矩形（中央寄せ）。
Rect _fitted(Size size, Rect bounds) {
  if (size.isEmpty || bounds.isEmpty) return bounds;
  final scale = math.min(
    bounds.width / size.width,
    bounds.height / size.height,
  );
  final w = size.width * scale;
  final h = size.height * scale;
  return Rect.fromLTWH(
    bounds.left + (bounds.width - w) / 2,
    bounds.top + (bounds.height - h) / 2,
    w,
    h,
  );
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.image,
    required this.baked,
    required this.mosaic,
    required this.source,
    required this.oriented,
    required this.dest,
    required this.sourceToView,
    required this.orientedToView,
    required this.strokes,
    required this.crop,
  });

  final ui.Image image;

  /// 書き出し済みの画像。あるときは編集を焼き込んだこれをそのまま見せる。
  final ui.Image? baked;

  final ui.Image? mosaic;
  final Size source;
  final Size oriented;

  /// 画面のうち、いま見せている範囲（トリミング後の絵）が占める矩形。
  final Rect dest;

  final Matrix4 sourceToView;
  final Matrix4 orientedToView;
  final List<MaskStroke> strokes;

  /// トリミング枠（表示座標の 0..1）。null なら枠を描かない。
  final Rect? crop;

  @override
  void paint(Canvas canvas, Size size) {
    final output = baked;
    if (output != null) {
      canvas.drawImageRect(
        output,
        Offset.zero & Size(output.width.toDouble(), output.height.toDouble()),
        dest,
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }

    canvas.save();
    // トリミング中以外は切り抜いた後の絵だけを見せる。枠の外は描かない。
    canvas.clipRect(dest);
    canvas.transform(sourceToView.storage);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    _paintMasks(canvas);
    canvas.restore();

    final cropRect = crop;
    if (cropRect != null) _paintCrop(canvas, size, cropRect);
  }

  void _paintMasks(Canvas canvas) {
    if (strokes.isEmpty) return;
    final mosaicImage = mosaic;
    for (final stroke in strokes) {
      final path = _strokePath(stroke, source);
      if (stroke.kind == MaskKind.fill || mosaicImage == null) {
        canvas.drawPath(path, Paint()..color = Colors.black);
        continue;
      }
      canvas.save();
      canvas.clipPath(path);
      canvas.drawImageRect(
        mosaicImage,
        Offset.zero &
            Size(mosaicImage.width.toDouble(), mosaicImage.height.toDouble()),
        Offset.zero & source,
        Paint()..filterQuality = FilterQuality.none,
      );
      canvas.restore();
    }
  }

  void _paintCrop(Canvas canvas, Size size, Rect crop) {
    final rect = MatrixUtils.transformRect(
      orientedToView,
      Rect.fromLTRB(
        crop.left * oriented.width,
        crop.top * oriented.height,
        crop.right * oriented.width,
        crop.bottom * oriented.height,
      ),
    );

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(rect),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    final line = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(rect, line);
    for (var i = 1; i < 3; i++) {
      final dx = rect.left + rect.width * i / 3;
      final dy = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), line);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), line);
    }

    final handle = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const arm = 18.0;
    void corner(Offset o, double sx, double sy) {
      canvas.drawLine(o, o + Offset(arm * sx, 0), handle);
      canvas.drawLine(o, o + Offset(0, arm * sy), handle);
    }

    corner(rect.topLeft, 1, 1);
    corner(rect.topRight, -1, 1);
    corner(rect.bottomLeft, 1, -1);
    corner(rect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_EditorPainter old) =>
      old.image != image ||
      old.baked != baked ||
      old.dest != dest ||
      old.sourceToView != sourceToView ||
      old.orientedToView != orientedToView ||
      old.strokes != strokes ||
      old.crop != crop;
}

/// 筆跡を面（塗り／切り抜きに使うパス）にする。
///
/// 線を面に変える API が無いので、点の間を補間しながら円を並べて union する。
Path _strokePath(MaskStroke stroke, Size source) {
  final radius = math.max(
    1.0,
    stroke.width * math.max(source.width, source.height) / 2,
  );
  final points = [
    for (final p in stroke.points)
      Offset(p.dx * source.width, p.dy * source.height),
  ];
  final path = Path();
  if (points.length == 1) {
    path.addOval(Rect.fromCircle(center: points.first, radius: radius));
    return path;
  }
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    final steps = math.max(1, ((b - a).distance / (radius / 2)).ceil());
    for (var k = 0; k <= steps; k++) {
      path.addOval(
        Rect.fromCircle(center: Offset.lerp(a, b, k / steps)!, radius: radius),
      );
    }
  }
  return path;
}
