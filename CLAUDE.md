# CLAUDE.md

## プロジェクト概要

テレビ録画TSファイルをiPhone再生用MP4(H.265)に自動変換するDockerツール。
CMカット（join_logo_scp）+ 高画質エンコード（libx265）のパイプライン。

## 技術スタック

- Docker (ubuntu:24.04ベース)
- ffmpeg 6.1 (libx265, AAC)
- AviSynthPlus 3.7.5 + FFMS2 5.0
- join_logo_scp (tobitti0/join_logo_scp_trial) — CMカット
- Bash スクリプト

## アーキテクチャ

```
input/ → [ポーリング検出] → [job manifest] → [CMカット] → [ロゴ消し] → [H.265エンコード] → [検証] → output/
```

### docker-composeサービス構成

- `converter`: 常駐サービス。input/をポーリングしてTS→MP4変換

スクリプトはイメージに焼き込まず、ホスト側からマウント（変更時のリビルド不要）。

### スクリプト構成（scripts/）

```
scripts/
├── lib/                          # 共通（両サービスで /scripts/lib にマウント）
│   ├── avs.sh
│   ├── common.sh
│   ├── job.sh
│   ├── logo.sh
│   └── media.sh
├── converter/                    # converter用（/scripts/app にマウント）
│   ├── convert.sh
│   ├── cmcut.sh
│   └── stages/
│       ├── cmcut.sh
│       ├── delogo.sh
│       ├── encode.sh
│       └── verify.sh
```

## ビルド・実行

```bash
docker compose up -d --build   # ビルド＋起動
docker compose logs -f         # ログ確認
docker compose down            # 停止
```

## 重要な設計判断

- macOS Docker bind mountではinotifyが動作しないためポーリング方式を採用
- 音声はコピー優先。`-c:a copy` + `aac_adtstoasc` の試験出力をデコード検証し、成功した場合のみ無劣化コピーする
- 音声コピー不可、またはデュアルモノラル時はAAC再エンコードする。再エンコード時は元音声ビットレートを見て 192k/256k/320k などを選ぶ
- `-tag:v hvc1` はApple機器再生に必須（hev1だとiOSで再生不可）
- CMカット失敗時（ロゴ未検出含む）は変換を中止し、failedマーカーを作成する
- 一時ファイルは `work/jobs/<job_id>/` に隔離し、manifestでステージ状態を管理する。成功時はジョブを削除し、失敗時はmanifest・ログ・AVS等を保持する
- manifest更新は `manifest.env.lock`、同一入力の二重処理防止は `.processing_<basename>.lock` を使い、`mkdir` ベースの原子的ロックで制御する
- ロゴ消し（EraseLOGO）はENABLE_DELOGOで有効化。`.avs` 直読みではなく `avs2y4m | ffmpeg` 経由でエンコード時に処理する
- ロゴ消しはlogoframeの検出座標と `.lgd` 内部座標から `EraseLOGO` の位置補正を行う。ENABLE_DELOGO_DEBUG=true で前後フレーム・crop・差分ログをジョブ配下に残す
- ロゴファイルは局ごとのディレクトリに `<局コード>_<日付>_<解像度>.lgd` 形式で管理する。入力TSと同じ解像度の全局候補を毎回収集する
- service_name / channel_map / Mirakurun 連携は使わない。同一解像度の候補lgdを1回のlogoframeで同時検出し、検出率が基準以上のロゴを採用する。複数ロゴ同時検出で選べない場合は失敗扱いにする
- MIN_LOGO_DETECTION_RATEでロゴ採用の最低検出率を指定する。通常は30で運用する
