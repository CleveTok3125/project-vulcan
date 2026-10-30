#!/bin/bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/config-lib.sh
source "$repo_root/scripts/config-lib.sh"

failures=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

expect_valid() {
    local game_id="$1"
    if is_valid_game_id "$game_id"; then
        printf 'ok   valid game id [%s]\n' "$game_id"
    else
        printf 'FAIL game id [%s] rejected\n' "$game_id" >&2
        failures=$((failures + 1))
    fi
}

expect_invalid() {
    local game_id="$1"
    if is_valid_game_id "$game_id"; then
        printf 'FAIL game id [%s] accepted\n' "$game_id" >&2
        failures=$((failures + 1))
    else
        printf 'ok   rejected game id [%s]\n' "$game_id"
    fi
}

expect_valid alpha
expect_valid demo
expect_valid Game_2.v1
expect_valid 0

expect_invalid ''
expect_invalid '..'
expect_invalid '../alpha'
expect_invalid 'a/b'
expect_invalid '-alpha'
expect_invalid 'a b'
expect_invalid 'alpha/'

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$'

alpha_uuid="$(derive_app_uuid alpha)"
if [[ "$alpha_uuid" =~ $uuid_re ]]; then
    printf 'ok   uuid format [%s]\n' "$alpha_uuid"
else
    printf 'FAIL uuid format [%s]\n' "$alpha_uuid" >&2
    failures=$((failures + 1))
fi

check 'uuid is stable' "$(derive_app_uuid alpha)" "$(derive_app_uuid alpha)"

check 'xwayland is off with gamescope' 'disable' "$(sway_xwayland 1)"
check 'xwayland is on without gamescope' 'enable' "$(sway_xwayland 0)"
check 'xwayland defaults to off' 'disable' "$(sway_xwayland)"

if [ "$(derive_app_uuid alpha)" = "$(derive_app_uuid demo)" ]; then
    printf 'FAIL uuid differs per game id\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   uuid differs per game id\n'
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

out="$workdir/apps.json"
render_apollo_apps_multi \
    "$repo_root/config/apollo/apps.json" "$out" \
    '[{"name":"Game \"A\" \\ B","cmd":"/usr/local/bin/launch-game.sh alpha","uuid":"'"$alpha_uuid"'"},{"name":"Second","cmd":"/usr/local/bin/launch-game.sh beta","uuid":"123e4567-e89b-42d3-a456-426614174000"}]'

check 'rendered first name' 'Game "A" \ B' "$(jq -r '.apps[0].name' "$out")"
check 'rendered first cmd' '/usr/local/bin/launch-game.sh alpha' "$(jq -r '.apps[0].cmd' "$out")"
check 'rendered first uuid' "$alpha_uuid" "$(jq -r '.apps[0].uuid' "$out")"
check 'rendered second name' 'Second' "$(jq -r '.apps[1].name' "$out")"
check 'rendered second cmd' '/usr/local/bin/launch-game.sh beta' "$(jq -r '.apps[1].cmd' "$out")"
check 'app count' '2' "$(jq '.apps | length' "$out")"
check 'unrelated field kept' '5' "$(jq -r '.apps[0]["exit-timeout"]' "$out")"
check 'unrelated field kept on every app' '5' "$(jq -r '.apps[1]["exit-timeout"]' "$out")"
check 'output is valid json' 'true' "$(jq -e . "$out" >/dev/null 2>&1 && printf true || printf false)"

if [ -e "${out}.tmp" ]; then
    printf 'FAIL temporary file left behind\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   no temporary file left behind\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
