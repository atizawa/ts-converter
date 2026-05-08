#!/bin/bash
set -euo pipefail

source /scripts/lib/common.sh
source /scripts/lib/avs.sh
source /scripts/lib/job.sh

LOG_TAG="stage:delogo"

MANIFEST="${1:?manifest path required}"
manifest_load "$MANIFEST"

DELOGO_WORK="${JOB_DIR}/delogo"
mkdir -p "$DELOGO_WORK"

create_debug_original_avs() {
    local input_file="$1"
    local avs_file="$2"
    local frame="$3"
    local escaped_input

    escaped_input=$(escape_avs_path "$input_file")

    {
        echo 'LoadPlugin("/usr/local/lib/libffms2.so")'
        echo "FFVideoSource(\"${escaped_input}\", seekmode=0)"
        echo "Trim(${frame},${frame})"
        echo 'ConvertToYV12(interlaced=true)'
    } > "$avs_file"
}

create_debug_delogo_avs() {
    local input_file="$1"
    local logo_file="$2"
    local avs_file="$3"
    local frame="$4"
    local logo_pos_x="${5:-}"
    local logo_pos_y="${6:-}"
    local escaped_input
    local escaped_logo
    local position_args

    escaped_input=$(escape_avs_path "$input_file")
    escaped_logo=$(escape_avs_path "$logo_file")
    position_args=$(get_delogo_position_args "$logo_file" "$logo_pos_x" "$logo_pos_y")

    {
        echo 'LoadPlugin("/usr/local/lib/avisynth/libdelogo.so")'
        echo 'LoadPlugin("/usr/local/lib/libffms2.so")'
        echo "FFVideoSource(\"${escaped_input}\", seekmode=0)"
        echo "Trim(${frame},${frame})"
        echo 'ConvertToYV12(interlaced=true)'
        echo "EraseLOGO(logofile=\"${escaped_logo}\"${position_args}, interlaced=true)"
    } > "$avs_file"
}

render_debug_frame() {
    local avs_file="$1"
    local output_file="$2"
    local log_file="$3"

    avs2y4m "$avs_file" | ffmpeg -nostdin -v error -f yuv4mpegpipe -i - \
        -frames:v 1 -y "$output_file" >>"$log_file" 2>&1
}

crop_debug_frame() {
    local input_file="$1"
    local output_file="$2"
    local crop_x="$3"
    local crop_y="$4"
    local log_file="$5"

    ffmpeg -nostdin -v error -i "$input_file" \
        -vf "crop=180:120:${crop_x}:${crop_y}" \
        -frames:v 1 -y "$output_file" >>"$log_file" 2>&1
}

create_delogo_debug_artifacts() {
    local debug_dir="${DELOGO_WORK}/debug"
    local debug_log="${debug_dir}/debug.log"
    local debug_frame="${DELOGO_DEBUG_FRAME:-${LOGO_DEBUG_FRAME:-0}}"
    local original_avs="${debug_dir}/original.avs"
    local delogo_avs="${debug_dir}/delogo.avs"
    local original_jpg="${debug_dir}/original.jpg"
    local delogo_jpg="${debug_dir}/delogo.jpg"
    local crop_x=0
    local crop_y=0

    mkdir -p "$debug_dir"
    : > "$debug_log"

    if [[ -n "${LOGO_POS_X:-}" && "$LOGO_POS_X" =~ ^[0-9]+$ ]]; then
        crop_x=$((LOGO_POS_X > 20 ? LOGO_POS_X - 20 : 0))
    fi
    if [[ -n "${LOGO_POS_Y:-}" && "$LOGO_POS_Y" =~ ^[0-9]+$ ]]; then
        crop_y=$((LOGO_POS_Y > 20 ? LOGO_POS_Y - 20 : 0))
    fi

    {
        echo "input=${ENCODE_INPUT}"
        echo "logo=${LOGO_FILE}"
        echo "logo_pos_x=${LOGO_POS_X:-}"
        echo "logo_pos_y=${LOGO_POS_Y:-}"
        echo "debug_frame=${debug_frame}"
        echo "crop=${crop_x}:${crop_y}:180:120"
    } >> "$debug_log"

    create_debug_original_avs "$ENCODE_INPUT" "$original_avs" "$debug_frame"
    create_debug_delogo_avs "$ENCODE_INPUT" "$LOGO_FILE" "$delogo_avs" "$debug_frame" "${LOGO_POS_X:-}" "${LOGO_POS_Y:-}"

    if ! render_debug_frame "$original_avs" "$original_jpg" "$debug_log"; then
        log "WARNING: ロゴ消し前デバッグフレーム生成に失敗しました: $debug_log"
        return 0
    fi
    if ! render_debug_frame "$delogo_avs" "$delogo_jpg" "$debug_log"; then
        log "WARNING: ロゴ消し後デバッグフレーム生成に失敗しました: $debug_log"
        return 0
    fi

    ffmpeg -nostdin -v info -i "$original_jpg" -i "$delogo_jpg" \
        -filter_complex psnr -f null - >>"$debug_log" 2>&1 || true

    crop_debug_frame "$original_jpg" "${debug_dir}/original_crop.jpg" "$crop_x" "$crop_y" "$debug_log" || true
    crop_debug_frame "$delogo_jpg" "${debug_dir}/delogo_crop.jpg" "$crop_x" "$crop_y" "$debug_log" || true

    manifest_set "$MANIFEST" LOG_DELOGO_DEBUG "$debug_log"
    log "ロゴ消しデバッグ成果物: $debug_dir"
}

main() {
    local stage_log="${DELOGO_WORK}/delogo.stage.log"
    manifest_set "$MANIFEST" LOG_DELOGO "$stage_log"
    job_stage_begin "$MANIFEST" "delogo"

    if [[ "${ENABLE_DELOGO:-false}" != "true" ]]; then
        log "ロゴ消し無効"
        manifest_set "$MANIFEST" USE_DELOGO "false"
        job_stage_success "$MANIFEST" "delogo"
        return 0
    fi

    if [[ -z "${LOGO_FILE:-}" ]]; then
        log "使用ロゴなし -> ロゴ消しスキップ"
        manifest_set "$MANIFEST" USE_DELOGO "false"
        job_stage_success "$MANIFEST" "delogo"
        return 0
    fi

    if [[ ! -f "$LOGO_FILE" ]]; then
        job_stage_fail "$MANIFEST" "delogo" "ロゴファイルが見つかりません: $LOGO_FILE"
        log "ERROR: ロゴファイルが見つかりません: $LOGO_FILE"
        return 1
    fi

    if ! require_avs2y4m; then
        job_stage_fail "$MANIFEST" "delogo" "avs2y4m が見つかりません"
        return 1
    fi

    log "ロゴ消しAVS生成: $(basename "$LOGO_FILE")"
    if ! create_delogo_avs "$ENCODE_INPUT" "$LOGO_FILE" "$DELOGO_AVS" "${LOGO_POS_X:-}" "${LOGO_POS_Y:-}" >"$stage_log" 2>&1; then
        job_stage_fail "$MANIFEST" "delogo" "ロゴ消しAVS生成に失敗しました"
        return 1
    fi

    if [[ "${ENABLE_DELOGO_DEBUG:-false}" == "true" ]]; then
        create_delogo_debug_artifacts
    fi

    manifest_set "$MANIFEST" USE_DELOGO "true"
    job_stage_success "$MANIFEST" "delogo"
}

main
