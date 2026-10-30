#!/bin/bash
# Verifies that two presets with different GAME_ID values render as separate
# compose projects, containers, and volumes.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0

check_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grep -Fq -- "$needle" <<<"$haystack"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s]\n' "$label" "$needle" >&2
        failures=$((failures + 1))
    fi
}

check_missing() {
    local label="$1" needle="$2" haystack="$3"
    if grep -Fq -- "$needle" <<<"$haystack"; then
        printf 'FAIL %s: unexpected [%s]\n' "$label" "$needle" >&2
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$label"
    fi
}

if ! docker compose version >/dev/null 2>&1; then
    printf 'skip compose identity: docker compose is not available\n'
    exit 0
fi

write_preset() {
    local path="$1" game_id="$2" apollo_port="$3"
    cat >"$path" <<EOF
GAME_ID=${game_id}
GAME_DIR=/games/${game_id}
GAME_EXE=/games/${game_id}/game.exe
RENDER_NODE=/dev/dri/renderD128
SPRITZ_DIR=/wine
APOLLO_PORT=${apollo_port}
GID_RENDER=1000
GID_VIDEO=1000
EOF
}

render() {
    BASE_IMAGE=vulcan/base:test docker compose --env-file "$1" \
        -f "$repo_root/compose.yaml" -f "$repo_root/compose.nvidia.yaml" \
        config 2>/dev/null
}

check_project() {
    local label="$1" game_id="$2" apollo_port="$3" other_game_id="$4" config="$5"
    check_contains "${label} project name" "name: vulcan-${game_id}" "$config"
    check_contains "${label} container name" "container_name: vulcan-${game_id}" "$config"
    check_contains "${label} volume name" "name: vulcan_${game_id}-data" "$config"
    check_contains "${label} apollo port" "APOLLO_PORT: \"${apollo_port}\"" "$config"
    check_missing "${label} leaves the other game alone" "vulcan-${other_game_id}" "$config"
    check_missing "${label} passes no input devices" "c 13:" "$config"
    check_missing "${label} does not add mknod" "- MKNOD" "$config"
    check_missing "${label} does not add net_admin" "- NET_ADMIN" "$config"
    check_missing "${label} has no kernel input env" "INPUT_BACKEND" "$config"
}

write_preset "$workdir/first.env" demo-one 47989
write_preset "$workdir/second.env" demo-two 47999

first="$(render "$workdir/first.env")"
second="$(render "$workdir/second.env")"

check_project first demo-one 47989 demo-two "$first"
check_project second demo-two 47999 demo-one "$second"

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
