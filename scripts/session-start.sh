#!/bin/bash
set -Eeuo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${XDG_RUNTIME_DIR}/pulse/native}"

for _ in $(seq 1 100); do
    signature="$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n 1 || true)"
    if [ -n "$signature" ]; then
        export HYPRLAND_INSTANCE_SIGNATURE="$signature"
        break
    fi
    sleep 0.1
done

if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    printf '[vulcan] Hyprland instance not found\n' >&2
    exit 1
fi

for _ in $(seq 1 100); do
    if hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.name == "HEADLESS-0")' >/dev/null; then
        break
    fi
    sleep 0.1
done

if ! hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.name == "HEADLESS-0")' >/dev/null; then
    printf '[vulcan] HEADLESS-0 never appeared\n' >&2
    exit 1
fi

wayland_socket="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' | head -n 1 || true)"
if [ -z "$wayland_socket" ]; then
    printf '[vulcan] Wayland socket not found\n' >&2
    exit 1
fi

export WAYLAND_DISPLAY="$(basename "$wayland_socket")"
unset DISPLAY

printf '[vulcan] starting Apollo on %s\n' "$WAYLAND_DISPLAY"
exec apollo /data/apollo/sunshine.conf
