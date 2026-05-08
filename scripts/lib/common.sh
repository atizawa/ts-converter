#!/bin/bash
# 共通ユーティリティ関数

# ログ出力（呼び出し元で LOG_TAG を設定すると "[tag]" が付く）
log() {
    local tag="${LOG_TAG:+ [$LOG_TAG]}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]${tag} $*" >&2
}

# ファイル名に使えない文字を置換
sanitize_filename() {
    local name="$1"
    name="${name//\//_}"
    name="${name//\\/_}"
    name="${name//:/_}"
    echo "$name"
}
