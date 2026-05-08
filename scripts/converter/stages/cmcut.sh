#!/bin/bash
set -euo pipefail

source /scripts/lib/common.sh
source /scripts/lib/logo.sh
source /scripts/lib/avs.sh
source /scripts/lib/media.sh
source /scripts/lib/job.sh

LOG_TAG="stage:cmcut"

MANIFEST="${1:?manifest path required}"
manifest_load "$MANIFEST"

JLS_DIR="${JLS_DIR:-/opt/jls}"
MIN_LOGO_DETECTION_RATE="${MIN_LOGO_DETECTION_RATE:-30}"

CMCUT_WORK="${JOB_DIR}/cmcut"
mkdir -p "$CMCUT_WORK"

calculate_detection_rate() {
    local logoframe_result="$1"
    local logo_frames=0
    local max_frame=0
    local last_start=0
    local frame
    local type

    while read -r frame type _rest; do
        frame=$(echo "$frame" | tr -d '[:space:]')
        [[ -z "$frame" || ! "$frame" =~ ^[0-9]+$ ]] && continue

        if [[ "$type" == "S" ]]; then
            last_start=$frame
        elif [[ "$type" == "E" ]]; then
            logo_frames=$((logo_frames + frame - last_start))
            [[ $frame -gt $max_frame ]] && max_frame=$frame
        fi
    done < "$logoframe_result"

    if [[ $max_frame -eq 0 ]]; then
        echo "-1"
        return 0
    fi

    echo $((logo_frames * 100 / max_frame))
}

parse_logo_position_from_log() {
    local log_file="$1"
    local logo_num="${2:-1}"

    if [[ ! -f "$log_file" ]]; then
        return 1
    fi

    sed -n -E "s/^logo${logo_num}:loc\\(([0-9]+),([0-9]+)\\).*/\\1	\\2/p" "$log_file" | head -1
}

parse_first_logo_debug_frame() {
    local logoframe_result="$1"
    local start_frame

    if [[ ! -f "$logoframe_result" ]]; then
        return 1
    fi

    start_frame=$(awk '$2=="S" && $1 ~ /^[0-9]+$/ { print $1; exit }' "$logoframe_result")
    if [[ -z "$start_frame" ]]; then
        return 1
    fi

    echo $((start_frame + 30))
}

select_logo_by_multilogo_detection() {
    local logoframe_avs="$1"
    local logoframe_result="$2"
    shift 2

    local candidates=("$@")
    local multilogo_dir="${CMCUT_WORK}/multilogo_candidates"
    local multilogo_log="${CMCUT_WORK}/logoframe_multilogo.log"
    local multilogo_list="${logoframe_result%.*}_list.ini"
    local candidate
    local link_name
    local selected=""
    local frame_sum=""
    local frame_total=""
    local org_logo_num=""
    local logo_pos=""
    local pos_x=""
    local pos_y=""
    local debug_frame=""

    rm -rf "$multilogo_dir"
    mkdir -p "$multilogo_dir"

    local idx=1
    for candidate in "${candidates[@]}"; do
        link_name="${multilogo_dir}/$(printf '%03d' "$idx")_$(basename "$candidate")"
        ln -s "$candidate" "$link_name"
        idx=$((idx + 1))
    done

    log "複数ロゴ同時検出: ${#candidates[@]}件を1回のlogoframeで確認します"
    if ! logoframe "$logoframe_avs" \
        -logo "$multilogo_dir" \
        -oa "$logoframe_result" \
        -oasel 1 \
        -oamask 7 >"$multilogo_log" 2>&1; then
        log "複数ロゴ同時検出に失敗しました"
        return 1
    fi

    if [[ ! -f "$multilogo_list" ]]; then
        log "複数ロゴ同時検出のリストが生成されませんでした"
        return 1
    fi

    selected=$(awk -F= '$1=="LogoName_N1"{print $2; exit}' "$multilogo_list")
    frame_sum=$(awk -F= '$1=="FrameSum_N1"{print $2; exit}' "$multilogo_list")
    frame_total=$(awk -F= '$1=="FrameTotal"{print $2; exit}' "$multilogo_list")
    org_logo_num=$(awk -F= '$1=="OrgLogoNum_N1"{print $2; exit}' "$multilogo_list")

    if [[ -z "$selected" || -z "$frame_sum" || -z "$frame_total" || "$frame_total" -le 0 ]]; then
        log "複数ロゴ同時検出で有効ロゴが選ばれませんでした"
        return 1
    fi

    local detection_rate=$((frame_sum * 100 / frame_total))
    if [[ "$detection_rate" -lt "$MIN_LOGO_DETECTION_RATE" ]]; then
        log "複数ロゴ同時検出の検出率不足 (${detection_rate}% < ${MIN_LOGO_DETECTION_RATE}%)"
        return 1
    fi

    selected=$(readlink -f "$selected")
    logo_pos=$(parse_logo_position_from_log "$multilogo_log" "${org_logo_num:-1}" || true)
    if [[ -n "$logo_pos" ]]; then
        IFS=$'\t' read -r pos_x pos_y <<< "$logo_pos"
    fi
    debug_frame=$(parse_first_logo_debug_frame "$logoframe_result" || true)

    printf '%s\t%s\t%s\t%s\t%s\n' "$selected" "$detection_rate" "$pos_x" "$pos_y" "$debug_frame"
}

