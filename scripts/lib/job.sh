#!/bin/bash
# Job manifest and lifecycle helpers.

source /scripts/lib/common.sh

JOBS_DIR="${JOBS_DIR:-${WORK_DIR:-/work}/jobs}"

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

lock_acquire() {
    local lock_dir="$1"
    local max_attempts="${2:-50}"
    local sleep_seconds="${3:-0.1}"
    local attempts=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge "$max_attempts" ]]; then
            return 1
        fi
        sleep "$sleep_seconds"
    done

    printf '%s\n' "$$" > "${lock_dir}/pid"
}

lock_release() {
    local lock_dir="$1"

    [[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
    rm -f "${lock_dir}/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}

manifest_lock_path() {
    local manifest="$1"
    printf '%s.lock' "$manifest"
}

job_cleanup_stale_manifest_locks() {
    local stale_lock

    shopt -s nullglob
    for stale_lock in "${JOBS_DIR}"/*/manifest.env.lock; do
        rm -rf "$stale_lock"
    done
    shopt -u nullglob
}

manifest_set() {
    local manifest="$1"
    local key="$2"
    local value="$3"
    local tmp
    local lock_dir
    local rc=0

    mkdir -p "$(dirname "$manifest")"
    lock_dir=$(manifest_lock_path "$manifest")

    if ! lock_acquire "$lock_dir"; then
        echo "ERROR: manifest lock を取得できません: $lock_dir" >&2
        return 1
    fi

    tmp="${manifest}.tmp.$$"

    if {
        if [[ -f "$manifest" ]]; then
            grep -v -E "^${key}=" "$manifest" > "$tmp" || true
        else
            : > "$tmp"
        fi

        printf '%s=%q\n' "$key" "$value" >> "$tmp"
        mv "$tmp" "$manifest"
    }; then
        rc=0
    else
        rc=$?
        rm -f "$tmp"
    fi

    lock_release "$lock_dir"
    return "$rc"
}

manifest_load() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 1
    # shellcheck disable=SC1090
    source "$manifest"
}

make_job_id() {
    local input_file="$1"
    local sum
    sum=$(printf '%s' "$input_file" | cksum | awk '{print $1}')
    printf '%s_%s_%s' "$(date '+%Y%m%d%H%M%S')" "$sum" "$$"
}

job_find_active() {
    local input_file="$1"
    local manifest

    shopt -s nullglob
    for manifest in "${JOBS_DIR}"/*/manifest.env; do
        unset INPUT_FILE JOB_STATUS
        if manifest_load "$manifest" && [[ "${INPUT_FILE:-}" == "$input_file" ]]; then
            case "${JOB_STATUS:-}" in
                success|failed) ;;
                *) dirname "$manifest"; shopt -u nullglob; return 0 ;;
            esac
        fi
    done
    shopt -u nullglob
    return 1
}

job_create() {
    local input_file="$1"
    local output_file="$2"
    local skip_cmcut="$3"
    local basename="$4"
    local job_id
    local job_dir
    local manifest

    job_id=$(make_job_id "$input_file")
    job_dir="${JOBS_DIR}/${job_id}"
    manifest="${job_dir}/manifest.env"
    mkdir -p "$job_dir"

    manifest_set "$manifest" JOB_ID "$job_id"
    manifest_set "$manifest" JOB_DIR "$job_dir"
    manifest_set "$manifest" JOB_STATUS "pending"
    manifest_set "$manifest" CREATED_AT "$(now_iso)"
    manifest_set "$manifest" UPDATED_AT "$(now_iso)"
    manifest_set "$manifest" INPUT_FILE "$input_file"
    manifest_set "$manifest" INPUT_BASENAME "$basename"
    manifest_set "$manifest" OUTPUT_FILE_FINAL "$output_file"
    manifest_set "$manifest" TEMP_OUTPUT_FILE "${job_dir}/encoded.tmp.mp4"
    manifest_set "$manifest" CMCUT_TS "${job_dir}/cmcut.ts"
    manifest_set "$manifest" ENCODE_INPUT "$input_file"
    manifest_set "$manifest" LOGO_FILE ""
    manifest_set "$manifest" LOGO_POS_X ""
    manifest_set "$manifest" LOGO_POS_Y ""
    manifest_set "$manifest" LOGO_DEBUG_FRAME ""
    manifest_set "$manifest" DELOGO_AVS "${job_dir}/delogo/delogo.avs"
    manifest_set "$manifest" SKIP_CMCUT "$skip_cmcut"
    manifest_set "$manifest" ENABLE_DELOGO "${ENABLE_DELOGO:-false}"
    manifest_set "$manifest" ENABLE_DELOGO_DEBUG "${ENABLE_DELOGO_DEBUG:-false}"
    manifest_set "$manifest" HAS_CMCUT "false"
    manifest_set "$manifest" USE_DELOGO "false"
    manifest_set "$manifest" STAGE_CMCUT "pending"
    manifest_set "$manifest" STAGE_DELOGO "pending"
    manifest_set "$manifest" STAGE_ENCODE "pending"
    manifest_set "$manifest" STAGE_VERIFY "pending"
    manifest_set "$manifest" FAILED_STAGE ""
    manifest_set "$manifest" FAILURE_REASON ""
    manifest_set "$manifest" LOG_CMCUT ""
    manifest_set "$manifest" LOG_DELOGO ""
    manifest_set "$manifest" LOG_DELOGO_DEBUG ""
    manifest_set "$manifest" LOG_ENCODE ""
    manifest_set "$manifest" LOG_VERIFY ""

    printf '%s' "$job_dir"
}

job_stage_begin() {
    local manifest="$1"
    local stage="$2"
    local key="STAGE_${stage^^}"

    manifest_set "$manifest" "$key" "running"
    manifest_set "$manifest" JOB_STATUS "running"
    manifest_set "$manifest" FAILED_STAGE ""
    manifest_set "$manifest" FAILURE_REASON ""
    manifest_set "$manifest" UPDATED_AT "$(now_iso)"
}

job_stage_success() {
    local manifest="$1"
    local stage="$2"
    local key="STAGE_${stage^^}"

    manifest_set "$manifest" "$key" "success"
    manifest_set "$manifest" UPDATED_AT "$(now_iso)"
}

job_stage_fail() {
    local manifest="$1"
    local stage="$2"
    local reason="$3"
    local key="STAGE_${stage^^}"

    manifest_set "$manifest" "$key" "failed"
    manifest_set "$manifest" JOB_STATUS "failed"
    manifest_set "$manifest" FAILED_STAGE "$stage"
    manifest_set "$manifest" FAILURE_REASON "$reason"
    manifest_set "$manifest" UPDATED_AT "$(now_iso)"
}

job_cleanup_failure() {
    local manifest="$1"
    manifest_load "$manifest" || return 0

    rm -f "${TEMP_OUTPUT_FILE:-}"
    if [[ -n "${CMCUT_TS:-}" ]]; then
        rm -f "$CMCUT_TS" "${CMCUT_TS}.logo"
    fi
}

job_cleanup_success() {
    local manifest="$1"
    manifest_load "$manifest" || return 0

    if [[ "${ENABLE_DELOGO_DEBUG:-false}" == "true" ]]; then
        log "ENABLE_DELOGO_DEBUG=true のためジョブ成果物を保持します: ${JOB_DIR:-}"
        return 0
    fi

    if [[ -n "${JOB_DIR:-}" && -d "$JOB_DIR" ]]; then
        rm -rf "$JOB_DIR"
    fi
}
