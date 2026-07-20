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

  test('失敗（null）はキャッシュせず次回再試行する', () async {
    var calls = 0;
    VideoThumbnails.generator = (url) async {
      calls++;
      return null;
    };

    final url = Uri.parse('https://x/movie.mp4');
    await VideoThumbnails.resolve(url);
    await VideoThumbnails.resolve(url);
    expect(calls, 2);
  });

  test('非対応プラットフォームでは生成せず null', () async {
    VideoThumbnails.debugTargetPlatform = TargetPlatform.macOS;
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
