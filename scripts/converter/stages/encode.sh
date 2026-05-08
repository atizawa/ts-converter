#!/bin/bash
set -euo pipefail

source /scripts/lib/common.sh
source /scripts/lib/media.sh
source /scripts/lib/job.sh

LOG_TAG="stage:encode"

MANIFEST="${1:?manifest path required}"
manifest_load "$MANIFEST"

CRF="${CRF:-20}"
PRESET="${PRESET:-slow}"
ENCODE_WORK="${JOB_DIR}/encode"
mkdir -p "$ENCODE_WORK"

run_ffmpeg_direct() {
    local source_file="$1"
    local output_file="$2"
    local audio_opts="$3"
    local video_filter_opts="$4"
    local log_file="$5"

    ffmpeg -nostdin -i "$source_file" \
        -map 0:v:0 -map 0:a:0? -map 0:s? \
        -c:v libx265 \
        $video_filter_opts \
        -crf "$CRF" \
        -preset "$PRESET" \
        -profile:v main \
        -level:v 4.1 \
        -tag:v hvc1 \
        -pix_fmt yuv420p \
        $audio_opts \
        -c:s mov_text \
        -movflags +faststart \
        -y \
        "$output_file" >"$log_file" 2>&1
}

run_ffmpeg_delogo() {
    local source_file="$1"
    local avs_file="$2"
    local output_file="$3"
    local audio_opts="$4"
    local video_filter_opts="$5"
    local log_file="$6"

    (avs2y4m "$avs_file" | ffmpeg -nostdin -f yuv4mpegpipe -i - -i "$source_file" \
        -map 0:v:0 -map 1:a:0? -map 1:s? \
        -c:v libx265 \
        $video_filter_opts \
        -crf "$CRF" \
        -preset "$PRESET" \
        -profile:v main \
        -level:v 4.1 \
        -tag:v hvc1 \
        -pix_fmt yuv420p \
        $audio_opts \
        -c:s mov_text \
        -movflags +faststart \
        -y \
        "$output_file") >"$log_file" 2>&1
}

main() {
    local ffmpeg_log="${ENCODE_WORK}/ffmpeg.log"
    local audio_opts
    local video_filter_opts

    manifest_set "$MANIFEST" LOG_ENCODE "$ffmpeg_log"
    job_stage_begin "$MANIFEST" "encode"
    rm -f "$TEMP_OUTPUT_FILE"

    if [[ ! -f "$ENCODE_INPUT" ]]; then
        job_stage_fail "$MANIFEST" "encode" "エンコード入力が見つかりません: $ENCODE_INPUT"
        return 1
    fi

    audio_opts=$(get_audio_opts "$ENCODE_INPUT" "$ENCODE_WORK")
    video_filter_opts=$(get_video_filter_opts "$ENCODE_INPUT")
    log "エンコード中 (CRF=${CRF}, preset=${PRESET})..."

    if [[ "${USE_DELOGO:-false}" == "true" ]]; then
        if [[ ! -f "$DELOGO_AVS" ]]; then
            job_stage_fail "$MANIFEST" "encode" "delogo AVSが見つかりません: $DELOGO_AVS"
            return 1
        fi

        if ! run_ffmpeg_delogo "$ENCODE_INPUT" "$DELOGO_AVS" "$TEMP_OUTPUT_FILE" "$audio_opts" "$video_filter_opts" "$ffmpeg_log"; then
            job_stage_fail "$MANIFEST" "encode" "ffmpeg delogo エンコードに失敗しました"
            return 1
        fi
    else
        if ! run_ffmpeg_direct "$ENCODE_INPUT" "$TEMP_OUTPUT_FILE" "$audio_opts" "$video_filter_opts" "$ffmpeg_log"; then
            job_stage_fail "$MANIFEST" "encode" "ffmpeg エンコードに失敗しました"
            return 1
        fi
    fi

    if [[ ! -s "$TEMP_OUTPUT_FILE" ]]; then
        job_stage_fail "$MANIFEST" "encode" "エンコード出力が空です"
        return 1
    fi

    job_stage_success "$MANIFEST" "encode"
}

main
