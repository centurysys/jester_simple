# Jester Simple — 初回リリース向け変更点（ドラフト）

リリース番号・日付は**未確定**。このファイルは既存`changelog.markdown`に
正式統合する前のレビュー用ドラフト。

## 基本構成

- 旧`jesterfork`から`jestersimple`へ改名。
- Linux専用。Nim 2.2.12以降とORCを基本要件とする。
- HTTPBeast依存と旧バックエンド切替、Windows/macOS分岐を削除。
- `std/asynchttpserver`を出発点とする内部HTTPトランスポートに一本化。

## HTTP受信と接続リソース

- Content-Lengthの重複／矛盾、CL+TE併記、不正チャンクを拒否。
- Content-Lengthとchunkedの両方にbodyサイズ上限を適用。
- 同時接続、ヘッダー容量・行数、ヘッダー/body/keep-alive受信期限を設定可能。
- Hostと信頼済みプロキシの取り扱いを明確化。

## APIとセキュリティ

- 未処理例外の内部情報漏洩を防止し、安全な標準エラーページを返す。
- レスポンスヘッダーとCookieの送信時検証、複数Set-Cookieを維持。
- Query/Formの二重デコードを廃止し、multipart解析を境界検証付きへ変更。
- raw送信のキュー・Future管理と同期/非同期送信を整理。
- 同期matcherのエラー経路を通常ディスパッチへ統一。

## 静的ファイル

- LinuxのFDと`openat`/`O_NOFOLLOW`で公開ディレクトリ外アクセスを抑止。
- ファイルを小ブロックで逐次送信し、HEADと304を整備。
- ETagを内容MD5からファイルメタデータ由来の弱いETagへ変更。
- `checksums`依存を除去。

## 互換性の注意

- 一部の旧入力は400/413、出力ヘッダー不正は500として拒否される。
- `Request.ip`、`Request.secure`、Host/絶対URL生成の既定の挙動が変わる。
- `numThreads`と`startup`は削除。旧`jesterfork` importの変更が必要。
- 静的ディレクトリ内symlink、chunk extension、Rangeは非対応。
- API詳細：`docs/migration/jesterfork_to_jestersimple.md`。

## 検証

Step 5〜16の回帰試験、およびStep 17のamd64/arm64/armhf実測結果を
リリース時に追記する。測定していないターゲットを検証済みとは書かない。
