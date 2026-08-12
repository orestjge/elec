import 'package:elec/src/ui/video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final original = VideoThumbnails.generator;

  setUp(() {
    VideoThumbnails.clearCache();
    VideoThumbnails.debugTargetPlatform = TargetPlatform.android;
  });

  tearDown(() {
    VideoThumbnails.generator = original;
    VideoThumbnails.debugTargetPlatform = null;
    VideoThumbnails.clearCache();
  });

  test('生成したフレームを返す', () async {
    final frame = Uint8List.fromList([1, 2, 3]);
    VideoThumbnails.generator = (url) async => frame;

    final result = await VideoThumbnails.resolve(
      Uri.parse('https://x/movie.mp4'),
    );
    expect(result, frame);
  });

  test('成功結果はキャッシュし、2 回目は再生成しない', () async {
    var calls = 0;
    VideoThumbnails.generator = (url) async {
      calls++;
      return Uint8List.fromList([9]);
    };

    final url = Uri.parse('https://x/movie.mp4');
    await VideoThumbnails.resolve(url);
    await VideoThumbnails.resolve(url);
    expect(calls, 1);
  });

  test('失敗も覚えて、叩き直さない', () async {
    // resolve は build から呼ばれる＝スクロール中は毎フレーム通るので、取れなかった
    // 動画を再試行し続けると OS のデコーダを回し続けることになる。
    var calls = 0;
    VideoThumbnails.generator = (url) async {
      calls++;
      return null;
    };

    final url = Uri.parse('https://x/movie.mp4');
    await VideoThumbnails.resolve(url);
    await VideoThumbnails.resolve(url);
    await VideoThumbnails.resolve(url);
    expect(calls, 1);
    // 覚えているのは「取れなかった」なので、待たずに引く方でも出てこない。
    expect(VideoThumbnails.cached(url), isNull);
  });

  test('生成済みのフレームは cached で待たずに引ける', () async {
    final frame = Uint8List.fromList([4, 5, 6]);
    VideoThumbnails.generator = (url) async => frame;
    final url = Uri.parse('https://x/movie.mp4');

    // まだ生成していない間は空（呼び出し側は FutureBuilder で待つ）。
    expect(VideoThumbnails.cached(url), isNull);

    await VideoThumbnails.resolve(url);

    // 生成後は待たずに引ける。行を作り直しても無地のカードに戻らないのはこれ。
    expect(VideoThumbnails.cached(url), frame);
  });

  test('macOS も対応プラットフォーム（Runner のチャンネルで生成する）', () async {
    VideoThumbnails.debugTargetPlatform = TargetPlatform.macOS;
    final frame = Uint8List.fromList([7]);
    VideoThumbnails.generator = (url) async => frame;

    expect(VideoThumbnails.isSupported, isTrue);
    expect(await VideoThumbnails.resolve(Uri.parse('https://x/m.mp4')), frame);
  });

  test('非対応プラットフォームでは生成せず null', () async {
    VideoThumbnails.debugTargetPlatform = TargetPlatform.linux;
    var calls = 0;
    VideoThumbnails.generator = (url) async {
      calls++;
      return Uint8List.fromList([1]);
    };

    expect(VideoThumbnails.isSupported, isFalse);
    expect(await VideoThumbnails.resolve(Uri.parse('https://x/m.mp4')), isNull);
    expect(calls, 0);
  });
}
