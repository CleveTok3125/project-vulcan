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

GAME_UID="${GAME_UID:-1000}"
GAME_GID="${GAME_GID:-1000}"
export XDG_RUNTIME_DIR="/run/user/${GAME_UID}"
export XDG_CONFIG_HOME="/data/home/.config"
export XDG_CACHE_HOME="/data/home/.cache"
export XDG_DATA_HOME="/data/home/.local/share"
export HOME="/data/home"

install -d -m 0755 /data
install -d -m 0755 -o "$GAME_UID" -g "$GAME_GID" \
    /data/apollo /data/apollo/credentials /data/home /data/log /data/prefix /data/overlay
install -d -m 0700 -o "$GAME_UID" -g "$GAME_GID" "$XDG_RUNTIME_DIR"
install -d -m 0755 /dev/input /run/udev /run/udev/data /run/udev/rules.d
install -d -m 0755 "$GAME_PATH"
if [ ! -e /var/run ] && [ ! -L /var/run ]; then
    ln -s /run /var/run
fi
if [ ! -e /run/udev/control ]; then
    touch /run/udev/control
fi
chown "$GAME_UID:$GAME_GID" /data
chown -R "$GAME_UID:$GAME_GID" /data/apollo /data/home /data/log /data/prefix /data/overlay

cleanup() {
    kill $(jobs -p) 2>/dev/null || true
}

trap cleanup EXIT INT TERM
INPUT_TRANSPORT="${INPUT_TRANSPORT:-socket}"
if [ "$INPUT_TRANSPORT" != "socket" ]; then
    die "only INPUT_TRANSPORT=socket is supported"
fi

if [ "${ENABLE_OVERLAY:-1}" = "1" ]; then
    if [ ! -d "$GAME_RO_PATH" ]; then
        die "missing ${GAME_RO_PATH}; mount the host game directory there"
    fi
    overlay_dir="/data/overlay/${GAME_ID}"
    install -d -m 0755 "$overlay_dir" "$overlay_dir/upper" "$overlay_dir/work"
    chown -R "$GAME_UID:$GAME_GID" /data/overlay
    if ! mountpoint -q "$GAME_PATH"; then
        mount -t overlay overlay \
            -o "lowerdir=${GAME_RO_PATH},upperdir=${overlay_dir}/upper,workdir=${overlay_dir}/work" \
            "$GAME_PATH" || die "failed to mount overlay for ${GAME_PATH}"
    fi
fi

read_gid() {
    stat -c '%g' "$1" 2>/dev/null || printf '0\n'
}

GID_INPUT="${GID_INPUT:-$(read_gid /dev/input)}"
GID_RENDER="${GID_RENDER:-$(read_gid /dev/dri/renderD128)}"
GID_VIDEO="${GID_VIDEO:-$(read_gid /dev/dri/renderD128)}"
GID_STORAGE="${GID_STORAGE:-$(read_gid /dev/dri/card0)}"
GID_SEAT="$(getent group seat | cut -d: -f3 || true)"

GROUP_LIST="$(
    printf '%s\n' "$GID_INPUT" "$GID_RENDER" "$GID_VIDEO" "$GID_STORAGE" "$GID_SEAT" \
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

as_game_netns() {
    if [ -n "$INPUT_NETNS" ]; then
        ip netns exec "$INPUT_NETNS" "${SETPRIV_CMD[@]}" "$@"
    else
        "${SETPRIV_CMD[@]}" "$@"
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

INPUT_BACKEND="${INPUT_BACKEND:-native}"
case "$INPUT_BACKEND" in
    native)
        SWAY_BACKENDS="headless,libinput"
        # libseat's noop backend opens /dev/input with the game user's
        # permissions. No seatd or logind is available in the container.
        # The preload grabs each event node opened by libinput so the host
        # compositor cannot consume the same stream input.
        SWAY_INPUT_ENV=(
            LIBSEAT_BACKEND=noop
            WLR_LIBINPUT_NO_DEVICES=1
            LD_PRELOAD=/usr/lib/libvulcan-input-grab.so
        )
        ;;
    xtest)
        SWAY_BACKENDS="headless"
        SWAY_INPUT_ENV=()
        ;;
    *)
        die "unsupported INPUT_BACKEND: $INPUT_BACKEND"
        ;;
esac

INPUT_NETNS=""
if [ "${INPUT_NETNS_ENABLED:-1}" = "1" ]; then
    INPUT_NETNS_NAME="${INPUT_NETNS_NAME:-vulcan-input}"
    ip netns del "$INPUT_NETNS_NAME" 2>/dev/null || true
    if ip netns add "$INPUT_NETNS_NAME" 2>/dev/null; then
        INPUT_NETNS="$INPUT_NETNS_NAME"
        log "broker and Sway run in netns ${INPUT_NETNS}"
    else
        log "failed to create input netns; broker udev events reach the host"
    fi
fi

if [ "${INPUT_BROKER:-1}" = "1" ]; then
    broker_cmd=(python3 /usr/local/bin/input-broker.py)
    if [ -n "$INPUT_NETNS" ]; then
        broker_cmd=(ip netns exec "$INPUT_NETNS" "${broker_cmd[@]}")
    fi
    INPUT_GID="$GID_INPUT" "${broker_cmd[@]}" \
        >/data/log/input-broker.log 2>&1 &
fi

if [ "$INPUT_BACKEND" = "xtest" ]; then
    INPUT_DISPLAY="${INPUT_DISPLAY:-}"
    if [ -z "$INPUT_DISPLAY" ]; then
        if [ "${GAMESCOPE_ENABLED:-1}" = "1" ]; then
            INPUT_DISPLAY=":2"
        else
            INPUT_DISPLAY=":1"
        fi
    fi
    : >/data/log/input-bridge.log
    (
        while true; do
            as_game env \
                XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
                DISPLAY="$INPUT_DISPLAY" \
                python3 /usr/local/bin/input-bridge.py \
                >>/data/log/input-bridge.log 2>&1 || true
            sleep 1
        done
    ) &
fi

APOLLO_ENCODER="${APOLLO_ENCODER:-nvenc}"
APOLLO_NAME="${APOLLO_NAME:-Vulcan-${GAME_ID}}"
APOLLO_PORT="${APOLLO_PORT:-47989}"
APOLLO_ADAPTER="${APOLLO_ADAPTER:-}"
APOLLO_OUTPUT="${APOLLO_OUTPUT:-HEADLESS-1}"
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"
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
    grep -v '^adapter_name = $' /data/apollo/sunshine.conf >/data/apollo/sunshine.conf.tmp
    mv /data/apollo/sunshine.conf.tmp /data/apollo/sunshine.conf
fi

chown "$GAME_UID:$GAME_GID" /data/apollo/sunshine.conf /data/apollo/apps.json /data/sway/config

log "starting Sway with ${SWAY_BACKENDS} (input: ${INPUT_BACKEND})"
as_game_netns env \
    "${SWAY_INPUT_ENV[@]}" \
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

# Apollo joins the host network namespace while Sway and the broker stay in
# the private one. Wayland and X11 sockets are filesystem objects, so the
# split does not affect capture or the game.
as_game env \
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
wait "$SWAY_PID" || true
