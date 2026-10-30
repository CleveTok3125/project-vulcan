#!/bin/bash
set -Eeuo pipefail

# Input reaches Apollo through the socket shim, which is loaded only into
# Apollo. Sway has no input devices and no preload.
INPUT_TRANSPORT="${INPUT_TRANSPORT:-socket}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${XDG_RUNTIME_DIR}/pulse/native}"

if [ -z "${SWAYSOCK:-}" ]; then
    for _ in $(seq 1 100); do
        socket="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'sway-ipc.*.sock' | head -n 1 || true)"
        if [ -n "$socket" ]; then
            export SWAYSOCK="$socket"
            break
        fi
        sleep 0.1
    done
fi

if [ -z "${SWAYSOCK:-}" ]; then
    printf '[vulcan] Sway IPC socket not found\n' >&2
    exit 1
fi

for _ in $(seq 1 100); do
    if swaymsg -t get_outputs 2>/dev/null | jq -e '.[] | select(.name == "HEADLESS-1")' >/dev/null; then
        break
    fi
    sleep 0.1
done

if ! swaymsg -t get_outputs 2>/dev/null | jq -e '.[] | select(.name == "HEADLESS-1")' >/dev/null; then
    printf '[vulcan] HEADLESS-1 never appeared\n' >&2
    exit 1
fi

wayland_socket="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' | head -n 1 || true)"
if [ -z "$wayland_socket" ]; then
    printf '[vulcan] Wayland socket not found\n' >&2
    exit 1
fi

export WAYLAND_DISPLAY="$(basename "$wayland_socket")"
unset DISPLAY

if [ "$INPUT_TRANSPORT" = "socket" ]; then
    export VULCAN_INPUT_SOCKET="${VULCAN_INPUT_SOCKET:-${XDG_RUNTIME_DIR}/vulcan-input.sock}"
    if [ "${INPUT_GAMEPAD:-1}" = "1" ]; then
        export VULCAN_GAMEPAD_STATE="${VULCAN_GAMEPAD_STATE:-/data/prefix/drive_c/vulcan-gamepad.bin}"
    fi
    unset LD_PRELOAD
    /usr/local/bin/vulcan-inputd >>/data/log/vulcan-inputd.log 2>&1 &
    export LD_PRELOAD=/usr/lib/libvulcan_uinput_shim.so
    printf '[vulcan] socket input on %s\n' "$VULCAN_INPUT_SOCKET"
fi

printf '[vulcan] starting Apollo on %s (%s)\n' "$WAYLAND_DISPLAY" "$SWAYSOCK"
exec apollo /data/apollo/sunshine.conf
