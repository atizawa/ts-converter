#!/bin/bash
set -euo pipefail

# Compatibility wrapper.
# Usage: cmcut.sh <input.ts> <output.ts>

source /scripts/lib/common.sh
source /scripts/lib/job.sh

LOG_TAG="cmcut"

INPUT_FILE="${1:?input TS required}"
OUTPUT_FILE="${2:?output TS required}"
WORK_DIR="${WORK_DIR:-/work}"
JOBS_DIR="${JOBS_DIR:-${WORK_DIR}/jobs}"
BASENAME="$(basename "${INPUT_FILE}" .ts)"
BASENAME="$(basename "$BASENAME" .TS)"
JOB_DIR="${JOBS_DIR}/manual_cmcut_$(date '+%Y%m%d%H%M%S')_$$"
MANIFEST="${JOB_DIR}/manifest.env"

mkdir -p "$JOB_DIR"

manifest_set "$MANIFEST" JOB_ID "$(basename "$JOB_DIR")"
manifest_set "$MANIFEST" JOB_DIR "$JOB_DIR"
manifest_set "$MANIFEST" JOB_STATUS "pending"
manifest_set "$MANIFEST" CREATED_AT "$(now_iso)"
manifest_set "$MANIFEST" UPDATED_AT "$(now_iso)"
manifest_set "$MANIFEST" INPUT_FILE "$INPUT_FILE"
manifest_set "$MANIFEST" INPUT_BASENAME "$BASENAME"
manifest_set "$MANIFEST" OUTPUT_FILE_FINAL ""
manifest_set "$MANIFEST" TEMP_OUTPUT_FILE ""
manifest_set "$MANIFEST" CMCUT_TS "$OUTPUT_FILE"
manifest_set "$MANIFEST" ENCODE_INPUT "$INPUT_FILE"
manifest_set "$MANIFEST" LOGO_FILE ""
manifest_set "$MANIFEST" DELOGO_AVS ""
manifest_set "$MANIFEST" SKIP_CMCUT "false"
manifest_set "$MANIFEST" ENABLE_DELOGO "${ENABLE_DELOGO:-false}"
manifest_set "$MANIFEST" HAS_CMCUT "false"
manifest_set "$MANIFEST" USE_DELOGO "false"
manifest_set "$MANIFEST" STAGE_CMCUT "pending"
manifest_set "$MANIFEST" STAGE_DELOGO "pending"
manifest_set "$MANIFEST" STAGE_ENCODE "pending"
manifest_set "$MANIFEST" STAGE_VERIFY "pending"
manifest_set "$MANIFEST" FAILED_STAGE ""
manifest_set "$MANIFEST" FAILURE_REASON ""

if /scripts/app/stages/cmcut.sh "$MANIFEST"; then
    if [[ "${KEEP_CMCUT_WORK:-false}" != "true" ]]; then
        rm -rf "$JOB_DIR"
    else
        log "デバッグ用にジョブディレクトリを保持: $JOB_DIR"
    fi
    exit 0
fi

log "ERROR: CMカット失敗。解析用ジョブディレクトリを保持: $JOB_DIR"
exit 1
