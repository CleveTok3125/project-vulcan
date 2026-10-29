#!/bin/bash
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

cp "$repo_root/Makefile" "$workdir/Makefile"
printf 'GAME_ID=zzz\n' >"$workdir/.env.local"
printf 'GAME_ID=demo\n' >"$workdir/preset.env"
printf 'GAME_ID=demo\nGPU_VENDOR=nvidia\n' >"$workdir/nvidia.env"
printf 'GAME_ID=demo\nGPU_VENDOR=amd\nINSTALL_CUDA=0\n' >"$workdir/amd.env"

run_make() {
    (cd "$workdir" && make --no-print-directory -n "$@")
}

# `make -n` prints the help recipe instead of running it.
run_help() {
    (cd "$workdir" && make --no-print-directory help)
}

# The default configuration file keeps working without arguments.
out="$(run_make up)"
check_contains 'default env file' '--env-file .env.local' "$out"
check_contains 'default preset is reported' '[vulcan] PRESET=.env.local' "$out"
check_contains 'default volume' 'vulcan_zzz-data' "$(run_make clean-logs)"

# An explicit file replaces the default for every target.
out="$(run_make up PRESET=preset.env)"
check_contains 'explicit env file' '--env-file preset.env' "$out"
check_contains 'explicit preset is reported' '[vulcan] PRESET=preset.env' "$out"
check_missing 'explicit env file replaces default' '--env-file .env.local' "$out"
check_contains 'explicit preset volume' 'vulcan_demo-data' "$(run_make clean-overlay PRESET=preset.env)"
check_contains 'explicit preset compose down' '--env-file preset.env' "$(run_make down PRESET=preset.env)"

# A missing preset is rejected before anything runs.
out="$(run_make up PRESET=absent.env 2>&1 || true)"
check_contains 'missing preset is rejected' 'preset absent.env does not exist' "$out"
check_missing 'missing preset starts nothing' 'docker compose' "$out"

# A preset without GAME_ID is rejected as well.
printf 'GAME_MODE=windowed\n' >"$workdir/nogame.env"
out="$(run_make up PRESET=nogame.env 2>&1 || true)"
check_contains 'preset without GAME_ID is rejected' 'does not define GAME_ID' "$out"

# Group targets report and start every listed preset.
out="$(run_make up-all PRESETS=".env.local:preset.env")"
check_contains 'up-all reports the first preset' '[vulcan] PRESET=.env.local' "$out"
check_contains 'up-all reports the second preset' '[vulcan] PRESET=preset.env' "$out"
check_contains 'up-all starts the first preset' '--env-file .env.local' "$out"
check_contains 'up-all starts the second preset' '--env-file preset.env' "$out"

out="$(run_make down-all PRESETS=".env.local:preset.env")"
check_contains 'down-all stops the second preset' '--env-file preset.env' "$out"

out="$(run_make ps-all PRESETS="preset.env")"
check_contains 'ps-all reports the preset' '[vulcan] PRESET=preset.env' "$out"
check_missing 'ps-all leaves out unlisted presets' '--env-file .env.local' "$out"

# The list is required and every entry must exist.
if (cd "$workdir" && make --no-print-directory up-all >/dev/null 2>&1); then
    printf 'FAIL up-all requires PRESETS: it ran without a list\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   up-all requires PRESETS\n'
fi
if (cd "$workdir" && make --no-print-directory up-all PRESETS=".env.local preset.env" >/dev/null 2>&1); then
    printf 'FAIL up-all rejects spaces: it accepted a space-separated list\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   up-all rejects spaces\n'
fi
if (cd "$workdir" && make --no-print-directory up-all PRESETS=absent.env >/dev/null 2>&1); then
    printf 'FAIL up-all rejects a missing preset: it ran with absent.env\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   up-all rejects a missing preset\n'
fi

# Cleanup targets remove only their own paths.
out="$(run_make clean-logs)"
check_contains 'clean-logs removes log files' '/data/log/*' "$out"
check_missing 'clean-logs keeps the overlay' '/data/overlay' "$out"
check_missing 'clean-logs keeps AppData' 'AppData' "$out"

