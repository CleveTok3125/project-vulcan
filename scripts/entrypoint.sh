#!/bin/bash
set -Eeuo pipefail

log() {
    printf '[vulcan] %s\n' "$*"
}

die() {
    log "$*"
    exit 1
}

# shellcheck source=config-lib.sh
source /usr/local/bin/config-lib.sh

GAME_ID="${GAME_ID:-}"
if ! is_valid_game_id "$GAME_ID"; then
    die "invalid GAME_ID '${GAME_ID}': use letters, digits, dot, dash, or underscore, starting with a letter or digit"
fi
GAME_PATH="/games/${GAME_ID}"
GAME_RO_PATH="/games-ro/${GAME_ID}"
RENDER_NODE="${RENDER_NODE:?set RENDER_NODE in the env file}"

GAME_UID="${GAME_UID:-1000}"
GAME_GID="${GAME_GID:-1000}"
export XDG_RUNTIME_DIR="/run/user/${GAME_UID}"
export XDG_CONFIG_HOME="/data/home/.config"
export XDG_CACHE_HOME="/data/home/.cache"
export XDG_DATA_HOME="/data/home/.local/share"
export HOME="/data/home"

install -d -m 0755 "$GAME_PATH"
if [ ! -e /var/run ] && [ ! -L /var/run ]; then
    ln -s /run /var/run
fi

cleanup() {
    kill $(jobs -p) 2>/dev/null || true
}

trap cleanup EXIT INT TERM
INPUT_TRANSPORT="${INPUT_TRANSPORT:-socket}"
if [ "$INPUT_TRANSPORT" != "socket" ]; then
    die "only INPUT_TRANSPORT=socket is supported"
fi

read_gid() {
    stat -c '%g' "$1" 2>/dev/null || printf '0\n'
}

GID_RENDER="${GID_RENDER:-$(read_gid "$RENDER_NODE")}"
GID_VIDEO="${GID_VIDEO:-$(read_gid "$RENDER_NODE")}"
GID_STORAGE="${GID_STORAGE:-$(read_gid /dev/dri/card0)}"
GID_SEAT="$(getent group seat | cut -d: -f3 || true)"

GROUP_LIST="$(
    printf '%s\n' "$GID_RENDER" "$GID_VIDEO" "$GID_STORAGE" "$GID_SEAT" \
        | awk '/^[0-9]+$/ && $1 != 0' \
        | sort -nu \
        | paste -sd, -
)"

SETPRIV_CMD=()
if [ -n "$GROUP_LIST" ]; then
    SETPRIV_CMD=(setpriv --reuid="$GAME_UID" --regid="$GAME_GID" --groups "$GROUP_LIST" --)
else
    SETPRIV_CMD=(setpriv --reuid="$GAME_UID" --regid="$GAME_GID" --clear-groups --)
fi

as_game() {
    "${SETPRIV_CMD[@]}" "$@"
}

# The volume belongs to the game user while the entrypoint runs as root.
# Create the runtime paths as that user so no chown (CAP_CHOWN) is needed.
if ! as_game test -w /data; then
    die "/data is not writable by uid ${GAME_UID}; fix the volume ownership"
fi
as_game install -d -m 0755 \
    /data/apollo /data/apollo/credentials /data/home /data/log /data/prefix /data/overlay

# A tmpfs mount gives the runtime directory the game user's ownership without
# a chown; sockets only need to live as long as the container.
install -d -m 0700 "$XDG_RUNTIME_DIR"
mount -t tmpfs -o "uid=${GAME_UID},gid=${GAME_GID},mode=0700,size=128m" tmpfs "$XDG_RUNTIME_DIR" \
    || die "failed to mount ${XDG_RUNTIME_DIR}"

if [ "${ENABLE_OVERLAY:-1}" = "1" ]; then
    if [ ! -d "$GAME_RO_PATH" ]; then
        die "missing ${GAME_RO_PATH}; mount the host game directory there"
    fi
    overlay_dir="/data/overlay/${GAME_ID}"
    as_game install -d -m 0755 "$overlay_dir" "$overlay_dir/upper" "$overlay_dir/work"
    if ! mountpoint -q "$GAME_PATH"; then
        mount -t overlay overlay \
            -o "lowerdir=${GAME_RO_PATH},upperdir=${overlay_dir}/upper,workdir=${overlay_dir}/work" \
            "$GAME_PATH" || die "failed to mount overlay for ${GAME_PATH}"
    fi
fi

as_game dbus-daemon --session \
    --address="unix:path=${XDG_RUNTIME_DIR}/bus" \
    --fork --print-address=1 >/run/dbus-address
