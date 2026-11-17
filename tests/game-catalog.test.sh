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

# A catalog can add a native emulator entry beside the Wine games.
eden_catalog="$workdir/eden.json"
cat >"$eden_catalog" <<'EOF'
{
  "eden_content": "/srv/eden/content",
  "games": [
    {
      "id": "alpha",
      "name": "Alpha Game",
      "source": "/srv/games/alpha",
      "exe": "Alpha.exe"
    },
    {
      "id": "gamma",
      "name": "Gamma Game",
      "runner": "eden",
      "source": "/srv/games/gamma",
      "rom": "game.xci"
    }
  ]
}
EOF
expect_valid 'eden entry' "$eden_catalog"
check 'eden runner is reported' 'eden' "$(game_runner "$eden_catalog" gamma)"
check 'wine runner is the default' 'wine' "$(game_runner "$eden_catalog" alpha)"
check 'eden content is reported' '/srv/eden/content' \
    "$(catalog_eden_content "$eden_catalog")"
check 'eden runner is detected' 'yes' \
    "$(catalog_has_eden_runner "$eden_catalog" && printf yes || printf no)"

eden_specs="$(build_app_specs "$eden_catalog")"
check 'eden app spec count' '3' "$(jq 'length' <<<"$eden_specs")"
check 'eden setup app name' 'Eden Setup' "$(jq -r '.[2].name' <<<"$eden_specs")"
check 'eden setup app command' '/usr/local/bin/eden-setup.sh' \
    "$(jq -r '.[2].cmd' <<<"$eden_specs")"
check 'eden setup app uuid is derived' "$(derive_app_uuid eden-setup)" \
    "$(jq -r '.[2].uuid' <<<"$eden_specs")"

# The setup app stays available without a content directory: it is also where
# the controller mapping is created.
jq 'del(.eden_content)' "$eden_catalog" >"$workdir/eden-no-content.json"
check 'setup app without content' '3' \
    "$(build_app_specs "$workdir/eden-no-content.json" | jq 'length')"

# Runner-specific fields are rejected instead of being silently ignored.
jq '.games[1] |= del(.rom)' "$eden_catalog" >"$workdir/eden-no-rom.json"
expect_invalid 'eden without rom' "$workdir/eden-no-rom.json" 'rom must be relative'
jq '.games[1].exe = "game.exe"' "$eden_catalog" >"$workdir/eden-with-exe.json"
expect_invalid 'eden with exe' "$workdir/eden-with-exe.json" 'must not set exe'
jq '.games[1].wine_source = "/srv/wine"' "$eden_catalog" >"$workdir/eden-with-wine.json"
expect_invalid 'eden with wine source' "$workdir/eden-with-wine.json" 'must not set wine_source'
jq '.games[1].reset_paths = ["Data"]' "$eden_catalog" >"$workdir/eden-with-reset.json"
expect_invalid 'eden with reset paths' "$workdir/eden-with-reset.json" 'must not set reset_paths'
jq '.games[0].rom = "game.xci"' "$eden_catalog" >"$workdir/wine-with-rom.json"
expect_invalid 'wine with rom' "$workdir/wine-with-rom.json" 'must not set rom'
jq '.games[1].runner = "retroarch"' "$eden_catalog" >"$workdir/bad-runner.json"
expect_invalid 'unsupported runner' "$workdir/bad-runner.json" 'unsupported runner'
jq '.games[1].rom = "../outside.xci"' "$eden_catalog" >"$workdir/eden-traversal.json"
expect_invalid 'eden rom traversal' "$workdir/eden-traversal.json" 'rom must be relative'
jq '.eden_content = "relative/content"' "$eden_catalog" >"$workdir/relative-content.json"
expect_invalid 'relative eden content' "$workdir/relative-content.json" 'eden_content must be absolute'

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
