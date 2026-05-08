# TS Converter

テレビ録画したTSファイルを、CMカット付きでiPhone再生可能なMP4(H.265)に自動変換するDockerツール。

## 特徴

- **Docker完結** — ローカルにffmpeg等のインストール不要
- **フォルダ監視で自動変換** — TSファイルを置くだけ
- **CMカット** — join_logo_scpによるロゴ+無音検出
- **高画質** — H.265 CRF 23 / medium preset（調整可）
- **音声コピー優先** — コピー試験とデコード検証に通る場合は無劣化コピー、不可時やデュアルモノラル時はAAC再エンコード
- **iPhone完全対応** — hvc1タグ、faststart、Main profile

## 必要なもの

- Docker Engine
- Docker Compose v2
- macOSの場合は Docker Desktop / Colima / OrbStack など

## 技術スタック

- Ubuntu 24.04
- FFmpeg 6.1
- AviSynthPlus 3.7.5 / FFMS2 5.0
- join_logo_scp (tobitti0版)

## セットアップ

```bash
git clone <このリポジトリ>
cd ts-converter
cp converter.env.sample converter.env
docker compose up -d --build
```

初回ビルドはjoin_logo_scpのコンパイルを含むため数分かかります。

## 使い方

### 基本（CMカットあり）

```bash
cp 録画ファイル.ts input/
```

30秒以内に自動検出され、CMカット→ロゴ消し→H.265エンコード→検証が実行されます。
完成したMP4は `output/` に出力されます。成功時はジョブ作業領域を削除し、`output/.job_<ファイル名>.manifest` に最終状態のコピーだけを残します。失敗時は `work/jobs/<job_id>/` に解析用のmanifest・ログ・AVS等を保持します。
`ENABLE_DELOGO_DEBUG=true` の場合は、成功時もジョブ作業ディレクトリ `work/jobs/<job_id>/` を保持します。中には manifest、ログ、AVS、ロゴ消し確認画像などが含まれます。

### CMカットなし

```bash
cp 録画ファイル.ts input/nocmcut/
```

### ログ確認

```bash
docker compose logs -f
```

### 停止・再起動

```bash
docker compose down      # 停止
docker compose up -d     # 再起動
```

## ディレクトリ構成

```
input/            TSファイルを置く（CMカットあり）
input/nocmcut/    TSファイルを置く（CMカットなし）
output/           変換済みMP4の出力先
work/             一時作業ディレクトリ（ジョブごとに管理）
  jobs/<job_id>/  失敗時にmanifest・AVS・ログ等を保持
  .processing_*.lock  同一入力の二重処理防止ロック
logos/            チャンネルロゴデータ
  <局コード>/       局ごとの確認済みロゴ
```

## CMカットとロゴデータ

join_logo_scpはチャンネルロゴの出現/消滅でCM区間を判定します。

### ロゴの管理

ロゴデータは局ごとのディレクトリに保存します:

```
logos/
├── NHKG/
│   ├── NHKG_2020-03-23_1440x1080.lgd   # 旧ロゴ
│   └── NHKG_2020-11-30_1440x1080.lgd   # 現行ロゴ
├── NTV/
│   └── NTV_2023-01-07_1440x1080.lgd
```

**ファイル命名規則:** `<局コード>_<YYYY-MM-DD>_<WxH>.lgd`

**マッチングの流れ:**

1. TSファイルごとに `work/jobs/<job_id>/manifest.env` を作成または再開
2. TSファイルから映像解像度を自動取得
3. 同一解像度の全局ロゴ候補を収集
4. 全候補を1回の `logoframe` で同時検出
5. 選ばれたロゴの検出率が基準以上なら採用
6. 確認済みロゴがない場合、または検出率が基準未満の場合は変換を中止
7. failedマーカー（`output/.failed_ファイル名`）が作成されるので、ロゴ設定後にマーカーを削除すると再変換

`manifest.env` の更新は `manifest.env.lock` で直列化されます。同じ入力ファイルの二重処理は `work/.processing_<ファイル名>.lock` で防ぎます。

**ロゴ変更の検知:**

全局同時検出で選ばれたロゴの検出率が基準未満のとき、テレビ局のロゴが変更された可能性があると判定します。新しい確認済み `.lgd` を追加してからfailedマーカーを削除してください。

### ロゴ消し

`ENABLE_DELOGO=true` の場合、CMカットで採用した `.lgd` を使ってロゴ消しを行います。ロゴ消しはAviSynthの `EraseLOGO` を `avs2y4m | ffmpeg` 経由で適用し、logoframeの検出座標と `.lgd` 内部座標から位置を補正します。

## 設定のカスタマイズ

`converter.env.sample` をコピーした `converter.env` で調整できます:

**converter.env.sample:**

| 変数 | 標準設定 | 説明 |
|------|-----------|------|
| `POLL_INTERVAL` | 30 | フォルダ監視間隔（秒） |
| `CRF` | 23 | 画質（低いほど高画質、18-28が実用的） |
| `PRESET` | medium | エンコード速度（slower/slow/medium/fast） |
| `ENABLE_DELOGO` | true | ロゴ消し（EraseLOGO）を有効化 |
| `ENABLE_DELOGO_DEBUG` | false | ロゴ消し前後フレーム・crop・差分ログをジョブ配下に残す |
| `MIN_LOGO_DETECTION_RATE` | 30 | ロゴ採用の最低検出率（%） |

音声は `-c:a copy` を優先しますが、コピーした音声がMP4内で正常にデコードできない場合はAACへ再エンコードします。再エンコード時のビットレートは元音声を見て自動選択します。

## 再変換したい場合

```bash
# 対象ファイルのマーカーを削除
rm output/.done_ファイル名
# 失敗マーカーがある場合はそれも削除
rm output/.failed_ファイル名
```

次のスキャンサイクルで自動的に再変換されます。

## エンコード時間の目安

Apple Silicon Mac + Docker（ソフトウェアx265）:

| 設定 | 1時間1080p素材 |
|------|---------------|
| CRF 23 / medium | 約3-4時間 |
| CRF 20 / slow | 約6-10時間 |
| CRF 26 / medium | 約2-3時間 |

夜間にバッチ処理する運用を推奨します。

## iPhone での再生

変換済みMP4はiPhone標準の動画プレーヤーで再生できます。

転送方法:
- AirDrop
- iCloud Drive
- ケーブル接続（Finder経由）


## トラブルシューティング

### 変換が始まらない

```bash
docker compose logs -f
```

でログを確認してください。コンテナが停止している場合は `docker compose up -d` で再起動。

### 変換に失敗した

`output/.failed_ファイル名` が作成されます。ログで原因を確認し、問題を修正後にマーカーを削除すれば再試行されます。

### CMカットの精度が悪い

`logos/` に確認済みのチャンネルロゴデータを追加することで改善します。通常入力で確認済みロゴがない場合は、誤カット防止のため変換を中止して failed マーカーを作成します。CMカットせず変換したい場合は `input/nocmcut/` に置いてください。
