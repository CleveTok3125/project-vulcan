#!/bin/bash
# Shared helpers for per-game configuration. Sourced by entrypoint.sh.

# is_valid_game_id reports whether the value is safe to use as a path segment
# and as part of a Docker volume name.
is_valid_game_id() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

# derive_app_uuid prints a stable UUID for a game id: an md5 digest laid out as
# a UUID v4. Apollo stores per-app client state under this value, so it must
# stay the same across restarts.
derive_app_uuid() {
    local digest
    digest="$(printf '%s' "$1" | md5sum | cut -d' ' -f1)"
    printf '%s-%s-4%s-8%s-%s\n' \
        "${digest:0:8}" "${digest:8:4}" "${digest:13:3}" "${digest:17:3}" "${digest:20:12}"
}

# sway_xwayland prints the Sway Xwayland mode.
#
# Gamescope runs its own Xwayland for Wine. Sway's instance is unused then and
# competes with the host for abstract X11 socket names, so it stays off unless
# the game runs directly under Sway.
sway_xwayland() {
    if [ "${1:-1}" = "1" ]; then
        printf 'disable\n'
    else
        printf 'enable\n'
    fi
}

# render_apollo_apps writes the Apollo app list for one game.
#
# Arguments: template path, output path, app name, app command, app uuid.
# The template must hold at least one app; its remaining fields are kept.
render_apollo_apps() {
    local template="$1" output="$2" name="$3" cmd="$4" uuid="$5"
    # Write in place so an existing file keeps its owner and mode.
    jq --arg name "$name" --arg cmd "$cmd" --arg uuid "$uuid" \
        '.apps[0].name = $name
         | .apps[0].cmd = $cmd
         | .apps[0].uuid = $uuid' \
        "$template" >"$output"
}