select_logo() {
    local candidates_str
    local logoframe_result="${CMCUT_WORK}/logoframe.txt"
    local logoframe_avs="${CMCUT_WORK}/logoframe.avs"
    local logo_file=""
    local logo_pos_x=""
    local logo_pos_y=""
    local logo_debug_frame=""

    candidates_str=$(find_logo_candidates_for_input "$INPUT_FILE" || echo "")

    if [[ -z "$candidates_str" ]]; then
        log "ERROR: 確認済みロゴが見つかりません"
        return 1
    fi

    mapfile -t logo_candidates <<< "$candidates_str"
    log "ロゴ候補: ${#logo_candidates[@]}件"

    create_logoframe_avs "$INPUT_FILE" "$logoframe_avs"

    local multilogo_selected=""
    local multilogo_rate=""
    local multilogo_pos_x=""
    local multilogo_pos_y=""
    local multilogo_debug_frame=""
    local multilogo_result=""

    if multilogo_result=$(select_logo_by_multilogo_detection "$logoframe_avs" "$logoframe_result" "${logo_candidates[@]}"); then
        IFS=$'\t' read -r multilogo_selected multilogo_rate multilogo_pos_x multilogo_pos_y multilogo_debug_frame <<< "$multilogo_result"
        logo_file="$multilogo_selected"
        logo_pos_x="$multilogo_pos_x"
        logo_pos_y="$multilogo_pos_y"
        logo_debug_frame="$multilogo_debug_frame"
        log "複数ロゴ同時検出で採用: $(basename "$logo_file") (${multilogo_rate}%)"
    else
        log "複数ロゴ同時検出では選択できませんでした"
    fi

    if [[ -z "$logo_file" ]]; then
        log "WARNING: 全てのロゴ候補で検出率が不足しています"
        log "ロゴが変更された可能性があります。確認済みlgdを追加してください"
        return 1
    fi

    log "使用ロゴ: $(basename "$logo_file")"
    manifest_set "$MANIFEST" LOGO_FILE "$logo_file"
    manifest_set "$MANIFEST" LOGO_POS_X "$logo_pos_x"
    manifest_set "$MANIFEST" LOGO_POS_Y "$logo_pos_y"
    manifest_set "$MANIFEST" LOGO_DEBUG_FRAME "$logo_debug_frame"
}