out="$(run_make clean-overlay)"
check_contains 'clean-overlay removes overlay upper' '/data/overlay/zzz/upper' "$out"
check_contains 'clean-overlay removes overlay work' '/data/overlay/zzz/work' "$out"
check_contains 'clean-overlay removes the reset marker' '.vulcan-reset-paths' "$out"
check_missing 'clean-overlay keeps the logs' '/data/log' "$out"
check_missing 'clean-overlay keeps AppData' 'AppData' "$out"

out="$(run_make clean-appdata)"
check_contains 'clean-appdata removes AppData' 'drive_c/users/*/AppData' "$out"
check_missing 'clean-appdata keeps the overlay' '/data/overlay' "$out"
check_missing 'clean-appdata keeps the logs' '/data/log' "$out"

out="$(run_make clean-all)"
check_contains 'clean-all removes logs' '/data/log/*' "$out"
check_contains 'clean-all removes the overlay' '/data/overlay/zzz/upper' "$out"
check_contains 'clean-all removes the reset marker' '.vulcan-reset-paths' "$out"
check_contains 'clean-all removes AppData' 'drive_c/users/*/AppData' "$out"

# The bare clean target is gone.
if (cd "$workdir" && make --no-print-directory -n clean >/dev/null 2>&1); then
    printf 'FAIL bare clean target is gone: it still exists\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   bare clean target is gone\n'
fi

# The session shell runs outside Compose and sets the session environment.
out="$(run_make shell)"
check_contains 'session shell runs as the game user' '--user 1000' "$out"
check_contains 'session shell sets the runtime dir' 'XDG_RUNTIME_DIR=/run/user/1000' "$out"
check_contains 'session shell sets the wayland display' 'WAYLAND_DISPLAY=' "$out"

# Uninstall removes the container, its volume, and the image.
out="$(run_make uninstall CONFIRM=1 PRESET=preset.env)"
check_contains 'uninstall uses the explicit preset' '--env-file preset.env' "$out"
check_contains 'uninstall removes the image' 'docker rmi vulcan/game-stream:local-' "$out"

# The image tag follows the build inputs, not the game.
tag_for() {
    printf '%s\n' "$1" | sed -n 's/.*docker rmi vulcan\/game-stream://p' | head -n 1
}
default_tag="$(tag_for "$(run_make uninstall CONFIRM=1)")"
explicit_tag="$(tag_for "$(run_make uninstall CONFIRM=1 PRESET=nvidia.env)")"
other_game_tag="$(tag_for "$(run_make uninstall CONFIRM=1 PRESET=preset.env)")"
variant_tag="$(tag_for "$(run_make uninstall CONFIRM=1 PRESET=amd.env)")"

if [ -n "$default_tag" ] && [ "$default_tag" = "$explicit_tag" ]; then
    printf 'ok   explicit defaults keep the image tag\n'
else
    printf 'FAIL explicit defaults keep the image tag: [%s] vs [%s]\n' "$default_tag" "$explicit_tag" >&2
    failures=$((failures + 1))
fi
if [ "$default_tag" = "$other_game_tag" ]; then
    printf 'ok   another game reuses the image tag\n'
else
    printf 'FAIL another game reuses the image tag: [%s] vs [%s]\n' "$default_tag" "$other_game_tag" >&2
    failures=$((failures + 1))
fi
if [ "$default_tag" != "$variant_tag" ]; then
    printf 'ok   a different backend gets its own tag\n'
else
    printf 'FAIL a different backend gets its own tag: both are [%s]\n' "$default_tag" >&2
    failures=$((failures + 1))
fi

# Targets that do not use Compose must work before any configuration exists.
rm "$workdir/.env.local"
out="$(run_make stats 2>&1 || true)"
check_contains 'container targets need a preset' 'preset .env.local does not exist' "$out"

out="$(run_help)"
check_contains 'help without env file' 'Show available targets' "$out"
check_contains 'help lists the group targets' 'up-all' "$out"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
