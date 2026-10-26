#!/bin/bash
set -Eeuo pipefail

log() {
    printf '[vulcan] %s\n' "$*"
}

die() {
    log "$*"
    exit 1
}

GAME_UID="${GAME_UID:-1000}"
GAME_GID="${GAME_GID:-1000}"
export XDG_RUNTIME_DIR="/run/user/${GAME_UID}"
export XDG_CONFIG_HOME="/data/home/.config"
export XDG_CACHE_HOME="/data/home/.cache"
export XDG_DATA_HOME="/data/home/.local/share"
export HOME="/data/home"

install -d -m 0755 /data /data/apollo /data/apollo/credentials /data/home /data/log /data/prefix /data/overlay
install -d -m 0700 -o "$GAME_UID" -g "$GAME_GID" "$XDG_RUNTIME_DIR"
install -d -m 0755 /dev/input /run/udev /run/udev/data
touch /run/udev/control
chown -R "$GAME_UID:$GAME_GID" /data

if [ "${ENABLE_OVERLAY:-1}" = "1" ]; then
    if [ ! -d /games-ro/zzz ]; then
        die "missing /games-ro/zzz; mount the host game directory there"
    fi
    if [ ! -d /games/zzz ]; then
        die "missing /games/zzz mount point in the image"
    fi
    install -d -m 0755 /data/overlay/zzz /data/overlay/zzz/upper /data/overlay/zzz/work
    chown -R "$GAME_UID:$GAME_GID" /data/overlay
    if ! mountpoint -q /games/zzz; then
        mount -t overlay overlay \
            -o "lowerdir=/games-ro/zzz,upperdir=/data/overlay/zzz/upper,workdir=/data/overlay/zzz/work" \
            /games/zzz || die "failed to mount overlay for /games/zzz"
    fi
fi

read_gid() {
    stat -c '%g' "$1" 2>/dev/null || printf '0\n'
}

GID_INPUT="${GID_INPUT:-$(read_gid /dev/uinput)}"
GID_RENDER="${GID_RENDER:-$(read_gid /dev/dri/renderD128)}"
GID_VIDEO="${GID_VIDEO:-$(read_gid /dev/dri/renderD128)}"
GID_UINPUT="${GID_UINPUT:-$(read_gid /dev/uinput)}"
GID_SEAT="$(getent group seat | cut -d: -f3 || true)"

GROUP_LIST="$(
    printf '%s\n' "$GID_INPUT" "$GID_RENDER" "$GID_VIDEO" "$GID_UINPUT" "$GID_SEAT" \
        | awk '/^[0-9]+$/ && $1 != 0' \
        | sort -nu \
        | paste -sd, -
)"

as_game() {
    if [ -n "$GROUP_LIST" ]; then
        setpriv --reuid="$GAME_UID" --regid="$GAME_GID" --clear-groups --groups "$GROUP_LIST" -- "$@"
    else
        setpriv --reuid="$GAME_UID" --regid="$GAME_GID" --clear-groups -- "$@"
    fi
}

as_game dbus-daemon --session \
    --address="unix:path=${XDG_RUNTIME_DIR}/bus" \
    --fork --print-address=1 >/run/dbus-address
export DBUS_SESSION_BUS_ADDRESS="$(cat /run/dbus-address)"
export PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"

as_game env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    pipewire >/data/log/pipewire.log 2>&1 &
as_game env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    pipewire-pulse >/data/log/pipewire-pulse.log 2>&1 &
as_game env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    wireplumber >/data/log/wireplumber.log 2>&1 &

seatd -g seat >/data/log/seatd.log 2>&1 &

sleep 1

as_game env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PULSE_SERVER="$PULSE_SERVER" \
    bash -c '
        for _ in $(seq 1 50); do
            pactl info >/dev/null 2>&1 && break
            sleep 0.1
        done
        pactl load-module module-null-sink \
            sink_name=vulcan_game \
            sink_properties=device.description=vulcan_game >/dev/null 2>&1 || true
        pactl set-default-sink vulcan_game >/dev/null 2>&1 || true
    ' >/data/log/audio.log 2>&1 || true

if [ "${INPUT_BROKER:-1}" = "1" ]; then
    INPUT_GID="$GID_INPUT" python3 /usr/local/bin/input-broker.py \
        >/data/log/input-broker.log 2>&1 &
fi

APOLLO_ENCODER="${APOLLO_ENCODER:-nvenc}"
APOLLO_NAME="${APOLLO_NAME:-Vulcan-ZZZ}"
APOLLO_PORT="${APOLLO_PORT:-47989}"
APOLLO_ADAPTER="${APOLLO_ADAPTER:-}"
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"
GAME_WIDTH="${GAME_WIDTH:-1920}"
GAME_HEIGHT="${GAME_HEIGHT:-1080}"
GAME_FPS="${GAME_FPS:-144}"

install -d -m 0755 /data/hypr

sed \
    -e "s|@ENCODER@|${APOLLO_ENCODER}|g" \
    -e "s|@NAME@|${APOLLO_NAME}|g" \
    -e "s|@PORT@|${APOLLO_PORT}|g" \
    -e "s|@ADAPTER@|${APOLLO_ADAPTER}|g" \
    /config/apollo/sunshine.conf.in >/data/apollo/sunshine.conf

sed \
    -e "s|@RENDER_NODE@|${RENDER_NODE}|g" \
    -e "s|@GAME_WIDTH@|${GAME_WIDTH}|g" \
    -e "s|@GAME_HEIGHT@|${GAME_HEIGHT}|g" \
    -e "s|@GAME_FPS@|${GAME_FPS}|g" \
    /config/hypr/hyprland.lua.in >/data/hypr/hyprland.lua

if [ -z "$APOLLO_ADAPTER" ]; then
    sed -i '/^adapter_name = $/d' /data/apollo/sunshine.conf
fi

chown "$GAME_UID:$GAME_GID" /data/apollo/sunshine.conf /data/hypr/hyprland.lua

log "starting Hyprland"
as_game env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PULSE_SERVER="$PULSE_SERVER" \
    XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=Hyprland \
    LIBSEAT_BACKEND=seatd \
    SEATD_SOCK=/run/seatd.sock \
    AQ_NO_KMS_REQUIREMENT=1 \
    AQ_DRM_DEVICES="$RENDER_NODE" \
    Hyprland --config /data/hypr/hyprland.lua \
    >/data/log/hyprland.log 2>&1 &

HYPR_PID=$!
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM

log "Hyprland pid ${HYPR_PID}"
wait "$HYPR_PID" || true
