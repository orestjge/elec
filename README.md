# elec

エッヂ（[bbs.eddibb.cc](https://bbs.eddibb.cc) / liveedge）を快適に読むための、非公式の Android 向け掲示板ビューアです。リアルタイム寄りの自動更新・モダンな UI・エッヂ特化が特徴です。

> 個人開発の非公式クライアントです。掲示板の運営とは無関係です。

## インストール（Android）

1. [最新リリース](https://github.com/orestjge/elec/releases/latest)から APK をダウンロードします。
   - **`elec-vX.Y.Z-arm64-v8a.apk`** … ほとんどの端末（おおむね2017年以降のスマホ）はこちら。
   - **`elec-vX.Y.Z-universal.apk`** … どちらか分からない場合はこちら（サイズは大きめ）。
2. ダウンロードした APK を開いてインストールします。
   - 初回は「提供元不明のアプリ／不明なアプリのインストール」の許可を求められます。端末の指示に従って許可してください。
3. 更新するときは、新しい APK を同じ手順で上書きインストールすればOKです（署名が同じなのでデータは保持されます）。

> Google Play では配布していません。APK の直接インストールになります。

## 開発

Flutter 製です。

```sh
flutter pub get
flutter run      # macOS デスクトップ / Android 実機・エミュレータなど
flutter test     # アプリのウィジェットテスト
```

プロトコルと Shift_JIS 処理は `packages/edge_core` / `packages/edge_sjis` に分離しています。

```sh
(cd packages/edge_core && dart test)
(cd packages/edge_sjis && dart test)
```

`main` へマージすると GitHub Actions が署名済み APK を自動ビルドし、Releases に公開します。
