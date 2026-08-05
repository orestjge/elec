import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// ID 文字列から決まる 5x5 の左右対称ドット絵（identicon）。
///
/// ID は英数字の羅列で、目で追うと「似た並びの別 ID」を取り違えやすい。絵にして
/// しまえば同一人物かどうかは形と色で一目で分かる。ID そのものを読みたい場面
/// （NG リストとの照合、必死チェッカー、コピー）はタップ後のシートに残してある。
///
/// ハッシュは ID 文字列だけから決まる純関数なので、同じ ID なら端末・起動を
/// またいでも必ず同じ絵になる。保存も通信もしない。
const idIconGridSize = 5;

/// 5x5 の各マスを塗るかどうか。row-major で長さ 25。
///
/// 左 3 列（15 マス）だけをハッシュから決め、右 2 列はその鏡像にする。左右対称に
/// すると小さいサイズでも「顔」や「紋章」として形が頭に残りやすい。
List<bool> idIconCells(String id) {
  final bits = _hash(id, 0);
  final cells = List<bool>.filled(idIconGridSize * idIconGridSize, false);
  var bit = 0;
  for (var col = 0; col < 3; col++) {
    for (var row = 0; row < idIconGridSize; row++) {
      final on = (bits >> bit) & 1 == 1;
      bit++;
      cells[row * idIconGridSize + col] = on;
      cells[row * idIconGridSize + (idIconGridSize - 1 - col)] = on;
    }
  }
  // 全消し・全塗りは絵にならない（3 万 2 千分の 2 で出る）。中央列を反転させて
  // 縦棒か二枚板にし、少なくとも形のあるものを出す。
  if (cells.every((on) => on == cells.first)) {
    for (var row = 0; row < idIconGridSize; row++) {
      final i = row * idIconGridSize + 2;
      cells[i] = !cells[i];
    }
  }
  return cells;
}

/// ID から決まる色。色相だけをハッシュで振り、彩度・明度はテーマに合わせて
/// 固定する。色相任せにすると暗いテーマで沈む色・明るいテーマで飛ぶ色が出て、
/// 「読めないアイコン」ができてしまうため。
Color idIconColor(String id, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // マス目とは別のシードでハッシュし直す。同じ値から色と形の両方を取ると、
  // 似た色のアイコンが似た形になりやすく、見分けの効きが落ちる。
  final hue = (_hash(id, 0x9e3779b9) % 360).toDouble();
  return HSLColor.fromAHSL(
    1,
    hue,
    dark ? 0.55 : 0.62,
    dark ? 0.68 : 0.42,
  ).toColor();
}

/// FNV-1a（32bit）。暗号強度は要らず、短い ID を撹拌できれば十分。
/// [seed] を変えると同じ文字列から独立した値を取れる。
int _hash(String value, int seed) {
  var h = (0x811c9dc5 ^ seed) & 0xffffffff;
  for (final unit in value.codeUnits) {
    h = ((h ^ (unit & 0xff)) * 0x01000193) & 0xffffffff;
    h = ((h ^ ((unit >> 8) & 0xff)) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// [id] から生成した identicon。文字を持たないので幅は [size] で固定。
class IdIcon extends StatelessWidget {
  const IdIcon({super.key, required this.id, this.size = 16});

  final String id;

  /// 一辺の長さ。5 で割ってマスの大きさにする。
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _IdIconPainter(
        cells: idIconCells(id),
        color: idIconColor(id, Theme.of(context).brightness),
      ),
    );
  }
}

/// ID を持たない板のレスに出す、identicon の代わりの目印。
///
/// ID が無ければ誰が書いたかは分からないので、**人物を示すものは出さない**。
/// レスの先頭がどこかを示すためだけの中立な枠で、押しても何も起きない。これが
/// 無いと、名無し・返信なしのレスはヘッダが時刻だけになり、どこからどこまでが
/// 1 つのレスなのか分かりにくくなる。
class IdIconPlaceholder extends StatelessWidget {
  const IdIconPlaceholder({super.key, this.size = 16});

  /// 一辺の長さ。[IdIcon] と揃える。
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      // 真っ白な枠は描画の失敗に見えるので、中央に短い横棒を置いて「ここは
      // 空である」と分かる形にする。
      child: SizedBox(
        width: size * 0.44,
        height: 1.5,
        child: ColoredBox(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _IdIconPainter extends CustomPainter {
  const _IdIconPainter({required this.cells, required this.color});

  final List<bool> cells;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.shortestSide * 0.22),
    );
    canvas.save();
    // 角を丸めた枠で切り抜く。マスは隙間なしのべた塗りで、境界だけ丸くなる。
    canvas.clipRRect(rrect);
    // 塗られていないマスも「地」として薄く色を敷く。全部透明だと、塗りの少ない
    // ID がレスの背景に溶けて何も無いように見えてしまう。
    canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: 0.16));
    final cell = size.width / idIconGridSize;
    final paint = Paint()..color = color;
    for (var row = 0; row < idIconGridSize; row++) {
      for (var col = 0; col < idIconGridSize; col++) {
        if (!cells[row * idIconGridSize + col]) continue;
        // 端のマスは 0.5 ぶん外へはみ出させる。割り切れない幅だとマスの継ぎ目に
        // 背景が透ける線が出るので、切り抜きに逃がして潰す。
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell + 0.5, cell + 0.5),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IdIconPainter old) =>
      old.color != color || !listEquals(old.cells, cells);
}
