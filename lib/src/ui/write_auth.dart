import 'package:edge_core/edge_core.dart';
import 'package:flutter/material.dart';

import '../net/auth_launcher.dart';

/// 書き込み（レス・スレ立て）の共通フロー。1 回 POST してみて、未認証なら認証
/// ダイアログを出し、認証後の再送まで面倒を見る。受理されたら [PostAccepted]
/// （レス番号を含みうる）を、受理されなければ null を返す。
///
/// [postOnce] は「1 回 POST してトークンを更新し結果を返す」処理（UI 副作用なし）。
/// レス書き込みもスレ立ても、この中身だけ差し替えて共用する。
Future<PostAccepted?> submitWithAuth({
  required BuildContext context,
  required AuthLauncher launcher,
  required Future<BbsCgiResult> Function() postOnce,
  ValueChanged<String>? onRejected,
  String? Function()? diagnostics,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await postOnce();
  switch (outcome) {
    case PostAccepted():
      return outcome;
    case PostRejected(:final message):
      final text = message.isEmpty ? '書き込めませんでした' : message;
      if (onRejected == null) {
        messenger.showSnackBar(SnackBar(content: Text(text)));
      } else {
        onRejected(text);
      }
      return null;
    case PostNeedsAuth(:final authCode, :final authUrl):
      if (!context.mounted) return null;
      return showDialog<PostAccepted>(
        context: context,
        builder: (_) => AuthDialog(
          initialCode: authCode,
          onOpen: () => launcher.open(authUrl),
          onRetry: postOnce,
          diagnostics: diagnostics,
        ),
      );
  }
}

/// 認証ダイアログに出す切り分け診断。**保存済みの edge-token があるのに
/// `Unauthenticated` を受けた「異常時」だけ**文字列を返す（通常の初回認証では
/// null）。外で再認証を求められる不具合の原因（Cookie を送っていないのか／
/// サーバがトークンを無視して新規発行したのか／IP 版）を、その場で読めるように
/// する。判明したら丸ごと消してよい。
String? buildAuthDiagnostics(AuthTokens before, WriteResult result) {
  if (result.outcome is! PostNeedsAuth || !before.hasEdgeToken) return null;
  final rotated = before.edgeToken != result.tokens.edgeToken;
  final ipv = result.remoteIpVersion ?? '不明';
  return '診断: Cookie送信=あり / 応答=${result.statusCode} / '
      'サーバ新token=${rotated ? '回転あり' : 'なし'} / 経路=$ipv';
}

/// 未認証時に出す認証ダイアログ。6 桁コードを見せ、ブラウザで開かせ、認証後の
/// 再送を扱う。
///
/// コードには約 5 分の有効期限がある。期限切れでサーバが新しいコードを発行し
/// たら（再送の結果に新コードが載る）、表示を更新する。
class AuthDialog extends StatefulWidget {
  const AuthDialog({
    super.key,
    required this.initialCode,
    required this.onOpen,
    required this.onRetry,
    this.diagnostics,
  });

  final String initialCode;
  final Future<bool> Function() onOpen;

  /// 認証後の再送。最新の結果を返す（コードが更新されていれば反映する）。
  final Future<BbsCgiResult> Function() onRetry;

  /// 切り分け診断の文字列を返すフック（[buildAuthDiagnostics]）。異常時のみ
  /// 非 null。再送のたびに最新値を読み直せるよう、値でなく getter で受ける。
  final String? Function()? diagnostics;

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  late String _code = widget.initialCode;
  bool _busy = false;
  String? _message;

  Future<void> _open() async {
    setState(() => _busy = true);
    final ok = await widget.onOpen();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _message = 'ブラウザを開けませんでした';
    });
  }

  Future<void> _retry() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.onRetry();
    if (!mounted) return;
    switch (result) {
      case PostAccepted():
        Navigator.of(context).pop(result);
      case PostNeedsAuth(:final authCode):
        setState(() {
          _busy = false;
          final changed = authCode != _code;
          _code = authCode; // 期限切れで新コードになっていれば更新
          _message = changed
              ? 'コードの期限が切れたため新しいコードに更新しました。もう一度ブラウザで認証してください。'
              : 'まだ認証が確認できません。ブラウザで認証を完了してから押してください。';
        });
      case PostRejected(:final message):
        setState(() {
          _busy = false;
          _message = message.isEmpty ? '書き込めませんでした' : message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('認証が必要です'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ブラウザで認証ページを開き、下のコードを入力して認証してください。'),
          const SizedBox(height: 16),
          Center(
            child: SelectableText(
              _code,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '※ コードの有効期限は約 5 分です。同じ端末・同じ回線で認証してください。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('認証ページを開く'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (widget.diagnostics?.call() case final diag?) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                diag,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [],
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              '※ トークンがあるのに認証を求められた異常時の診断です。'
              'この内容をコピーして共有してください。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _busy ? null : _retry,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('認証したので投稿'),
        ),
      ],
    );
  }
}