run_chapter_detection() {
    local chapter_result="${CMCUT_WORK}/chapter.txt"
    local chapter_log="${CMCUT_WORK}/chapter_exe.log"
    local chapter_video_avs="${CMCUT_WORK}/chapter_video.avs"
    local chapter_audio_wav="${CMCUT_WORK}/audio.wav"

    log "chapter_exe 実行中..."
    log "音声抽出中..."
    if ! ffmpeg -nostdin -y -i "$INPUT_FILE" -map 0:a:0 -vn -ac 2 -ar 48000 "$chapter_audio_wav" >"${CMCUT_WORK}/audio_extract.log" 2>&1; then
        log "ERROR: 音声抽出に失敗しました"
        return 1
    fi

    create_chapter_video_avs "$INPUT_FILE" "$chapter_video_avs" "${CMCUT_WORK}/chapter_video.ffindex"

    if ! chapter_exe -v "$chapter_video_avs" -a "$chapter_audio_wav" -oa "$chapter_result" >"$chapter_log" 2>&1; then
        log "ERROR: chapter_exe 失敗"
        return 1
    fi
}

run_join_logo_scp() {
    local logoframe_result="${CMCUT_WORK}/logoframe.txt"
    local chapter_result="${CMCUT_WORK}/chapter.txt"
    local avscript="${CMCUT_WORK}/cut.avs"
    local jls_result="${CMCUT_WORK}/jls_cut.txt"
    local jls_log="${CMCUT_WORK}/join_logo_scp.log"
    local jls_cmd="${JLS_CMD:-${JLS_DIR}/modules/join_logo_scp/JL/JL_標準.txt}"

    log "join_logo_scp 実行中..."
    manifest_load "$MANIFEST"
    if ! join_logo_scp \
        ${LOGO_FILE:+-inlogo "$logoframe_result"} \
        -inscp "$chapter_result" \
        -incmd "$jls_cmd" \
        -o "$avscript" \
        -oscp "$jls_result" >"$jls_log" 2>&1; then
        log "ERROR: join_logo_scp 失敗"
        return 1
    fi

    [[ -f "$avscript" ]]
}

