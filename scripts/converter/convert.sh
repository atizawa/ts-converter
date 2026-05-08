#!/bin/bash
set -euo pipefail

source /scripts/lib/common.sh
source /scripts/lib/job.sh

LOG_TAG="convert"

INPUT_DIR="/input"
NOCMCUT_DIR="/input/nocmcut"
OUTPUT_DIR="/output"
WORK_DIR="/work"
JOBS_DIR="${WORK_DIR}/jobs"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
ENABLE_DELOGO="${ENABLE_DELOGO:-false}"

basename_without_ts() {
    local file="$1"
    local name
    name="$(basename "${file}" .ts)"
    basename "$name" .TS
}

stage_status_var() {
    local stage="$1"
    printf 'STAGE_%s' "${stage^^}"
}

run_stage_if_needed() {
    local manifest="$1"
    local stage="$2"
    local status_key
    local status

    manifest_load "$manifest"
    status_key=$(stage_status_var "$stage")
    status="${!status_key:-pending}"

    if [[ "$status" == "success" ]]; then
        log "  stage ${stage}: success済み"
        return 0
    fi

    log "  stage ${stage}: 実行"
    "/scripts/app/stages/${stage}.sh" "$manifest"
}

fail_job() {
    local manifest="$1"
    local marker_failed="$2"

    touch "$marker_failed"
    job_cleanup_failure "$manifest"
    manifest_load "$manifest" || true
    log "=== 変換失敗: ${INPUT_BASENAME:-unknown} (${FAILED_STAGE:-unknown}: ${FAILURE_REASON:-unknown}) ==="
}

mark_cmcut_skipped() {
    local manifest="$1"

    manifest_set "$manifest" STAGE_CMCUT "success"
    manifest_set "$manifest" HAS_CMCUT "false"
    manifest_load "$manifest"
    manifest_set "$manifest" ENCODE_INPUT "$INPUT_FILE"
}

finalize_success() {
    local manifest="$1"
    local marker_done="$2"

    manifest_load "$manifest"
    mkdir -p "$(dirname "$OUTPUT_FILE_FINAL")"

    if [[ -f "$OUTPUT_FILE_FINAL" ]]; then
        rm -f "$TEMP_OUTPUT_FILE"
    else
        mv "$TEMP_OUTPUT_FILE" "$OUTPUT_FILE_FINAL"
    fi

    manifest_set "$manifest" JOB_STATUS "success"
    manifest_set "$manifest" UPDATED_AT "$(now_iso)"
    cp "$manifest" "${OUTPUT_DIR}/.job_${INPUT_BASENAME}.manifest"
    touch "$marker_done"
    log "=== 変換完了: ${INPUT_BASENAME}.mp4 ==="
    job_cleanup_success "$manifest"
}

convert_file() {
    local input_file="$1"
    local skip_cmcut="$2"
    local basename
    local marker_done
    local marker_failed
    local processing_lock
    local output_file
    local job_dir
    local manifest

    basename="$(basename_without_ts "$input_file")"
    marker_done="${OUTPUT_DIR}/.done_${basename}"
    marker_failed="${OUTPUT_DIR}/.failed_${basename}"
    processing_lock="${WORK_DIR}/.processing_${basename}.lock"
    output_file="${OUTPUT_DIR}/${basename}.mp4"

    [[ -f "$marker_done" ]] && return 0
    [[ -f "$marker_failed" ]] && return 0

    if [[ -f "$output_file" ]]; then
        touch "$marker_done"
        return 0
    fi

    if ! lock_acquire "$processing_lock" 1; then
        return 0
    fi

    if job_dir=$(job_find_active "$input_file"); then
        log "=== ジョブ再開: ${basename} ($(basename "$job_dir")) ==="
    else
        job_dir=$(job_create "$input_file" "$output_file" "$skip_cmcut" "$basename")
        log "=== 変換開始: ${basename} ($(basename "$job_dir")) ==="
    fi

    manifest="${job_dir}/manifest.env"

    if [[ "$skip_cmcut" == "true" ]]; then
        log "  CMカットスキップ"
        mark_cmcut_skipped "$manifest"
    else
        if ! run_stage_if_needed "$manifest" "cmcut"; then
            fail_job "$manifest" "$marker_failed"
            lock_release "$processing_lock"
            return 0
        fi
    fi

    if ! run_stage_if_needed "$manifest" "delogo"; then
        fail_job "$manifest" "$marker_failed"
        lock_release "$processing_lock"
        return 0
    fi

    if ! run_stage_if_needed "$manifest" "encode"; then
        fail_job "$manifest" "$marker_failed"
        lock_release "$processing_lock"
        return 0
    fi

    if ! run_stage_if_needed "$manifest" "verify"; then
        fail_job "$manifest" "$marker_failed"
        lock_release "$processing_lock"
        return 0
    fi

    finalize_success "$manifest" "$marker_done"
    lock_release "$processing_lock"
}

log "中断ファイルのクリーンアップ..."
rm -f "${WORK_DIR}"/.converting_*.mp4
shopt -s nullglob
for stale_lock in "${WORK_DIR}"/.processing_*.lock; do
    rm -rf "$stale_lock"
done
for stale_file in "${WORK_DIR}"/.processing_*; do
    [[ -d "$stale_file" ]] && continue
    rm -f "$stale_file"
done
shopt -u nullglob
job_cleanup_stale_manifest_locks

mkdir -p "$NOCMCUT_DIR" "$OUTPUT_DIR" "$WORK_DIR" "$JOBS_DIR"

log "========================================="
log " TS Converter 起動"
log " 監視間隔: ${POLL_INTERVAL}秒"
log " 画質: CRF=${CRF:-20}, preset=${PRESET:-slow}"
log " ロゴ消し: ${ENABLE_DELOGO}"
log " 入力: ${INPUT_DIR}/"
log " 出力: ${OUTPUT_DIR}/"
log " ジョブ: ${JOBS_DIR}/"
log "========================================="

while true; do
    shopt -s nullglob
    for f in "${INPUT_DIR}"/*.ts "${INPUT_DIR}"/*.TS; do
        convert_file "$f" "false"
    done

    for f in "${NOCMCUT_DIR}"/*.ts "${NOCMCUT_DIR}"/*.TS; do
        convert_file "$f" "true"
    done
    shopt -u nullglob

    sleep "$POLL_INTERVAL"
done
