# 再現可能な性能・リソース測定（Step 17）

## 目的と対象

Jester SimpleをLinux環境で測定し、旧Jesterforkとの比較を含めて
リクエスト遅延・スループット・RSS・FD・CPU・バイナリサイズを記録する。
**測定器の整備後、静的小ファイルの送信方法を改善した**ため、
古い測定レポートと現在の実装の数値を混在させないこと。

このドキュメントは**測定手順**であり、リリースを自動承認するものではない。
Jester Simple自体はLinux、Nim 2.2.12以上、`--mm:orc`を対象とする。

## 使用するファイル

| PATH | 内容 |
| --- | --- |
| `tests/perf/step17_app.nim` | 旧版・新版の共通ルートを持つ測定アプリ |
| `tests/perf/step17_probe.py` | Python標準ライブラリの逐次HTTPクライアント |
| `tests/perf/compare_step17.py` | 同条件での比較表生成 |
| `tests/perf/run_step17.sh` | 一時ファイル生成・ビルド・測定・後片付け |
| `tests/perf/test_step17_tools.py` | 測定器の単体テスト |
| `docs/release/RELEASE_CHECKLIST.md` | リリース判定項目 |

CIは使用しない方針であり、測定と回帰試験はローカルで実施する。

## 前提条件

Linux、Nim 2.2.12以上、ORC、Cコンパイラ、Python 3、Bash、Git。
旧版との比較には`jesterfork.nim`が存在するソースディレクトリを指定する。
TCPポートは`127.0.0.1:5517`のみを使用する。`wrk`は不要。

## 実行

測定器単体テスト：

```sh
python3 tests/perf/test_step17_tools.py
```

現行Jester Simpleの測定（出力ディレクトリは自動作成）：

```sh
bash tests/perf/run_step17.sh docs/performance/step17-amd64
```

arm64/armhf機器で実行する場合は出力先を分離する。

```sh
bash tests/perf/run_step17.sh docs/performance/step17-arm64
STEP17_NIM_EXTRA_FLAGS='-d:nimUse64BitCTime' \
  bash tests/perf/run_step17.sh docs/performance/step17-armhf
```

`-d:nimUse64BitCTime`は必要なarmhfビルドでのみ指定する。
`STEP17_NIM_EXTRA_FLAGS`は旧版・新版の双方に適用される。

旧Jesterforkとの比較：

```sh
bash tests/perf/run_step17.sh \
  docs/performance/step17-paired /path/to/legacy-jesterfork
```

旧版は標準HTTPバックエンドを使用するため`-d:step17Legacy -d:useStdLib`を指定。
双方とも`--mm:orc -d:release --opt:size`を使用するが、
ソース差分やセキュリティ検証コストも含んだ比較になる。

## 計測方法と精度の限界

各ルート3回の反復測定を実施する。標準のサンプル数は次のとおり。

| ルート | 1反復あたり要求数 |
| --- | ---: |
| 通常GET / JSON / Query / POST / 静的小ファイル | 400 |
| 静的2MiB | 10 |
| 静的32MiB | 2 |

先行して1,000 GETを実行し、RSS・FDの変化を観測する。
各HTTP応答はステータスと本文、またはサイズとSHA-256を照合する。
`STEP17_QUICK=1`を指定したときは要求数を減らすため、通常の結果と比較しないこと。

**Python `http.client`による単一接続の逐次測定であり、ピークRPSではない。**
クライアント自身のCPUとローカルTCPの遅延を含む。
2MiBの10件と32MiBの2件ではp99はほぼ最大値を表し、統計的に安定しない。
本格的な同時接続性能は同一LANの別ホストから専用負荷ツールで検証する。

測定対象はループバックで、比較対象は同じホスト・CPU・OS・ツールチェーン・
計測オプションに揃える。異なるアーキテクチャのRPSを直接比較しない。

## 出力

- `<out>/current/RESULTS.json` / `REPORT.md`：新実装の測定結果。
- `<out>/legacy/` / `<out>/COMPARISON.md`：旧版を指定した場合の比較。
- `<out>/environment.txt`：CPU/Kernel/NimとHEAD、作業ツリー状態。
- `<out>/current/{build.log,server.log,binary-sections.txt,dynamic-libraries.txt,startup.txt}`：診断情報。

`docs/performance/step17-*/`の生成物は`.gitignore`で除外している。
サンプルに含まれる古い計測値ではなく、現在のcommitをチェックアウトして
**再実行した数値**で判定すること。

## セキュリティ回帰と受け入れ条件

```sh
nimble test -y
python3 tests/integration/run_step16_suite.py
```

- すべてのテストが成功し、失敗ステージが残っていないこと。
- 代表GETが旧版より5%超低下する場合は原因を調査し、10%超の退行は
  明示的な受け入れ判断を残すこと（絶対的な合否閾値ではない）。
- Cortex-A5を想定する場合は実機でRSS、FD、CPUと応答を測定すること。
- 実際の管理WebUIでの互換性と接続条件を検証すること。
- 結果と根拠を[リリースチェックリスト](../release/RELEASE_CHECKLIST.md)に記録すること。
