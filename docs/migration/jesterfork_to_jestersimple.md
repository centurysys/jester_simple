# Jesterfork → Jester Simple 移行ガイド

対象はLinux、Nim 2.2.12以降、`--mm:orc`を使用する管理WebUI・組み込みアプリケーション。
Jesterfork系APIとの互換性を中心に説明する。Jester Simpleのソースは現在`1.0.0`を宣言するが、
**既存アプリケーションの移植成功や正式なリリース判定を保証するものではない**。

## 基本移行

1. `import jesterfork`を`import jestersimple`へ変更する。
2. `jesterfork/...`の直接importを`jestersimple/...`へ変更する。
3. Nimble依存名を`jestersimple`へ変更する。リポジトリ名は`jester_simple`である点に注意。
4. Nim 2.2.12以降と`--mm:orc`でビルドする。
5. Linux専用であることを確認し、旧バックエンド選択`-d:useStdLib`は不要とする。
6. 以前は許可されていたHTTP入力が新しい検証で拒否されないか、テストと実運用の両方で確認する。

## API互換性

| 領域 | 状態 | 移行時の注意 |
| --- | --- | --- |
| `routes`、`router`、`register`、`initJester`、`serve` | 維持 | 同期/非同期matcherの動作は専用回帰テストで検証 |
| `get` / `post` 等、`before` / `after` / `error` | 維持 | 使用しているマクロの組合せは実アプリで確認 |
| `resp`、`halt`、`pass`、`cond`、`redirect` | 維持 | 空本文4xx/5xxのエラーハンドラー経路を統一 |
| `request.params`、`paramValuesAsSeq` | 挙動変更 | クエリ・フォーム値は1回だけ復号。無効な`%`は400 |
| `request.formData`、`MultiData` | API維持・検証強化 | 不正multipartは400。重複フィールド名は最後の値 |
| `request.ip` / `request.secure` / `request.host` / `request.port` | 信頼境界を変更 | 通常は接続元を使用。転送ヘッダーは信頼済みプロキシのみ |
| `setHeader` / `setCookie` / `attachment` | API維持・検証強化 | CRLF、無効Cookie、曖昧な応答フレーミングを拒否 |
| `request.send`、`sendHeaders`、`enableRawMode` | 維持 | 同期raw送信にはキュー容量制限あり |
| `request.sendAsync` | 追加 | `await`で書き込み完了・背圧を扱う |
| `sendFile`、`staticDir` | API維持・内部変更 | 公開ディレクトリ内symlink禁止。弱いETagへ変更 |
| `newSettings` | 引数追加 | 接続・ヘッダー・時間・プロキシ・公開URL設定を追加 |
| `numThreads`、`startup` | 削除 | HTTPBeast専用設定のため廃止 |
| `-d:useStdLib`、`httpbeastfork` | 廃止 | 単一の内部HTTP受信層を使用 |
| Windows/macOS | 非対応 | Linux以外はコンパイル時にエラー |
| `reqMeth`、`parseUrlQuery` | 互換目的で維持 | 新規コードでは推奨しない |

## 安全なサーバー設定

デフォルトの`bindAddr`は空であり、IPv4のワイルドカードアドレスで待受する。
ローカルの管理UIでは`bindAddr = "127.0.0.1"`などに制限し、外部公開する場合は
認証、アクセス制御、TLS終端を別途構成する。

- `maxBody`は対象機器が受信可能な最大ペイロードに合わせる。
- `maxConnections`、`maxHeaderBytes`、`maxHeaderFields`、`headerTimeoutMs`、
  `bodyTimeoutMs`、`keepAliveTimeoutMs`はCPU・メモリ制約に合わせて設定する。
- リバースプロキシ使用時は`trustedProxies`を実際の接続元だけに限定し、
  プロキシが外部入力の`Forwarded` / `X-Forwarded-*`を削除・再設定する。
- 絶対URLを生成するアプリでは`publicBaseUrl`や`allowedHosts`の設定を確認する。
- 公開ディレクトリ内symlinkは使用できない。ファイル更新はatomic renameを推奨する。

```nim
import jestersimple

settings:
  bindAddr = "127.0.0.1"
  maxBody = 1024 * 1024

routes:
  get "/health":
    resp "ok"
```

## HTTP動作の相違点

- Content-Lengthの重複/矛盾、Content-LengthとTransfer-Encodingの併記、不正chunkを拒否。
- chunkedにもbody上限を適用し、超過時は413。
- 不正Host、レスポンスヘッダー、URIエンコード、multipartを拒否。
- 未処理例外の内部メッセージやスタックトレースはデフォルトHTTPページに表示しない。
- 静的ファイルのGET/HEAD、弱いETagを利用した304に対応。
- ヘッダーと最初のファイル本文をまとめて送信し、小ファイルの遅延を抑制。
- 未対応：静的Range/If-Range (206)、chunk extension。
- LF-onlyのHTTP行終端を厳密に拒否することは保証しない。

## 移行確認

```sh
nimble test -y
bash tests/integration/run_step16.sh
python3 tests/integration/run_step16_suite.py
```

全体実行器は各ステージを別プロセスで順次実行し、失敗したステージも記録する。
実行結果は`docs/modernization/step16-suite-results/REPORT.md`へ生成されるが、
**このディレクトリはGit管理しない**。

代表する既存アプリケーションを1つ移植し、実際のarmhf/Cortex-A5等の環境で
RSS、FD、CPU、HTTPの正常系と異常系を確認することを推奨する。
