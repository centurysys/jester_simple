# Jester Simple 初回リリース判定チェックリスト

状態：**未判定**。GitHubへのソース公開と正式リリース承認は別。
測定日・ターゲット・Git HEAD・参照ログを記入してからタグを確定する。

## テスト・性能・移植確認

- [ ] `nimble test -y`が現行HEADでPASS。ログ：
- [ ] Step 5〜15の回帰試験がすべてPASS。ログ：
- [ ] Step 16のDebug/Releaseが各23/23 PASS。ログ：
- [ ] `python3 tests/perf/test_step17_tools.py`がPASS。ログ：
- [ ] 静的小ファイル最適化後のStep 13/14/16回帰がPASS。ログ：
- [ ] amd64で`--mm:orc -d:release --opt:size`の性能・RSSを記録。パス：
- [ ] 対象がある場合arm64実機で測定。機種・結果：
- [ ] armhf/Cortex-A5実機で測定。CPU・RAM・結果：
- [ ] 旧Jesterforkとの比較条件・RPS退行の受け入れ判断を記録。結果：
- [ ] 代表管理WebUIを移植し、実機でHTTP正常系・異常系を確認。対象・結果：
- [ ] RSS・FD・CPU・バイナリサイズ・依存ライブラリを用途の上限と比較。結果：

## セキュリティと導入時の責任分界

- [ ] CL/TE、重複CL、chunked累積サイズ、不正chunkを拒否できる。
- [ ] 接続・ヘッダー・受信タイムアウトを対象機の負荷条件で確認。
- [ ] HTTPエラーに内部例外メッセージやスタックトレースが漏れない。
- [ ] ヘッダー、Set-Cookie、LocationにCRLF注入できない。
- [ ] Host/Forwardedの信頼設定と実際のプロキシ構成が一致している。
- [ ] malformed multipartでプロセス終了や情報漏洩が起きない。
- [ ] 静的ファイルのtraversal、symlink、パス置換競合への防御を確認。
- [ ] raw/大容量送信の途中切断後のFD回収と接続処理を確認。
- [ ] TLS、認証・認可、CSRF対策、ネットワークACLをアプリ・運用側で確保。

## 既知の制限

- Linuxのみ。Nim 2.2.12以降とORCを使用し、HTTPBeastは含めない。
- 既定では転送ヘッダーを信頼しない。必要な場合のみ`trustedProxies`を設定。
- `chunk extension`、静的`Range`/`If-Range`による206は未対応。
- LF-only行終端に関する厳密な拒否は保証していない。
- 静的公開ディレクトリ内のsymlinkは禁止。
- 認証・認可、セッション、CSRF、TLS終端はフレームワーク外。
- 回帰試験成功は第三者監査やファジングの代わりにはならない。

## 公開・バージョン管理

- [ ] [移行ガイド](../migration/jesterfork_to_jestersimple.md)と非互換変更を確認。
- [ ] [`README.md`](../../README.md)、[`CHANGELOG.md`](../../CHANGELOG.md)を確認。
- [ ] 旧Jester/Jesterforkの著作権表記と`license.txt`を保持。
- [ ] `jestersimple.nimble`と`jestersimple.nim`のバージョン一致を確認。
- [ ] 配布物に不要な測定ログ・ビルド済みバイナリ・秘密情報がない。
- [ ] GitHub Actionsは利用しない方針。ローカルの全回帰テスト結果を記録。
- [ ] 正式リリースに採用するバージョンとタグ名を確定。

**最終判定：** 未判定。責任者：＿＿＿＿　日付：＿＿＿＿

**未対応事項／受け入れ判断：**

- （証跡を記入）
