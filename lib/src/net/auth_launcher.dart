import 'package:url_launcher/url_launcher.dart';

/// 認証ページ（/auth-code）をどう開くかの抽象。
///
/// いまはシステムブラウザで開く（macOS/Android/iOS 共通で動く）。将来モバイルで
/// アプリ内 WebView にしたくなったら、この実装だけ差し替えればよい。書き込み・
/// 認証ロジック本体（edge_core / 画面）はこのインターフェースにしか依存しない。
abstract interface class AuthLauncher {
  /// 認証ページを開く。開けたら true。
  Future<bool> open(Uri url);
}

/// システムの既定ブラウザで開く実装。
class SystemBrowserLauncher implements AuthLauncher {
  const SystemBrowserLauncher();

  @override
  Future<bool> open(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}
