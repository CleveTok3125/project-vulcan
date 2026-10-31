#!/bin/bash
# Loads or removes the host Pulse source that follows a session's game audio.
set -Eeuo pipefail

usage() {
    printf 'usage: %s <up|down|status> <runtime-dir> <session-id>\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 3 ] || usage
action="$1"
runtime_dir="$2"
session_id="$3"

PACTL="${PACTL:-pactl}"
AUDIO_SOURCE="${AUDIO_SOURCE:-sink-sunshine-stereo.monitor}"
AUDIO_LATENCY_MSEC="${AUDIO_LATENCY_MSEC:-60}"
AUDIO_MONITOR="${AUDIO_MONITOR:-0}"
AUDIO_MONITOR_SINK="${AUDIO_MONITOR_SINK:-}"
AUDIO_MONITOR_LATENCY_MSEC="${AUDIO_MONITOR_LATENCY_MSEC:-100}"
socket="$runtime_dir/pulse/native"
state_file="$runtime_dir/obs-audio.module"
monitor_state_file="$runtime_dir/obs-audio-monitor.module"
monitor_sink_file="$runtime_dir/obs-audio-monitor.sink"
monitor_err="$runtime_dir/obs-audio-monitor.err"
source_name="vulcan-${session_id}-audio"

die() {
    printf '[vulcan] %s\n' "$*" >&2
    exit 1
}

read_module_id() {
    local file="$1"
    [ -f "$file" ] || return 1
    cat "$file"
}

module_present() {
    local module_id="$1"
    "$PACTL" list short modules 2>/dev/null \
        | awk -v id="$module_id" '$1 == id { found = 1 } END { exit !found }'
}

unload_state() {
    local file="$1" module_id
    module_id="$(read_module_id "$file")" || return 0
    if module_present "$module_id"; then
        if ! "$PACTL" unload-module "$module_id" 2>/dev/null; then
            printf '[vulcan] could not unload audio module %s\n' "$module_id" >&2
        fi
    fi
    rm -f "$file"
}

unload_monitor() {
    unload_state "$monitor_state_file"
    rm -f "$monitor_sink_file" "$monitor_err"
}

unload_tunnel() {
    unload_state "$state_file"
}

unload_modules() {
    unload_monitor
    unload_tunnel
}

source_available() {
    PULSE_SERVER="unix:${socket}" "$PACTL" list short sources 2>/dev/null \
        | awk -v target="$AUDIO_SOURCE" '$2 == target { found = 1 } END { exit !found }'
}

wait_for_source() {
    local attempts="${AUDIO_WAIT_ATTEMPTS:-50}"
    local attempt
    for ((attempt = 0; attempt < attempts; attempt++)); do
        source_available && return 0
        sleep 0.1
    done
    return 1
}

default_sink() {
    local sink
    sink="$("$PACTL" get-default-sink 2>/dev/null || true)"
    if [ -z "$sink" ]; then
        sink="$("$PACTL" info 2>/dev/null | sed -n 's/^Default Sink: //p' | head -n 1 || true)"
    fi
    printf '%s\n' "$sink"
}

sink_available() {
    "$PACTL" list short sinks 2>/dev/null \
        | awk -v target="$1" '$2 == target { found = 1 } END { exit !found }'
}

resolve_monitor_sink() {
    local sink
    sink="${AUDIO_MONITOR_SINK:-$(default_sink)}"
    [ -n "$sink" ] || die "no default sink; set AUDIO_MONITOR_SINK"
    if ! sink_available "$sink"; then
        die "audio monitor sink not found: $sink"
    fi
    printf '%s\n' "$sink"
}

case "$action" in
    up)
        [ -S "$socket" ] || die "pulse socket not found: $socket"
        source_available \
            || die "audio source not found: $AUDIO_SOURCE (start the audio producer first)"

        case "$AUDIO_MONITOR" in
            0|1) ;;
            *) die "AUDIO_MONITOR must be 0 or 1" ;;
        esac

        monitor_sink=""
        if [ "$AUDIO_MONITOR" = "1" ]; then
            if ! [[ "$AUDIO_MONITOR_LATENCY_MSEC" =~ ^[0-9]+$ ]]; then
                die "invalid AUDIO_MONITOR_LATENCY_MSEC: $AUDIO_MONITOR_LATENCY_MSEC"
            fi
            monitor_sink="$(resolve_monitor_sink)"
        fi

        unload_modules

        load_args=(
            module-tunnel-source
            "server=unix:${socket}"
            "source=${AUDIO_SOURCE}"
            "source_name=${source_name}"
            "latency_msec=${AUDIO_LATENCY_MSEC}"
        )
        if [ -n "${AUDIO_COOKIE:-}" ]; then
            load_args+=("cookie=${AUDIO_COOKIE}")
        fi
        if ! module_id="$($PACTL load-module "${load_args[@]}" 2>"$runtime_dir/obs-audio.err")"; then
            cat "$runtime_dir/obs-audio.err" >&2
            die "failed to load audio tunnel source"
        fi
        case "$module_id" in
            ''|*[!0-9]*)
                die "unexpected module id: $module_id"
                ;;
        esac
        printf '%s\n' "$module_id" >"$state_file"
        if ! wait_for_source; then
            "$PACTL" unload-module "$module_id" >/dev/null 2>&1 || true
            rm -f "$state_file"
            die "audio source did not appear: $source_name"
        fi
        printf '[vulcan] audio source %s -> %s (latency %sms)\n' "$source_name" "$AUDIO_SOURCE" "$AUDIO_LATENCY_MSEC"

        if [ "$AUDIO_MONITOR" = "1" ]; then
            monitor_args=(
                module-loopback
                "source=${source_name}"
                "sink=${monitor_sink}"
                "latency_msec=${AUDIO_MONITOR_LATENCY_MSEC}"
            )
            if ! monitor_id="$($PACTL load-module "${monitor_args[@]}" 2>"$monitor_err")"; then
                cat "$monitor_err" >&2
                printf '[vulcan] audio monitor failed; tunnel source %s remains active\n' \
                    "$source_name" >&2
                exit 1
            fi
            case "$monitor_id" in
                ''|*[!0-9]*)
                    die "unexpected monitor module id: $monitor_id"
                    ;;
            esac
            printf '%s\n' "$monitor_id" >"$monitor_state_file"
            printf '%s\n' "$monitor_sink" >"$monitor_sink_file"
            printf '[vulcan] audio monitor %s -> %s (latency %sms)\n' \
                "$source_name" "$monitor_sink" "$AUDIO_MONITOR_LATENCY_MSEC"
        fi
        ;;
    down)
        unload_modules
        rm -f "$runtime_dir/obs-audio.err"
        ;;
    status)
        module_id="$(read_module_id "$state_file" 2>/dev/null || true)"
        if [ -n "$module_id" ] && module_present "$module_id"; then
            printf 'module=%s\n' "$module_id"
        elif [ -n "$module_id" ]; then
            printf 'module=stale (%s)\n' "$module_id"
        else
            printf 'module=none\n'
        fi
        printf 'source=%s\n' "$source_name"
        source_line="$("$PACTL" list short sources 2>/dev/null | awk -v name="$source_name" '$2 == name { print }')"
        if [ -n "$source_line" ]; then
            printf '%s\n' "$source_line"
        else
            printf 'source=missing\n'
        fi

        monitor_id="$(read_module_id "$monitor_state_file" 2>/dev/null || true)"
        if [ -n "$monitor_id" ] && module_present "$monitor_id"; then
            printf 'monitor=%s\n' "$monitor_id"
        elif [ -n "$monitor_id" ]; then
            printf 'monitor=stale (%s)\n' "$monitor_id"
        else
            printf 'monitor=none\n'
        fi
        if [ -n "$monitor_id" ]; then
            printf 'monitor_sink=%s\n' "$(cat "$monitor_sink_file" 2>/dev/null || printf unknown)"
        fi
        ;;
    *)
        usage
        ;;
esac
