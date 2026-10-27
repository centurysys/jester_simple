# Step 17 — 組み込み性能測定・初回リリース判定

## 目的

Step 0〜16のセキュリティ改修を維持しつつ、Jester SimpleがLinux amd64/arm64/armhfで
再現可能に動作し、組み込み管理WebUIとして許容できるメモリ・FD・CPU・応答性能・
バイナリサイズに収まるか判定する。**本Stepではフレームワーク本体を変更しない。**

Step 16までの回帰試験が通過したことは前提だが、リリース可否を自動的に保証しない。

## 配置ファイル

| PATH | 内容 |
| --- | --- |
| `tests/perf/step17_app.nim` | 同一ルートを旧Jesterfork／新Jester Simpleでビルドする測定アプリ |
| `tests/perf/step17_probe.py` | Python標準ライブラリの逐次HTTP測定器 |
| `tests/perf/compare_step17.py` | 同条件の旧版／新版を比較する集計器 |
| `tests/perf/run_step17.sh` | ビルド・起動・測定・結果保存・安全な後片付け |
| `tests/perf/test_step17_tools.py` | 測定器の単体テスト |
| `docs/performance/step17.md` | 本書 |
| `docs/release/RELEASE_CHECKLIST.md` | 残課題とGo/No-Go判定 |
| `docs/release/CHANGES_FOR_INITIAL_RELEASE.md` | 変更点ドラフト |
| `readme.markdown` | 初回公開用の概要・前提条件・ドキュメント導線 |
| `.github/workflows/main.yml` | 測定器自身の単体テストをCIへ追加 |

## 前提条件

Linux、Nim 2.2.12以上、`--mm:orc`、Cコンパイラ、`python3`、`bash`。
新旧比較には旧Jesterforkの**ソースディレクトリ**が別に必要。
`wrk`は必須ではない。通信はすべて`127.0.0.1:5517`、固定テスト入力のみ。
起動するサーバは各比較で順次1個。外部公開しない。

## 実行手順

### 1. 測定器の単体テスト

```sh
python3 tests/perf/test_step17_tools.py
```

### 2. Jester Simpleのみで実機測定

```sh
bash tests/perf/run_step17.sh docs/performance/step17-amd64
```

arm64/armhfでは同じソースを展開して、出力先を分ける。

```sh
bash tests/perf/run_step17.sh docs/performance/step17-arm64
bash tests/perf/run_step17.sh docs/performance/step17-armhf
```

32bit ARM環境で明示的なctime型が必要なビルドの場合のみ、現行プロジェクトの
検証済み設定を使って次のように実行する。

```sh
STEP17_NIM_EXTRA_FLAGS='-d:nimUse64BitCTime' \
  bash tests/perf/run_step17.sh docs/performance/step17-armhf
```

`STEP17_NIM_EXTRA_FLAGS`は空白区切りでNimに渡す追加フラグ。
**旧版・新版の両方に同じフラグ**を指定する。

### 3. 旧Jesterforkとの同条件比較

旧版のパスは、`jesterfork.nim`が存在する旧ソースのトップディレクトリ。

```sh
bash tests/perf/run_step17.sh \
  docs/performance/step17-paired /path/to/legacy-jesterfork
```

旧版には`-d:step17Legacy -d:useStdLib`を追加し、標準`asynchttpserver`同士で比較する。
両者は`--mm:orc -d:release --opt:size`でビルドする。
HTTPBeastとの比較は別作業であり、今回の比較値に混在させない。

旧版のGit履歴が現行リポジトリにある場合、`git worktree add --detach`
で別ディレクトリを作成できる。変更前のソースを別途保管している場合はそれを利用する。
旧版はNim 2.2.12でコンパイル可能であることを最初に確認する。

### 4. 全セキュリティ回帰試験

```sh
nimble test -y
python3 tests/integration/run_step16_suite.py
```

結果は`docs/modernization/step16-suite-results/REPORT.md`で確認する。
失敗ステージがあればStep 17の計測が成功していてもリリースを承認しない。

## 測定値と解釈

- `current/RESULTS.json`・`REPORT.md`：ルートごとに3回の反復測定。
- 旧版を指定したときのみ`legacy/RESULTS.json`と`COMPARISON.md`を生成。
- `environment.txt`：Nim/CPU/Kernel/HEADとコンパイラ条件。
- `current/build.log`、`current/server.log`：失敗時の診断。
- `current/binary-sections.txt`、`current/dynamic-libraries.txt`：実行ファイルと動的依存。
- `current/startup.txt`：秒単位の概略起動待機時間（高精度測定ではない）。

計測対象はGET plain/json/query、POST echo、静的小ファイル、2MiB、32MiB。
最初に1000 GETの完走とFD/RSS回収を観測する。その後各ルートを繰り返し、
HTTPステータスと本文またはSHA-256が一致した要求だけを測定する。
`maxBody`のようなセキュリティ設定は測定用に緩めない。

**注意：** Pythonの`http.client`はクライアント側で逐次要求を送り、Pythonの
処理・ローカルTCPの遅延を含む。RPSはサーバの上限性能ではなく、相対指標。
特にCortex-A5上でクライアントを同居させると、そのCPU消費も結果に影響する。
本格的なRPS/p99と同時接続性能の判定には、同一LAN上の専用負荷クライアントと
`wrk`等を用い、ルート・スレッド/接続数・バージョン・結果を別途記録する。
保護された検証ネットワークでのみ実施し、本番サービスに負荷をかけない。

同一条件でない他アーキテクチャ・他コンパイラのRPSを単純な性能改善率として比較しない。
過去Step 0のRSS（amd64で起動約2.7MiB、1000件後約11MiB）は参考値であり、
当時のビルド条件やアプリが本Stepと完全に一致しないため厳密な差分ではない。

## 受け入れ基準

1. `nimble test`、Step 5〜16、Step 17測定器単体テストがすべて成功。
2. amd64/arm64/armhfの実行可能なターゲットでビルドし、結果ファイルを保存。
3. 少なくとも**実際のCortex-A5相当のarmhfボード**でRSS、FD、CPUとレスポンス時間を測定。
4. 同一CPU・同条件の旧版との比較で、代表GETのRPSが5%超低下する場合は原因調査。
   10%超低下なら明示的な受け入れ判断が必要。メモリの増大も用途の上限で審査。
5. 代表する既存管理WebUIを1つ`import jestersimple`へ移行し、ビルド・実機HTTP試験を記録。
6. セキュリティ残課題、逆プロキシ・TLS・アクセス制御・ライセンス表記・バージョンを点検。
7. `docs/release/RELEASE_CHECKLIST.md`に根拠を記録してからタグを決定する。

**リリース判定は未実施。** このファイル・測定スクリプトの追加だけで
「軽量化達成」「セキュリティ完全対応」「出荷可能」とは宣言しない。
