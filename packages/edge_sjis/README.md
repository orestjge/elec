# edge_sjis

エッヂ (eddist) / 5ch 互換掲示板のワイヤフォーマットである **Windows-31J (CP932)** のエンコード・デコード。Flutter 非依存の純 Dart。

`dart:convert` は utf8 / latin1 / ascii しか持たない。一方エッヂはプロトコル全体が Shift_JIS（`subject.txt`、`dat`、`SETTING.TXT`、`bbs.cgi` のボディ）なので、この層は避けて通れない。

```dart
final lines = splitDatLines(datBytes);        // LF 分割 (完全な行のみ)
final text  = decodeSjis(lines.first);        // 表示用デコード
final body  = encodeFormBody({                // bbs.cgi のボディ
  'submit': '書き込む', 'MESSAGE': '本文',
  'bbs': 'liveedge', 'key': '1749045135',
});
```

## なぜ `charset` ではなく `jis0208` なのか

**`charset` パッケージを使ってはいけない。** 一見よさそう（純 Dart、110k downloads/月）だが、**JIS X 0208 の変換表**を使っており、ブラウザ・サーバが使う **CP932** と挙動が食い違う。実測した差分:

| 文字 | `charset` | `jis0208` (Windows-31J) | ブラウザの実際 |
| --- | --- | --- | --- |
| `〜` U+301C | `81 60` | 表現不能 → `&#12316;` | 表現不能 → `&#12316;` |
| `～` U+FF5E | **表現不能** | `81 60` | `81 60` |
| `①` U+2460 | **表現不能** | `87 40` | `87 40` |

`charset` を採用すると次の 3 つが起きる。

1. **`①` が書き込めない。** 5ch では致命的。
2. **既存レスの引用が壊れる。** `0x8160` をデコードすると `～`(U+FF5E) を返すのに、その `～` を再エンコードできず `FFFD` になる。デコードとエンコードの表が非対称。
3. **切断されたバイト列で `RangeError` を投げる。** `input[++i]` に境界チェックが無い（設計されたエラーではなく実装バグ）。Range 差分取得では末尾が文字の途中で切れるのが常態なので、本番でクラッシュする。

`jis0208` は Windows-31J = CP932 実装で、上記すべてをブラウザと同じ挙動で処理する。切断入力に対しても catch 可能な `FormatException` を投げる。

検証の根拠は `../edge-sender`（実際にエッヂへ書き込みが通っている Python スクリプト）の payload との**バイト単位での照合**。`書き込む` → `%8F%91%82%AB%8D%9E%82%DE` まで一致することを確認済み。この照合は `test/edge_sjis_test.dart` に golden test として残してある。**ここが壊れたら書き込みは通らないと考えてよい。**

## 落とし穴

### エンコード失敗は無警告
`Windows31JCodec.encode()` は、CP932 で表現できない文字（`〜`、絵文字など）を**例外も出さずに `?` (0x3F) に置き換える**。

**`encode()` を直接呼ぶ箇所を作らないこと。** 必ず `encodeFormValue()` を通す。この関数が 0x3F を検出して数値文字参照 `&#NNNNN;` にフォールバックする。これはブラウザのフォーム送信の挙動そのもの（`edge-sender` の payload にも `〜` が `&#12316;` として現れている）。

### Range 差分取得ではチャンクを個別にデコードしない
Range の切れ目はマルチバイト文字の途中に平気で落ちる。**バイト列のまま結合し、`splitDatLines()` で分割してから**デコードすること。

LF 分割が安全な理由: Windows-31J の trail byte は `0x40-0x7E` / `0x80-0xFC` で、**`0x0A` はどちらの範囲にも入らない**。つまり文字の途中に LF は現れない。

### HTML エスケープはサーバの責務
`eddist-server/src/domain/utils.rs` の `sanitize_base` が `< > " '` をエスケープし、`\r` を削除し、`\n` を `<br>` に変換する。**クライアント側で事前にエスケープしてはいけない**（二重エスケープになる）。

### `Uri.encodeComponent` は使えない
UTF-8 固定のため。SJIS バイト列から手でパーセントエンコードする必要がある。

## テスト

```sh
dart test
```

Flutter 非依存なので実機もエミュレータも不要。
