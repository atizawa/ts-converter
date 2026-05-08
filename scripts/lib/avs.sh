#!/bin/bash
# AviSynth script generation helpers.

source /scripts/lib/common.sh

escape_avs_path() {
    local path="$1"
    path="${path//\\/\\\\}"
    path="${path//\"/\\\"}"
    printf '%s' "$path"
}

create_logoframe_avs() {
    local input_file="$1"
    local avs_file="$2"
    local escaped_input

    escaped_input=$(escape_avs_path "$input_file")

    {
        echo 'LoadPlugin("/usr/local/lib/libffms2.so")'
        echo "FFVideoSource(\"${escaped_input}\", seekmode=0)"
        echo 'ConvertToYV12(interlaced=true)'
    } > "$avs_file"
}

create_chapter_video_avs() {
    local input_file="$1"
    local avs_file="$2"
    local cache_file="$3"
    local escaped_input
    local escaped_cache

    escaped_input=$(escape_avs_path "$input_file")
    escaped_cache=$(escape_avs_path "$cache_file")

    {
        echo 'LoadPlugin("/usr/local/lib/libffms2.so")'
        echo "FFVideoSource(\"${escaped_input}\", cachefile=\"${escaped_cache}\", seekmode=0)"
        echo 'ConvertToYV12(interlaced=true)'
    } > "$avs_file"
}

create_audio_avs() {
    local input_file="$1"
    local avs_file="$2"
    local escaped_input

    escaped_input=$(escape_avs_path "$input_file")

    {
        echo 'LoadPlugin("/usr/local/lib/libffms2.so")'
        echo "FFAudioSource(\"${escaped_input}\")"
    } > "$avs_file"
}

read_lgd_position() {
    local logo_file="$1"

    od -An -j 64 -N 4 -tu2 "$logo_file" 2>/dev/null | awk '{print $1 "\t" $2}'
}

get_delogo_position_args() {
    local logo_file="$1"
    local detected_x="${2:-}"
    local detected_y="${3:-}"
    local lgd_pos
    local lgd_x
    local lgd_y
    local offset_x
    local offset_y

    if [[ -z "$detected_x" || -z "$detected_y" ]]; then
        return 0
    fi
    if [[ ! "$detected_x" =~ ^[0-9]+$ || ! "$detected_y" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    lgd_pos=$(read_lgd_position "$logo_file" || true)
    if [[ -z "$lgd_pos" ]]; then
        return 0
    fi

    IFS=$'\t' read -r lgd_x lgd_y <<< "$lgd_pos"
    if [[ ! "$lgd_x" =~ ^[0-9]+$ || ! "$lgd_y" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    offset_x=$((detected_x - lgd_x))
    offset_y=$((detected_y - lgd_y))
    printf ', pos_x=%s, pos_y=%s' "$offset_x" "$offset_y"
}

create_delogo_avs() {
    local input_file="$1"
    local logo_file="$2"
    local avs_file="$3"
    local logo_pos_x="${4:-}"
    local logo_pos_y="${5:-}"
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
        echo 'ConvertToYV12(interlaced=true)'
        echo "EraseLOGO(logofile=\"${escaped_logo}\"${position_args}, interlaced=true)"
    } > "$avs_file"
}

require_avs2y4m() {
    if ! command -v avs2y4m >/dev/null 2>&1; then
        log "ERROR: avs2y4m が見つかりません"
        return 1
    fi
}
