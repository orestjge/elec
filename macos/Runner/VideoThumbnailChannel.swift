import AVFoundation
import Cocoa
import FlutterMacOS

/// mp4 等の先頭フレームを JPEG バイト列で返すメソッドチャンネル。
///
/// Android/iOS は video_thumbnail プラグインが担うが、同プラグインは macOS 非対応
/// なので、その iOS 実装と同じ AVAssetImageGenerator でこちらに用意する。faststart
/// ＋ Range 対応のホストなら先頭キーフレーム付近だけ読むので通信は軽い。
///
/// Dart 側は `lib/src/ui/video_thumbnail.dart`。
enum VideoThumbnailChannel {
  static let channelName = "elec/video_thumbnail"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "thumbnail" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let urlString = args["url"] as? String,
        let url = URL(string: urlString)
      else {
        result(nil)
        return
      }
      generate(
        url: url,
        maxWidth: args["maxWidth"] as? Int ?? 320,
        quality: args["quality"] as? Int ?? 60,
        result: result
      )
    }
  }

  /// 先頭フレームを非同期に取り出す。失敗（非対応コーデック・到達不可・削除済み）は
  /// nil を返し、Dart 側は再生カードにフォールバックする。
  private static func generate(
    url: URL, maxWidth: Int, quality: Int, result: @escaping FlutterResult
  ) {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // 長辺を maxWidth に収める。表示は 160pt の正方形なのでこれで足りる。
    generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)

    let time = CMTime(seconds: 0, preferredTimescale: 600)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
      _, image, _, status, _ in
      // ジェネレータを完了まで生かしておく（キャプチャで保持する）。
      _ = generator
      guard status == .succeeded, let image = image else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let jpeg = NSBitmapImageRep(cgImage: image).representation(
        using: .jpeg,
        properties: [.compressionFactor: NSNumber(value: Double(quality) / 100.0)]
      )
      // チャンネルの応答はメインスレッドから返す。
      DispatchQueue.main.async {
        result(jpeg.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }
}