extract_trim_segments() {
    local avscript="${CMCUT_WORK}/cut.avs"
    local logoframe_result="${CMCUT_WORK}/logoframe.txt"
    local concat_list="${CMCUT_WORK}/concat.txt"
    local trim_lines
    local trim_count
    local fps
    local fps_num
    local fps_den
    local segment_idx=0
    local logo_starts=()
    local logo_ends=()
    local logo_start
    local logo_end

    if [[ ! -f "$avscript" ]]; then
        log "ERROR: AVSスクリプトが生成されませんでした"
        return 1
    fi

    trim_lines=$(grep -Eio 'trim[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*[0-9]+[[:space:]]*\)' "$avscript" 2>/dev/null || true)
    if [[ -z "$trim_lines" ]]; then
        log "ERROR: Trim情報が見つかりません"
        return 1
    fi

    trim_count=$(printf '%s\n' "$trim_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
    log "保持Trimセグメント検出: ${trim_count}件"

    fps=$(get_frame_rate_fraction "$INPUT_FILE")
    if [[ -z "$fps" ]]; then
        log "ERROR: フレームレートを取得できません"
        return 1
    fi

    fps_num=$(echo "$fps" | cut -d'/' -f1)
    fps_den=$(echo "$fps" | cut -d'/' -f2)
    [[ -z "$fps_den" || "$fps_den" == "$fps_num" ]] && fps_den=1
    log "フレームレート: ${fps_num}/${fps_den}"

    if [[ ! -f "$logoframe_result" ]]; then
        log "ERROR: logoframe結果が見つかりません"
        return 1
    fi

    local current_logo_start=""
    while read -r logo_start type _rest; do
        logo_start=$(echo "$logo_start" | tr -d '[:space:]')
        [[ -z "$logo_start" || ! "$logo_start" =~ ^[0-9]+$ ]] && continue

        if [[ "$type" == "S" ]]; then
            current_logo_start="$logo_start"
        elif [[ "$type" == "E" && -n "$current_logo_start" ]]; then
            logo_starts+=("$current_logo_start")
            logo_ends+=("$logo_start")
            current_logo_start=""
        fi
    done < "$logoframe_result"

    if [[ "${#logo_starts[@]}" -eq 0 ]]; then
        log "ERROR: 有効なロゴ検出区間がありません"
        return 1
    fi
    log "ロゴ検出区間: ${#logo_starts[@]}件"

    : > "$concat_list"
    while IFS= read -r line; do
        if [[ "$line" =~ [Tt]rim[[:space:]]*\([[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*\) ]]; then
            local start_frame="${BASH_REMATCH[1]}"
            local end_frame="${BASH_REMATCH[2]}"
            local idx

            for idx in "${!logo_starts[@]}"; do
                local keep_start="$start_frame"
                local keep_end="$end_frame"
                local start_sec
                local end_sec
                local duration
                local segment_file

                logo_start="${logo_starts[$idx]}"
                logo_end="${logo_ends[$idx]}"

                [[ "$keep_start" -lt "$logo_start" ]] && keep_start="$logo_start"
                [[ "$keep_end" -gt "$logo_end" ]] && keep_end="$logo_end"
                [[ "$keep_start" -gt "$keep_end" ]] && continue

                if [[ "$keep_start" != "$start_frame" || "$keep_end" != "$end_frame" ]]; then
                    log "ロゴ有無でTrim境界を補正: ${start_frame}-${end_frame} -> ${keep_start}-${keep_end}"
                fi

                start_sec=$(echo "scale=6; $keep_start * $fps_den / $fps_num" | bc)
                end_sec=$(echo "scale=6; ($keep_end + 1) * $fps_den / $fps_num" | bc)
                duration=$(echo "scale=6; $end_sec - $start_sec" | bc)
                segment_file="${CMCUT_WORK}/seg_${segment_idx}.ts"

                ffmpeg -nostdin -y -ss "$start_sec" -i "$INPUT_FILE" \
                    -t "$duration" \
                    -c copy \
                    -avoid_negative_ts make_zero \
                    "$segment_file" >"${CMCUT_WORK}/seg_${segment_idx}.log" 2>&1

                echo "file '${segment_file}'" >> "$concat_list"
                segment_idx=$((segment_idx + 1))
            done
        fi
    done <<< "$trim_lines"

    if [[ $segment_idx -eq 0 ]]; then
        log "ERROR: 有効なTrimセグメントがありません"
        return 1
    fi

    log "CM除去済みセグメント結合中（${segment_idx}セグメント）..."
    ffmpeg -nostdin -y -f concat -safe 0 -i "$concat_list" \
        -c copy \
        "$CMCUT_TS" >"${CMCUT_WORK}/concat.log" 2>&1
}

main() {
    local stage_log="${CMCUT_WORK}/cmcut.stage.log"
    manifest_set "$MANIFEST" LOG_CMCUT "$stage_log"
    job_stage_begin "$MANIFEST" "cmcut"

    if ! {
        select_logo &&
        run_chapter_detection &&
        run_join_logo_scp &&
        extract_trim_segments
    } > >(tee -a "$stage_log" >&2) 2>&1; then
        job_stage_fail "$MANIFEST" "cmcut" "CMカットに失敗しました"
        return 1
    fi

    manifest_load "$MANIFEST"
    echo "$LOGO_FILE" > "${CMCUT_TS}.logo"
    manifest_set "$MANIFEST" HAS_CMCUT "true"
    manifest_set "$MANIFEST" ENCODE_INPUT "$CMCUT_TS"
    job_stage_success "$MANIFEST" "cmcut"
    log "CMカット完了: $(basename "$CMCUT_TS")"
}

main
