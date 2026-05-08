#!/bin/bash
# ロゴ関連ユーティリティ

LOGOS_DIR="${LOGOS_DIR:-/logos}"

# TS映像解像度の取得（WxH形式: 1440x1080 など）
get_video_resolution() {
    local ts_file="$1"
    ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=width,height \
        -of csv=p=0:s=x "$ts_file" 2>/dev/null | head -1 | sed 's/x$//'
}

# 全局ディレクトリから解像度一致のlgd候補を返す（1行1パス、日付降順）
list_all_logo_candidates() {
    local resolution="$1"

    shopt -s nullglob
    local candidates=()
    for dir in "${LOGOS_DIR}"/*/; do
        [[ "$(basename "$dir")" == "candidates" ]] && continue
        candidates+=("${dir}"*_"${resolution}".lgd)
    done
    shopt -u nullglob

    [[ ${#candidates[@]} -eq 0 ]] && return 1

    printf '%s\n' "${candidates[@]}" | sort -r
}

# 入力TSと同じ解像度の全局ロゴ候補を返す（1行1パス、日付降順）
find_logo_candidates_for_input() {
    local ts_file="$1"
    local resolution
    local candidates

    resolution=$(get_video_resolution "$ts_file")
    if [[ -z "$resolution" ]]; then
        log "映像解像度を取得できませんでした"
        return 1
    fi

    log "映像解像度: ${resolution}"
    log "全局ロゴ候補から同時検出します"

    candidates=$(list_all_logo_candidates "$resolution" || echo "")
    if [[ -n "$candidates" ]]; then
        local count
        count=$(echo "$candidates" | wc -l | tr -d ' ')
        log "ロゴ候補: ${count}件（全局/${resolution}）"
        echo "$candidates"
        return 0
    fi

    log "解像度 ${resolution} のロゴが見つかりません"
    return 1
}
