#!/bin/bash
set -euo pipefail

source /scripts/lib/common.sh
source /scripts/lib/media.sh
source /scripts/lib/job.sh

LOG_TAG="stage:verify"

MANIFEST="${1:?manifest path required}"
manifest_load "$MANIFEST"

VERIFY_WORK="${JOB_DIR}/verify"
mkdir -p "$VERIFY_WORK"

main() {
    local verify_log="${VERIFY_WORK}/verify.log"
    local input_duration=""
    local output_duration=""

    manifest_set "$MANIFEST" LOG_VERIFY "$verify_log"
    job_stage_begin "$MANIFEST" "verify"

    {
        echo "input=${ENCODE_INPUT}"
        echo "output=${TEMP_OUTPUT_FILE}"
    } > "$verify_log"

    if [[ ! -s "$TEMP_OUTPUT_FILE" ]]; then
        job_stage_fail "$MANIFEST" "verify" "出力MP4が存在しないか空です"
        return 1
    fi

    if ! has_video_stream "$TEMP_OUTPUT_FILE"; then
        job_stage_fail "$MANIFEST" "verify" "出力MP4に映像ストリームがありません"
        return 1
    fi

    if has_audio_stream "$ENCODE_INPUT" && ! has_audio_stream "$TEMP_OUTPUT_FILE"; then
        job_stage_fail "$MANIFEST" "verify" "入力に音声があるのに出力MP4に音声ストリームがありません"
        return 1
    fi

    if has_audio_stream "$ENCODE_INPUT" && ! audio_stream_decodes "$TEMP_OUTPUT_FILE" "$verify_log" 60; then
        job_stage_fail "$MANIFEST" "verify" "出力MP4の音声をデコードできません"
        return 1
    fi

    input_duration=$(get_duration_seconds "$ENCODE_INPUT" || echo "")
    output_duration=$(get_duration_seconds "$TEMP_OUTPUT_FILE" || echo "")
    {
        echo "input_duration=${input_duration}"
        echo "output_duration=${output_duration}"
    } >> "$verify_log"

    if [[ -z "$output_duration" ]] || ! duration_is_positive "$output_duration"; then
        job_stage_fail "$MANIFEST" "verify" "出力MP4の長さを確認できません"
        return 1
    fi

    if [[ -n "$input_duration" ]] && duration_is_positive "$input_duration"; then
        if ! duration_lte_with_slack "$output_duration" "$input_duration" 15; then
            job_stage_fail "$MANIFEST" "verify" "出力MP4が入力より不自然に長いです"
            return 1
        fi
    fi

    job_stage_success "$MANIFEST" "verify"
}

main
