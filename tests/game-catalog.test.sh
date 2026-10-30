#!/bin/bash
# Verifies the game catalog parser and validators.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/game-lib.sh
source "$repo_root/scripts/game-lib.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

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
    local label="$1" catalog="$2"
    if validate_games_catalog "$catalog" >/dev/null 2>&1; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: catalog rejected\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

expect_invalid() {
    local label="$1" catalog="$2" needle="$3"
    local output
    if output="$(validate_games_catalog "$catalog" 2>&1)"; then
        printf 'FAIL %s: catalog accepted\n' "$label" >&2
        failures=$((failures + 1))
    elif grep -Fq -- "$needle" <<<"$output"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in [%s]\n' "$label" "$needle" "$output" >&2
        failures=$((failures + 1))
    fi
}

catalog="$workdir/games.json"
cat >"$catalog" <<'EOF'
{
  "games": [
    {
      "id": "alpha",
      "name": "Alpha Game",
      "source": "/srv/games/alpha",
      "exe": "Alpha.exe"
    },
    {
      "id": "beta",
      "name": "Beta Game",
      "source": "/srv/games/beta",
      "exe": "Beta.exe",
      "reset_paths": [
        "Data/Login",
        "Data/Cache"
      ]
    }
  ]
}
EOF

expect_valid 'valid catalog' "$catalog"

check 'game ids' $'alpha\nbeta' "$(game_ids "$catalog")"
check 'game field' 'Beta Game' "$(game_field "$catalog" beta name)"
check 'missing game field is empty' '' "$(game_field "$catalog" missing name)"
check 'reset paths' \
    $'Data/Login\nData/Cache' \
    "$(game_reset_paths "$catalog" beta)"
check 'game without reset paths' '' "$(game_reset_paths "$catalog" alpha)"
check 'game count' '2' "$(game_count "$catalog")"

specs="$(build_app_specs "$catalog")"
check 'app spec count' '2' "$(jq 'length' <<<"$specs")"
check 'first app name' 'Alpha Game' "$(jq -r '.[0].name' <<<"$specs")"
check 'first app command' '/usr/local/bin/launch-game.sh alpha' "$(jq -r '.[0].cmd' <<<"$specs")"
check 'first app uuid is derived' "$(derive_app_uuid alpha)" "$(jq -r '.[0].uuid' <<<"$specs")"
check 'second app uuid is derived' "$(derive_app_uuid beta)" "$(jq -r '.[1].uuid' <<<"$specs")"

# A catalog must contain at least one game.
printf '{"games":[]}\n' >"$workdir/empty.json"
expect_invalid 'empty catalog' "$workdir/empty.json" 'at least one game'

# IDs are safe path segments and unique.
jq '.games[0].id = "../bad"' "$catalog" >"$workdir/bad-id.json"
expect_invalid 'unsafe game id' "$workdir/bad-id.json" 'invalid game id'
jq '.games[1].id = "alpha"' "$catalog" >"$workdir/duplicate-id.json"
expect_invalid 'duplicate game id' "$workdir/duplicate-id.json" 'duplicate game id'

# Exe and reset paths stay inside the game directory.
jq '.games[0].exe = "/bin/sh"' "$catalog" >"$workdir/absolute-exe.json"
expect_invalid 'absolute exe' "$workdir/absolute-exe.json" 'exe must be relative'
jq '.games[0].exe = "../outside.exe"' "$catalog" >"$workdir/parent-exe.json"
expect_invalid 'parent traversal in exe' "$workdir/parent-exe.json" 'exe must be relative'
jq '.games[1].reset_paths[0] = "/etc/passwd"' "$catalog" >"$workdir/absolute-reset.json"
expect_invalid 'absolute reset path' "$workdir/absolute-reset.json" 'reset path must be relative'
jq '.games[1].reset_paths[0] = "../outside"' "$catalog" >"$workdir/parent-reset.json"
expect_invalid 'parent traversal in reset path' "$workdir/parent-reset.json" 'reset path must be relative'

# Sources are absolute host paths.
jq '.games[0].source = "relative/path"' "$catalog" >"$workdir/relative-source.json"
expect_invalid 'relative source' "$workdir/relative-source.json" 'source must be absolute'

# An optional wine tree is an absolute host path.
jq '.games[0].wine_source = "relative/wine"' "$catalog" >"$workdir/relative-wine.json"
expect_invalid 'relative wine source' "$workdir/relative-wine.json" 'wine_source must be absolute'
jq '.games[0].wine_source = "/srv/wine"' "$catalog" >"$workdir/wine-source.json"
expect_valid 'absolute wine source' "$workdir/wine-source.json"

# An explicit UUID must be a UUID, not an arbitrary string.
jq '.games[0].uuid = "not-a-uuid"' "$catalog" >"$workdir/bad-uuid.json"
expect_invalid 'invalid uuid' "$workdir/bad-uuid.json" 'invalid uuid'

# A valid explicit UUID is accepted.
jq '.games[0].uuid = "123e4567-e89b-42d3-a456-426614174000"' "$catalog" >"$workdir/uuid.json"
expect_valid 'explicit uuid' "$workdir/uuid.json"

# Missing names and malformed reset arrays are rejected.
jq '.games[0].name = ""' "$catalog" >"$workdir/empty-name.json"
expect_invalid 'empty name' "$workdir/empty-name.json" 'name must not be empty'
jq '.games[0].reset_paths = "one:two"' "$catalog" >"$workdir/string-reset.json"
expect_invalid 'reset paths must be an array' "$workdir/string-reset.json" 'reset_paths must be an array'

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
