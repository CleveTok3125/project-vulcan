#!/bin/bash
# Verifies the host-side Pulse tunnel source used by OBS audio capture.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/obs-audio.sh"
compose="$repo_root/compose.yaml"
entrypoint="$repo_root/scripts/entrypoint.sh"
makefile="$repo_root/Makefile"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0

check_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in %s\n' "$label" "$needle" "$file" >&2
        failures=$((failures + 1))
    fi
}

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

check_contains 'compose mounts the audio runtime' 'AUDIO_RUNTIME_DIR' "$compose"
check_contains 'entrypoint isolates the pulse socket' 'PULSE_RUNTIME_PATH' "$entrypoint"
check_contains 'make exposes audio-up' 'audio-up' "$makefile"
check_contains 'make exposes audio-down' 'audio-down' "$makefile"
check_contains 'make tears down audio on session stop' '_audio-teardown' "$makefile"

mkdir -p "$workdir/bin" "$workdir/runtime"
cat >"$workdir/bin/pactl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PACTL_LOG:?}"
case "$1" in
    load-module)
        case "$2" in
            module-loopback)
                if [ "${FAIL_LOOPBACK:-0}" = "1" ]; then
                    printf 'loopback failed\n' >&2
                    exit 1
                fi
                printf '43\n'
                ;;
            *) printf '42\n' ;;
        esac
        ;;
    unload-module) exit 0 ;;
    get-default-sink) printf '%s\n' "${DEFAULT_SINK:-alsa_output.test}" ;;
    info) printf 'Default Sink: %s\n' "${DEFAULT_SINK:-alsa_output.test}" ;;
    list)
        case "$3" in
            modules)
                if [ "${MODULE_PRESENT:-1}" != "0" ]; then
                    printf '42\tmodule-tunnel-source\tserver=unix:test\n'
                fi
                if [ "${MONITOR_PRESENT:-1}" != "0" ]; then
                    printf '43\tmodule-loopback\tsource=vulcan-demo-audio\n'
                fi
                ;;
            sources)
                if [ "${NO_SOURCE:-0}" != "1" ]; then
                    printf '1\tsink-sunshine-stereo.monitor\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n'
                    printf '2\tvulcan_game.monitor\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n'
                fi
                ;;
            sinks)
                if [ "${NO_SINK:-0}" != "1" ]; then
                    printf '0\t%s\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n' "${SINK_NAME:-alsa_output.test}"
                fi
                ;;
        esac
        ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$workdir/bin/pactl"

socket="$workdir/runtime/pulse/native"
mkdir -p "$(dirname "$socket")"
python3 - "$socket" <<'PY'
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
PY

PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo
check 'module id is stored' '42' "$(cat "$workdir/runtime/obs-audio.module")"
check_contains 'module is a tunnel source' 'module-tunnel-source' "$workdir/pactl.log"
check_contains 'tunnel points at the container socket' \
    "server=unix:$socket" "$workdir/pactl.log"
check_contains 'tunnel reads the game monitor' 'source=sink-sunshine-stereo.monitor' "$workdir/pactl.log"
check_contains 'source name is session scoped' 'source_name=vulcan-demo-audio' "$workdir/pactl.log"

PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo
check_contains 'down unloads the module' 'unload-module 42' "$workdir/pactl.log"
check 'down removes the module id' 'no' "$([ -e "$workdir/runtime/obs-audio.module" ] && printf yes || printf no)"

# The container's stable sink works without an Apollo stream.
: >"$workdir/pactl.log"
AUDIO_SOURCE=vulcan_game.monitor PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo
check_contains 'stable sink is accepted as the source' \
    'source=vulcan_game.monitor' "$workdir/pactl.log"
PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo

# Host speaker monitoring adds a loopback from the tunnel source.
: >"$workdir/pactl.log"
AUDIO_MONITOR=1 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo
check 'monitor module id is stored' '43' "$(cat "$workdir/runtime/obs-audio-monitor.module")"
check 'monitor sink is stored' 'alsa_output.test' "$(cat "$workdir/runtime/obs-audio-monitor.sink")"
check_contains 'monitor is a loopback' 'module-loopback' "$workdir/pactl.log"
check_contains 'monitor reads the tunnel source' 'source=vulcan-demo-audio' "$workdir/pactl.log"
check_contains 'monitor uses the default sink' 'sink=alsa_output.test' "$workdir/pactl.log"
check_contains 'monitor uses the configured latency' 'latency_msec=100' "$workdir/pactl.log"

PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" status "$workdir/runtime" demo >"$workdir/monitor-status.out"
check_contains 'status reports the monitor module' 'monitor=43' "$workdir/monitor-status.out"
check_contains 'status reports the monitor sink' 'monitor_sink=alsa_output.test' "$workdir/monitor-status.out"

PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo
check_contains 'down unloads the monitor' 'unload-module 43' "$workdir/pactl.log"
check 'down removes the monitor module id' 'no' "$([ -e "$workdir/runtime/obs-audio-monitor.module" ] && printf yes || printf no)"
check 'down removes the monitor sink' 'no' "$([ -e "$workdir/runtime/obs-audio-monitor.sink" ] && printf yes || printf no)"

# An explicit sink and latency override the defaults.
: >"$workdir/pactl.log"
AUDIO_MONITOR=1 AUDIO_MONITOR_SINK=speakers AUDIO_MONITOR_LATENCY_MSEC=50 \
    SINK_NAME=speakers PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo
check_contains 'monitor accepts an explicit sink' 'sink=speakers' "$workdir/pactl.log"
check_contains 'monitor accepts an explicit latency' 'latency_msec=50' "$workdir/pactl.log"
PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo

# Disabling the monitor removes a stale loopback without reloading it.
AUDIO_MONITOR=1 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null
: >"$workdir/pactl.log"
AUDIO_MONITOR=0 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null
check_contains 'disabled monitor unloads the old module' 'unload-module 43' "$workdir/pactl.log"
check 'disabled monitor leaves no monitor state' 'no' \
    "$([ -e "$workdir/runtime/obs-audio-monitor.module" ] && printf yes || printf no)"
check_contains 'disabled monitor keeps the tunnel' 'module-tunnel-source' "$workdir/pactl.log"
PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo

# A loopback failure keeps the OBS tunnel available.
: >"$workdir/pactl.log"
set +e
FAIL_LOOPBACK=1 AUDIO_MONITOR=1 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null 2>"$workdir/loopback-failure.log"
status=$?
set -e
check 'loopback failure exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'loopback failure keeps the tunnel' '42' "$(cat "$workdir/runtime/obs-audio.module")"
check 'loopback failure leaves no monitor state' 'no' \
    "$([ -e "$workdir/runtime/obs-audio-monitor.module" ] && printf yes || printf no)"
check_contains 'loopback failure is reported' 'audio monitor failed' "$workdir/loopback-failure.log"
PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" down "$workdir/runtime" demo

# A missing default sink is rejected before any module is loaded.
: >"$workdir/pactl.log"
set +e
AUDIO_MONITOR=1 NO_SINK=1 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null 2>"$workdir/missing-sink.log"
status=$?
set -e
check 'missing monitor sink exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check_contains 'missing monitor sink is reported' 'audio monitor sink not found' "$workdir/missing-sink.log"

# A missing socket means the container audio server is not ready.
rm -f "$socket"
set +e
PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null 2>"$workdir/missing.log"
status=$?
set -e
check 'missing pulse socket exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check_contains 'missing pulse socket is reported' 'pulse socket not found' \
    "$workdir/missing.log"

# Stale state is discarded instead of warning about a missing module.
python3 - "$socket" <<'PY'
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
PY
printf '99\n' >"$workdir/runtime/obs-audio.module"
MODULE_PRESENT=0 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null 2>"$workdir/stale.log"
check 'stale module is replaced' '42' "$(cat "$workdir/runtime/obs-audio.module")"
check 'stale module does not warn' '0' "$(grep -c 'could not unload' "$workdir/stale.log")"

# Status distinguishes stale state from a live module.
printf '99\n' >"$workdir/runtime/obs-audio.module"
NO_SOURCE=1 MODULE_PRESENT=0 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" status "$workdir/runtime" demo >"$workdir/status.out"
check_contains 'status reports a stale module' 'module=stale (99)' "$workdir/status.out"
check_contains 'status reports a missing source' 'source=missing' "$workdir/status.out"
rm -f "$workdir/runtime/obs-audio.module"

# A missing Sunshine sink means the Apollo stream has not started.
NO_SOURCE=1 PACTL_LOG="$workdir/pactl.log" PACTL="$workdir/bin/pactl" \
    "$script" up "$workdir/runtime" demo >/dev/null 2>"$workdir/no-source.log" || true
check_contains 'missing audio source is reported' 'audio source not found' "$workdir/no-source.log"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
