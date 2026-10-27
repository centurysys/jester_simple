# Jester Simple — 初回リリース変更点の概要

Jesterforkを基点にJester Simpleへ統合した変更を説明する。
GitHub上へのソース公開と、バージョンタグを付けた正式リリースの判定は別とする。
現在のソースはバージョン`1.0.0`を宣言しているが、リリース日とタグはここでは確定しない。
短い変更履歴は[`CHANGELOG.md`](../../CHANGELOG.md)を参照。

## 構成・対応環境

- モジュールを`jestersimple`へ改名。Linux専用、Nim 2.2.12以降、ORCを前提とする。
- HTTPBeast依存と旧バックエンド切替、Windows/macOS向け経路を撤去。
- 非同期HTTP受信は`asyncdispatch`ベースの内部トランスポートへ統一。

## HTTP受信と接続リソース

- 重複/矛盾するContent-Length、CL/TEの併記、不正chunkを拒否。
- Content-Lengthとchunkedの両方にbodyサイズ上限を適用。
- 同時接続、ヘッダー容量と項目数、受信期限、keep-alive期限を設定可能。
- HostとForwarded系ヘッダーの信頼境界を明確化。

## APIとセキュリティ

- 未処理例外の内部情報を標準エラーページへ出力しない。
- レスポンスヘッダー・Cookieの検証と複数Set-Cookie出力を整備。
- Query/Formの二重デコードをなくし、multipart解析の境界検査を強化。
- raw送信をキューとFutureで管理。await可能な`sendAsync`を追加。
- 同期matcherのエラー処理を通常ディスパッチと整合させた。

## 静的ファイル

- Linux FDによる`openat` / `O_NOFOLLOW`ベースの公開範囲制御。
- チェック済みFDを閉じるまで保持して転送し、パス置換競合を回避。
- 16KiB単位のストリーミング、GET/HEAD、ETag/304に対応。
- ファイルメタデータから弱いETagを生成し、MD5毎回計算と`checksums`依存を撤去。
- HTTPヘッダーと最初の本文チャンクを同時送信し、静的小ファイルの
  Nagle/Delayed ACKによる著しい遅延を改善。

## 性能観測の位置づけ

x86_64の同一ホストで旧版と比較したローカル逐次HTTP測定では、静的小ファイル配信が
約14,133 RPSから約16,015 RPSへ改善し、全測定経路のピークRSSが約78,044 KiBから
約2,856 KiBへ低下した。これはユーザー環境の**特定の測定結果**であり、
最大同時接続性能やarmhf実機での性能を保証しない。通常GET/POSTの性能は
旧版より低下する測定値もあり、実機条件での確認が必要。

## 互換性と残課題

- import名、HTTPBeast専用設定、入力検証、転送ヘッダー、ETagに互換性変更がある。
- 静的ディレクトリ内symlink、chunk extension、静的Range/If-Rangeは非対応。
- Nimコンパイラが新しくなる場合、あるいは別の組み込みボードへ移す場合は再検証が必要。
- API詳細は[移行ガイド](../migration/jesterfork_to_jestersimple.md)を参照。

## 検証

Step 5〜16の回帰テスト、NimbleのコアテストとStep 17の計測ツールを維持している。
正式リリース前に現行HEADで総合回帰試験を実行し、
[リリースチェックリスト](RELEASE_CHECKLIST.md)に結果を記録する。
