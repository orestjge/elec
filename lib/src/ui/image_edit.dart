import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 画像編集の内容。UI にもデコーダにも依存しない純粋なデータ。
///
/// 座標系は 2 つある。
/// - **元画像座標**: Exif の向きだけ正した、回転も反転もしていない画像を 0..1 に
///   正規化したもの。[strokes]（モザイク・塗りつぶし）はここに置く。
/// - **表示座標**: 元画像に [flipHorizontal] → [quarterTurns] を適用した後の画像を
///   0..1 に正規化したもの。[crop] はここに置く。
///
/// マスクを元画像座標に置いているのは、後から回転やトリミングをやり直しても
/// 隠した場所が中身からずれないようにするため。逆にトリミング枠は画面で見た
/// ままの矩形であってほしいので表示座標に置く。
class ImageEdit {
  const ImageEdit({
    this.crop = const Rect.fromLTRB(0, 0, 1, 1),
    this.quarterTurns = 0,
    this.flipHorizontal = false,
    this.strokes = const [],
    this.maxLongSide,
    this.jpegQuality = 90,
  });

  /// 表示座標でのトリミング枠。
  final Rect crop;

  /// 時計回りの 90 度回転数（0〜3）。
  final int quarterTurns;

  /// 左右反転。[quarterTurns] より先に適用する。
  final bool flipHorizontal;

  /// モザイク・塗りつぶしの筆跡（元画像座標）。
  final List<MaskStroke> strokes;

  /// 出力の長辺の上限（px）。null なら原寸のまま。
  final int? maxLongSide;

  /// JPEG で出すときの品質（1〜100）。PNG 入力では使わない。
  final int jpegQuality;

  /// 何も変えていない＝再エンコードせず元のバイト列をそのまま使える。
  bool get isIdentity =>
      crop == const Rect.fromLTRB(0, 0, 1, 1) &&
      quarterTurns == 0 &&
      !flipHorizontal &&
      strokes.isEmpty &&
      maxLongSide == null;

  ImageEdit copyWith({
    Rect? crop,
    int? quarterTurns,
    bool? flipHorizontal,
    List<MaskStroke>? strokes,
    int? maxLongSide,
    bool clearMaxLongSide = false,
    int? jpegQuality,
  }) {
    return ImageEdit(
      crop: crop ?? this.crop,
      quarterTurns: quarterTurns ?? this.quarterTurns,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      strokes: strokes ?? this.strokes,
      maxLongSide: clearMaxLongSide ? null : (maxLongSide ?? this.maxLongSide),
      jpegQuality: jpegQuality ?? this.jpegQuality,
    );
  }

  /// 表示を時計回りに 90 度回す。トリミング枠も一緒に回して、画像の中身に対する
  /// 位置が変わらないようにする。
  ImageEdit rotatedClockwise() {
    return copyWith(
      quarterTurns: (quarterTurns + 1) % 4,
      crop: rotateRectClockwise(crop),
    );
  }

  /// 表示を左右反転する。
  ///
  /// このクラスは「反転 → 回転」の順で持つので、既に回っている画像を後から
  /// 反転するには回転の向きを逆にして反転フラグを立て直す（`mirror∘rot(t)` は
  /// `rot(-t)∘mirror` と同じ）。
  ImageEdit flipped() {
    return copyWith(
      quarterTurns: (4 - quarterTurns) % 4,
      flipHorizontal: !flipHorizontal,
      crop: mirrorRect(crop),
    );
  }

  /// トリミング・回転・反転だけを初期状態へ戻す（マスクと出力設定は残す）。
  ImageEdit resetTransform() {
    return copyWith(
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      quarterTurns: 0,
      flipHorizontal: false,
    );
  }
}

/// マスクの種類。
enum MaskKind {
  /// ブロック状にぼかす。
  mosaic,

  /// 単色で塗りつぶす。
  fill,
}

/// 指でなぞった 1 本の筆跡。座標は元画像座標（0..1）。
class MaskStroke {
  const MaskStroke({
    required this.points,
    required this.width,
    required this.kind,
  });

  final List<Offset> points;

  /// 線の太さ。元画像の長辺に対する割合。
  final double width;

  final MaskKind kind;
}

/// 回転・反転後の画像サイズ。
Size orientedSize(Size source, int quarterTurns) {
  return quarterTurns.isEven ? source : Size(source.height, source.width);
}

