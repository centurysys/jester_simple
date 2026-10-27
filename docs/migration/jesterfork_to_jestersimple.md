# Jesterfork → Jester Simple 移行ガイド（Step 16現在）

対象：Nim 2.2.12、`--mm:orc`、Linuxの管理WebUI / 組み込みアプリ。
旧`jesterfork`の公開APIとStep 15までの`jestersimple`を比較したものであり、
**実際のアプリケーションの移植成功を保証するものではない**。

## 1. 基本移行

1. `import jesterfork`を`import jestersimple`へ変更する。
2. `jesterfork/...`の直接importを`jestersimple/...`へ変更する。
3. `.nimble`の依存名と、`jesterfork.nimble`への参照を更新する。
4. 使用するNimを2.2.12以上とし、`--mm:orc`でビルドする。
5. Linux専用であることを前提とし、`-d:useStdLib`を外す。
6. HTTP接続元、Host、Cookie、bodyサイズ等の検証強化で入力が拒否されるケースを確認する。

## 2. API互換性マトリクス

| 領域 | 状態 | 移行時の注意 |
| --- | --- | --- |
| `routes`、`router`、`register`、`initJester`、`serve` | 維持 | 同期・非同期matcherの差はStep 15で回帰検証済み |
| `get` / `post` 等、`before` / `after` / `error` | 維持 | 既存統合テストで使用。実アプリ特有のマクロ組合せは別途確認 |
| `resp`、`halt`、`pass`、`cond`、`redirect` | 維持 | 空本文4xx/5xxでカスタムerrorへ到達するよう統一 |
| `request.params`、`paramValuesAsSeq` | 意図的な挙動変更 | クエリ・フォーム値は正確に1回復号。不正な`%`は400 |
| `request.formData`、`MultiData` | API維持・入力厳格化 | multipart不正形式は400。重複フィールド名は最後の値 |
| `request.ip` / `request.secure` / `request.host` / `request.port` | 信頼境界を変更 | 通常は接続元を使用。転送ヘッダーは信頼済みプロキシのみ |
| `setHeader` / `setCookie` / `attachment` | API維持・検証厳格化 | CRLF、無効なCookie、曖昧な応答フレーミングを拒否 |
| `request.send`、`sendHeaders`、`enableRawMode` | 維持 | 同期raw送信にはキュー容量制限。大容量は`sendAsync`推奨 |
| `request.sendAsync` | 追加 | `await`で送信完了を待つAPI |
| `sendFile`、`staticDir` | 維持・実装変更 | 公開ディレクトリ内symlink禁止。Weak ETagへ変更 |
| `newSettings` | 引数追加 | 末尾に接続/ヘッダー/時間/プロキシ/公開URLの設定を追加 |
| `numThreads`、`startup` | 削除 | HTTPBeast専用設定だったため廃止 |
| `-d:useStdLib`、`httpbeastfork` | 削除 | `asyncdispatch` + 内部HTTP受信層のみ |
| Windows/macOS対応 | 削除 | Linux専用。非Linuxはコンパイル時にエラー |
| `reqMeth`、`parseUrlQuery` | 非推奨のまま維持 | 可能なら`reqMethod`などへ移行 |

## 3. 代表的なサーバー設定

- `bindAddr`を明示する。ローカル管理画面なら127.0.0.1で待受可能。
- `maxBody`をアプリケーションが受け取る最大ペイロードに合わせて設定する。
- `maxConnections` / `maxHeaderBytes` / `maxHeaderFields` / `headerTimeoutMs` /
  `bodyTimeoutMs` / `keepAliveTimeoutMs`はStep 6で追加された制限。
- リバースプロキシ利用時は`trustedProxies`に*実際に接続するプロキシIP/CIDRだけ*を指定し、
  プロキシ側でクライアントの`Forwarded` / `X-Forwarded-*`を消去・再設定する。
- 外部公開の絶対URLが必要なら`publicBaseUrl`を明示し、`allowedHosts`も検討する。
- 公開ディレクトリ内にsymlinkを作らず、更新はatomic renameを推奨する。

## 4. 意図的に変わったHTTP動作

- Content-Lengthの重複、Content-LengthとTransfer-Encodingの併記、不正chunkは拒否。
- chunkedでもbodyサイズ上限を適用。サイズ超過は413。
- 不正Host、ヘッダー、URIエンコード、multipartは原則400系で拒否。
- フレームワークが生成する未処理例外ページは内部メッセージを公開しない。
- ヘッダー、Cookie、Locationの値は送信前に検証する。
- 静的ファイルはGETとHEADに対応し、弱いETagによる304を使用する。
- 未実装：Range/If-Range（206）、chunk extension。これらを必要とするアプリは要評価。

## 5. 推奨する移植確認

`nimble test -y`に加え、次を実行する。

```sh
bash tests/integration/run_step16.sh
python3 tests/integration/run_step16_suite.py
```

`run_step16_suite.py`は全既存Stepを**別プロセスで順次実行**し、失敗しても次を実行して結果を収集する。
出力：`docs/modernization/step16-suite-results/REPORT.md`。
大規模なリグレッション試験は実機で行う。Step 17ではarmhf/Cortex-A5のRSS、FD、バイナリサイズ、性能を確認する。
