#!/bin/bash
# Media probing and ffmpeg option helpers.

source /scripts/lib/common.sh

has_video_stream() {
    local file="$1"
    local stream
    stream=$(ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=index \
        -of csv=p=0 "$file" 2>/dev/null || echo "")
    [[ -n "$stream" ]]
}

has_audio_stream() {
    local file="$1"
    local stream
    stream=$(ffprobe -v quiet -select_streams a:0 \
        -show_entries stream=index \
        -of csv=p=0 "$file" 2>/dev/null || echo "")
    [[ -n "$stream" ]]
}

is_dual_mono() {
    local file="$1"
    local layout
    layout=$(ffprobe -v quiet -select_streams a:0 \
        -show_entries stream=channel_layout \
        -of csv=p=0 "$file" 2>/dev/null || echo "")

    if [[ "$layout" == "dual_mono" ]] || [[ "$layout" == "downmix" ]]; then
        return 0
    fi

    local service_type
    service_type=$(ffprobe -v quiet -select_streams a:0 \
        -show_entries stream_tags=service_type \
        -of csv=p=0 "$file" 2>/dev/null || echo "")

    [[ "$service_type" == *"dual_mono"* ]]
}

get_audio_opts() {
    local file="$1"
    local work_dir="${2:-/tmp}"
    local bitrate

    if ! has_audio_stream "$file"; then
        echo "-an"
        return 0
    fi

    if is_dual_mono "$file"; then
        log "  デュアルモノラル検出 -> 左ch(日本語)を抽出"
        echo "-af pan=mono|c0=FL -c:a aac -b:a 192k -ar 48000"
    elif audio_copy_is_usable "$file" "$work_dir"; then
        log "  音声はコピー（無劣化）"
        echo "-c:a copy -bsf:a aac_adtstoasc"
    else
        bitrate=$(get_audio_reencode_bitrate "$file")
        log "  音声コピー不可 -> AACへ再エンコード (${bitrate})"
        echo "-c:a aac -b:a ${bitrate} -ar 48000"
    fi
}

audio_copy_is_usable() {
    local file="$1"
    local work_dir="$2"
    local probe_file="${work_dir}/audio_copy_probe.m4a"
    local probe_log="${work_dir}/audio_copy_probe.log"

    mkdir -p "$work_dir"
    rm -f "$probe_file" "$probe_log"

    if ! ffmpeg -nostdin -v warning -i "$file" \
        -map 0:a:0 -vn -sn -dn \
        -c:a copy \
        -bsf:a aac_adtstoasc \
        -movflags +faststart \
        -y "$probe_file" >"$probe_log" 2>&1; then
        log "  音声コピー試験に失敗しました: $probe_log"
        return 1
    fi

    if ! ffmpeg -nostdin -v error -i "$probe_file" \
        -map 0:a:0 -f null - >>"$probe_log" 2>&1; then
        log "  音声コピー試験のデコード検証に失敗しました: $probe_log"
        return 1
    fi

    if grep -Eqi 'aac_adtstoasc|ADTS|bitstream error|Invalid data found|not implemented|Error applying bitstream filters|Input buffer exhausted|channel element .* is not allocated' "$probe_log"; then
        log "  音声コピー試験でAACエラーを検出しました: $probe_log"
        return 1
    fi

    return 0
}

audio_stream_decodes() {
    local file="$1"
    local log_file="$2"
    local duration="${3:-60}"

    ffmpeg -nostdin -v error -i "$file" \
        -map 0:a:0 -t "$duration" -f null - >>"$log_file" 2>&1
}

get_audio_bitrate_bps() {
    local file="$1"
    ffprobe -v quiet -select_streams a:0 \
        -show_entries stream=bit_rate \
        -of csv=p=0 "$file" 2>/dev/null | head -1
}

get_audio_reencode_bitrate() {
    local file="$1"
    local bitrate_bps
    local bitrate_kbps

    bitrate_bps=$(get_audio_bitrate_bps "$file" || echo "")
    if [[ -z "$bitrate_bps" || ! "$bitrate_bps" =~ ^[0-9]+$ || "$bitrate_bps" -le 0 ]]; then
        echo "256k"
        return 0
    fi

    bitrate_kbps=$(((bitrate_bps + 999) / 1000))
    if [[ "$bitrate_kbps" -le 192 ]]; then
        echo "192k"
    elif [[ "$bitrate_kbps" -le 256 ]]; then
        echo "256k"
    elif [[ "$bitrate_kbps" -le 320 ]]; then
        echo "320k"
    elif [[ "$bitrate_kbps" -le 384 ]]; then
        echo "384k"
    else
        echo "$((((bitrate_kbps + 63) / 64) * 64))k"
    fi
}

get_video_filter_opts() {
    local file="$1"
    local sar
    local sar_expr
    local field_order
    local filters=()

    field_order=$(ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=field_order \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 || echo "")

    case "$field_order" in
        tt|bb|tb|bt)
            log "  インターレース検出 (${field_order}) -> bwdif を適用"
            filters+=("bwdif=mode=send_frame:parity=auto:deint=all")
            ;;
    esac

    sar=$(ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=sample_aspect_ratio \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | sed -n -E '/^[0-9]+:[0-9]+$/p' | head -1 || echo "")

    if [[ -n "$sar" && "$sar" != "0:1" && "$sar" != "1:0" && "$sar" != "0:0" ]]; then
        log "  入力SARを保持: ${sar}"
        sar_expr="${sar/:/\/}"
        filters+=("setsar=${sar_expr}")
    else
        filters+=("setsar=1")
    fi

    local IFS=,
    echo "-vf ${filters[*]}"
}

get_frame_rate_fraction() {
    local file="$1"
    ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of csv=p=0 "$file" 2>/dev/null | sed 's/,.*//' | head -1
}

get_duration_seconds() {
    local file="$1"
    ffprobe -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1
}

duration_is_positive() {
    local duration="$1"
    awk -v d="$duration" 'BEGIN { exit !(d + 0 > 0) }'
}

duration_lte_with_slack() {
    local value="$1"
    local limit="$2"
    local slack="${3:-10}"
    awk -v v="$value" -v l="$limit" -v s="$slack" 'BEGIN { exit !(v + 0 <= l + s) }'
}
