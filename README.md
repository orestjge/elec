# elec

エッヂ（[bbs.eddibb.cc](https://bbs.eddibb.cc) / liveedge）を快適に読むための、非公式の Android / iPhone 向け掲示板ビューアです。リアルタイム寄りの自動更新・モダンな UI・エッヂ特化が特徴です。

> 個人開発の非公式クライアントです。掲示板の運営とは無関係です。

## インストール（Android）

1. [最新リリース](https://github.com/orestjge/elec/releases/latest)から APK をダウンロードします。
   - **`elec-vX.Y.Z-arm64-v8a.apk`** … ほとんどの端末（おおむね2017年以降のスマホ）はこちら。
   - **`elec-vX.Y.Z-universal.apk`** … どちらか分からない場合はこちら（サイズは大きめ）。
2. ダウンロードした APK を開いてインストールします。
   - 初回は「提供元不明のアプリ／不明なアプリのインストール」の許可を求められます。端末の指示に従って許可してください。
3. 更新するときは、新しい APK を同じ手順で上書きインストールすればOKです（署名が同じなのでデータは保持されます）。

> Google Play では配布していません。APK の直接インストールになります。

## インストール（iPhone / iPad）

App Store では配布していません。**AltStore** または **SideStore** を使って、無署名の IPA を自分の Apple ID でサイドロードします。

### 事前準備

まず AltStore か SideStore のどちらかを端末にセットアップしておきます（初回のみ）。

- **AltStore**（Mac / Windows が必要）… PC に AltServer をインストールし、iPhone に AltStore を導入します。→ [公式手順](https://altstore.io)
- **SideStore**（PC 不要・Wi-Fi のみで更新できる）… → [公式手順](https://sidestore.io)

無料の Apple ID でサイドロードする場合の制約（AltStore/SideStore 共通の仕様）:
- インストールしたアプリは **7日で失効** します。AltStore/SideStore で定期的に再署名（更新）が必要です。
- 同時にサイドロードできるアプリは **3つまで**。

### ソースを追加してインストール

1. AltStore / SideStore の **「Sources」→「+」** を開きます。
2. 次の URL を追加します。
   ```
   https://raw.githubusercontent.com/orestjge/elec/altstore/source.json
   ```
3. 追加したソースの中から **Elec** を選び、**GET / インストール** します。
4. 更新版が出たら、同じく AltStore / SideStore 上から更新できます。

> IPA を直接入れたい場合は、[最新リリース](https://github.com/orestjge/elec/releases/latest)の **`elec-vX.Y.Z.ipa`** を AltStore / SideStore で開いてもインストールできます。

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
