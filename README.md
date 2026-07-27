# elec

エッヂ（[bbs.eddibb.cc](https://bbs.eddibb.cc) / liveedge）や5ch系掲示板向けのAndroid向け掲示板ビューア。サイドロードを使用すればiOSからもインストール可能です。

## インストール（Android）

### APK を直接インストール（おすすめ）

1. [最新リリース](https://github.com/orestjge/elec/releases/latest)から APK をダウンロード。
   - `elec-vX.Y.Z-arm64-v8a.apk` … ほとんどの端末（おおむね 2017 年以降）
   - `elec-vX.Y.Z-universal.apk` … ↑が利用できない場合はこちら
2. APK を開いてインストール。初回は「提供元不明のアプリ」の許可を求められます。
3. 更新は新しい APK を上書きインストールするだけ（署名が同じなのでデータは保持されます）。

### Google Play クローズドテスト

Play ストアから自動更新したい場合はこちら。

1. [テスター用 Google グループ](https://groups.google.com/u/0/g/elec-beta/)に参加（Play で使っているアカウントと同じもので）。
2. [ストアページ](https://play.google.com/store/apps/details?id=io.github.orestjge.elec)を開いてインストール。

> 参加が反映されるまで時間がかかることがあります。ストアページが開けないときは少し待ってからお試しください。
> なお、参加したメールアドレスは開発者にのみ見えます（表示名は参加時に変更可能）。

## インストール（iPhone / iPad）

App Store では配布していません。**AltStore** または **SideStore** で IPA をサイドロードします。（SideStoreがおすすめ）

1. どちらかを端末にセットアップ（初回のみ）。
   - [AltStore](https://altstore.io) … Mac / Windows が必要
   - [SideStore](https://sidestore.io) … PC 不要、Wi-Fi のみで更新可
2. 「Sources」→「+」で次の URL を追加。
   ```
   https://raw.githubusercontent.com/orestjge/elec/altstore/source.json
   ```
3. ソース内の **Elec** を選んでインストール。更新も同じ画面から行えます。

> 無料の Apple ID では 7 日でアプリが失効し、同時にサイドロードできるのは 3 つまでです（AltStore / SideStore 共通の仕様）。
> IPA を直接入れたい場合は、[最新リリース](https://github.com/orestjge/elec/releases/latest)の `elec-vX.Y.Z.ipa` を開いてもインストールできます。

## 開発

Flutter 製です。プロトコルと Shift_JIS 処理は `packages/edge_core` / `packages/edge_sjis` に分離しています。

```sh
flutter pub get
flutter run
flutter test
(cd packages/edge_core && dart test)
(cd packages/edge_sjis && dart test)
```

画像アップロードの既定 Imgur Client ID をローカルビルドに入れる場合:

```sh
cp .env.example .env
# ELEC_DEFAULT_IMGUR_CLIENT_ID=... を編集
flutter run --dart-define-from-file=.env
```

`main` へマージすると GitHub Actions が署名済み APK をビルドし、Releases に公開します。Release ビルドで既定 Imgur Client ID を入れる場合は、GitHub Secrets に `ELEC_DEFAULT_IMGUR_CLIENT_ID` を登録します。
