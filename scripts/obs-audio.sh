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
socket="$runtime_dir/pulse/native"
state_file="$runtime_dir/obs-audio.module"
source_name="vulcan-${session_id}-audio"

die() {
    printf '[vulcan] %s\n' "$*" >&2
    exit 1
}

read_module_id() {
    [ -f "$state_file" ] || return 1
    cat "$state_file"
}

module_present() {
    local module_id="$1"
    "$PACTL" list short modules 2>/dev/null \
        | awk -v id="$module_id" '$1 == id { found = 1 } END { exit !found }'
}

unload_module() {
    local module_id
    module_id="$(read_module_id)" || return 0
    if module_present "$module_id"; then
        if ! "$PACTL" unload-module "$module_id" 2>/dev/null; then
            printf '[vulcan] could not unload audio tunnel module %s\n' "$module_id" >&2
        fi
    fi
    rm -f "$state_file"
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

case "$action" in
    up)
        [ -S "$socket" ] || die "pulse socket not found: $socket"
        source_available || die "audio source not found: $AUDIO_SOURCE (start the Apollo stream first)"
        unload_module
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
        ;;
    down)
        unload_module
        ;;
    status)
        module_id="$(read_module_id 2>/dev/null || true)"
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
        ;;
    *)
        usage
        ;;
esac