/// 元画像座標 → 表示座標。
Offset orientedFromSource(
  Offset p, {
  required int quarterTurns,
  required bool flipHorizontal,
}) {
  var q = flipHorizontal ? Offset(1 - p.dx, p.dy) : p;
  for (var i = 0; i < quarterTurns % 4; i++) {
    q = Offset(1 - q.dy, q.dx);
  }
  return q;
}

/// 表示座標 → 元画像座標。[orientedFromSource] の逆。
Offset sourceFromOriented(
  Offset p, {
  required int quarterTurns,
  required bool flipHorizontal,
}) {
  var q = p;
  for (var i = 0; i < quarterTurns % 4; i++) {
    q = Offset(q.dy, 1 - q.dx);
  }
  return flipHorizontal ? Offset(1 - q.dx, q.dy) : q;
}

/// 正規化矩形を時計回りに 90 度回す。
Rect rotateRectClockwise(Rect r) =>
    Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right);

/// 正規化矩形を左右反転する。
Rect mirrorRect(Rect r) =>
    Rect.fromLTRB(1 - r.right, r.top, 1 - r.left, r.bottom);

/// トリミング枠の四隅。辺のドラッグは扱わない（隅だけでも足り、指で掴みやすい）。
enum CropCorner { topLeft, topRight, bottomLeft, bottomRight }

/// トリミング枠の最小の一辺（正規化）。これ以上小さくすると掴めなくなる。
const double minCropSide = 0.08;

/// 隅をドラッグしたときの新しい枠を返す。掴んだ隅の対角を固定して、指の位置まで
/// 広げる（縦横比は保たない。比の指定は持たせていない）。
Rect resizeCrop(Rect crop, CropCorner corner, Offset pointer) {
  final anchor = switch (corner) {
    CropCorner.topLeft => crop.bottomRight,
    CropCorner.topRight => crop.bottomLeft,
    CropCorner.bottomLeft => crop.topRight,
    CropCorner.bottomRight => crop.topLeft,
  };
  final p = Offset(pointer.dx.clamp(0.0, 1.0), pointer.dy.clamp(0.0, 1.0));

  // 掴んだ隅が対角のどちら側にいるかは隅ごとに決まっていて、指では変わらない。
  // 指の位置から決めると、対角を追い越したときに向きが裏返って枠が潰れる。
  final signX = switch (corner) {
    CropCorner.topRight || CropCorner.bottomRight => 1.0,
    CropCorner.topLeft || CropCorner.bottomLeft => -1.0,
  };
  final signY = switch (corner) {
    CropCorner.bottomLeft || CropCorner.bottomRight => 1.0,
    CropCorner.topLeft || CropCorner.topRight => -1.0,
  };

  // 対角から指までの距離（追い越したら負）。最小の一辺と画像の端で挟む。
  final roomX = signX > 0 ? 1 - anchor.dx : anchor.dx;
  final roomY = signY > 0 ? 1 - anchor.dy : anchor.dy;
  final w = ((p.dx - anchor.dx) * signX).clamp(
    minCropSide,
    math.max(minCropSide, roomX),
  );
  final h = ((p.dy - anchor.dy) * signY).clamp(
    minCropSide,
    math.max(minCropSide, roomY),
  );

  final x0 = anchor.dx + signX * w;
  final y0 = anchor.dy + signY * h;
  return Rect.fromLTRB(
    math.min(anchor.dx, x0),
    math.min(anchor.dy, y0),
    math.max(anchor.dx, x0),
    math.max(anchor.dy, y0),
  );
}

/// 枠全体を平行移動する。画像の外へは出さない。
Rect moveCrop(Rect crop, Offset delta) {
  final dx = delta.dx.clamp(-crop.left, 1 - crop.right);
  final dy = delta.dy.clamp(-crop.top, 1 - crop.bottom);
  return crop.shift(Offset(dx, dy));
}

/// 編集後に出来上がる画像のピクセルサイズ。
///
/// [source] は元画像のピクセルサイズ。回転・トリミング・長辺上限を順に効かせる。
Size editedPixelSize(Size source, ImageEdit edit) {
  final oriented = orientedSize(source, edit.quarterTurns);
  var w = math.max(1.0, (oriented.width * edit.crop.width).roundToDouble());
  var h = math.max(1.0, (oriented.height * edit.crop.height).roundToDouble());
  final max = edit.maxLongSide;
  if (max != null && math.max(w, h) > max) {
    final scale = max / math.max(w, h);
    w = math.max(1.0, (w * scale).roundToDouble());
    h = math.max(1.0, (h * scale).roundToDouble());
  }
  return Size(w, h);
}