export DBUS_SESSION_BUS_ADDRESS="$(cat /run/dbus-address)"
export PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"

"${SETPRIV_CMD[@]}" env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    pipewire >/data/log/pipewire.log 2>&1 &
"${SETPRIV_CMD[@]}" env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    pipewire-pulse >/data/log/pipewire-pulse.log 2>&1 &
"${SETPRIV_CMD[@]}" env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    wireplumber >/data/log/wireplumber.log 2>&1 &

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

# Input arrives over the socket shim and gamescope EIS, so Sway has no input
# devices of its own and only needs the headless backend.
SWAY_BACKENDS="headless"

APOLLO_ENCODER="${APOLLO_ENCODER:-nvenc}"
APOLLO_NAME="${APOLLO_NAME:-Vulcan-${GAME_ID}}"
APOLLO_PORT="${APOLLO_PORT:-47989}"
APOLLO_ADAPTER="${APOLLO_ADAPTER:-}"
APOLLO_OUTPUT="${APOLLO_OUTPUT:-HEADLESS-1}"
GAME_WIDTH="${GAME_WIDTH:-1920}"
GAME_HEIGHT="${GAME_HEIGHT:-1080}"
GAME_FPS="${GAME_FPS:-144}"
GAME_MODE="${GAME_WIDTH}x${GAME_HEIGHT}@${GAME_FPS}Hz"

# The app entry is generated from the image template. GAME_APP_UUID must stay
# stable for a given game, or clients lose the app's stored state.
APOLLO_APP_NAME="${GAME_APP_NAME:-${GAME_ID}}"
APOLLO_APP_UUID="${GAME_APP_UUID:-$(derive_app_uuid "$GAME_ID")}"
APOLLO_APP_CMD="/usr/local/bin/launch-game.sh"

install -d -m 0755 /data/sway
# Apollo rewrites its config and app list from the web UI, so create the files
# as the game user before root fills them in.
as_game sh -c 'rm -f /data/apollo/apps.json /data/apollo/sunshine.conf &&
    install -m 0644 /dev/null /data/apollo/apps.json &&
    install -m 0644 /dev/null /data/apollo/sunshine.conf'

render_apollo_apps /config/apollo/apps.json /data/apollo/apps.json \
    "$APOLLO_APP_NAME" "$APOLLO_APP_CMD" "$APOLLO_APP_UUID"

sed \
    -e "s|@ENCODER@|${APOLLO_ENCODER}|g" \
    -e "s|@NAME@|${APOLLO_NAME}|g" \
    -e "s|@PORT@|${APOLLO_PORT}|g" \
    -e "s|@ADAPTER@|${APOLLO_ADAPTER}|g" \
    -e "s|@OUTPUT@|${APOLLO_OUTPUT}|g" \
    /config/apollo/sunshine.conf.in >/data/apollo/sunshine.conf

sed \
    -e "s|@MODE@|${GAME_MODE}|g" \
    /config/sway/config.in >/data/sway/config

if [ -z "$APOLLO_ADAPTER" ]; then
    grep -v '^adapter_name = $' /data/apollo/sunshine.conf >/run/sunshine.conf
    cat /run/sunshine.conf >/data/apollo/sunshine.conf
    rm -f /run/sunshine.conf
fi

log "starting Sway with ${SWAY_BACKENDS}"
"${SETPRIV_CMD[@]}" env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PULSE_SERVER="$PULSE_SERVER" \
    XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=sway \
    XCURSOR_THEME=Adwaita \
    XCURSOR_SIZE=24 \
    WLR_BACKENDS="$SWAY_BACKENDS" \
    WLR_RENDER_DRM_DEVICE="$RENDER_NODE" \
    WLR_RENDERER_ALLOW_SOFTWARE=1 \
    sway -c /data/sway/config \
    >/data/log/sway.log 2>&1 &

SWAY_PID=$!

# Apollo runs in the container network namespace; Sway stays there too.
# Wayland and X11 sockets are filesystem objects, so capture is unaffected.
"${SETPRIV_CMD[@]}" env \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PULSE_SERVER="$PULSE_SERVER" \
    XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=sway \
    XCURSOR_THEME=Adwaita \
    XCURSOR_SIZE=24 \
    /usr/local/bin/session-start.sh \
    >>/data/log/sway.log 2>&1 &

log "Sway pid ${SWAY_PID}"
# Root privileges are no longer needed; keep the session alive as the game
# user and exit when Sway does. `wait` cannot be used after the exec because
# the new shell has no job table.
exec setpriv --reuid="$GAME_UID" --regid="$GAME_GID" --clear-groups \
    tail --pid="$SWAY_PID" -f /dev/null
