#!/bin/bash
# Opens Eden without launching a game.
#
# The window is the session's only way to install updates and DLC, add the
# Cemuhook UDP controller server, and map its buttons. Everything it prepares
# stays in the session volume.
set -Eeuo pipefail

# shellcheck source=game-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/game-lib.sh"

GAMES_CATALOG_PATH="${GAMES_CATALOG_PATH:-/config/games/games.json}"
VULCAN_RUN_DIR="${VULCAN_RUN_DIR:-/data/run}"

validate_games_catalog "$GAMES_CATALOG_PATH" || exit 1
if ! catalog_has_eden_runner "$GAMES_CATALOG_PATH"; then
    printf '[vulcan] no eden entry in the catalog\n' >&2
    exit 1
fi

install -d -m 0755 "$VULCAN_RUN_DIR"
exec 9>"$VULCAN_RUN_DIR/game.lock"
if ! flock -n 9; then
    printf '[vulcan] another game is already running\n' >&2
    exit 1
fi

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/data/home/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/data/home/.cache}"
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}"

eden_bin="${EDEN_BIN:-eden}"
if ! command -v "$eden_bin" >/dev/null 2>&1; then
    printf '[vulcan] eden not found: %s\n' "$eden_bin" >&2
    exit 1
fi

dsud_pid=""
if [ "${VULCAN_DSUD:-1}" = "1" ]; then
    dsud_bin="${VULCAN_DSUD_BIN:-/usr/local/bin/vulcan-dsud}"
    if [ -x "$dsud_bin" ]; then
        "$dsud_bin" \
            --pad-file "${VULCAN_GAMEPAD_STATE:-/data/vulcan-gamepad.bin}" \
            --port "${VULCAN_DSUD_PORT:-26760}" &
        dsud_pid=$!
    else
        printf '[vulcan] vulcan-dsud not found: %s; controller input disabled\n' \
            "$dsud_bin" >&2
    fi
fi

stop_dsud() {
    if [ -n "${dsud_pid:-}" ]; then
        kill -TERM "$dsud_pid" 2>/dev/null || true
        wait "$dsud_pid" 2>/dev/null || true
    fi
}
trap stop_dsud EXIT
trap 'stop_dsud; exit 143' TERM INT

# The Eden AppImage ships a hook that forces the X11 platform, so the setup
# window needs the Xwayland display gamescope provides. Without it the emulator
# starts with no window at all.
GAMESCOPE_ENABLED="${GAMESCOPE_ENABLED:-1}"
if [ "$GAMESCOPE_ENABLED" = "1" ] && command -v gamescope >/dev/null 2>&1; then
    GAMESCOPE_ARGS=()
    gamescope_args GAMESCOPE_ARGS
    gamescope "${GAMESCOPE_ARGS[@]}" -- "$eden_bin" &
else
    "$eden_bin" &
fi
app_pid=$!

status=0
wait "$app_pid" || status=$?
exit "$status"
