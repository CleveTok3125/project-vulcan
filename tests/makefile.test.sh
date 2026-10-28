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
check_contains 'default volume' 'vulcan_zzz-data' "$(run_make clean-logs)"

# An explicit file replaces the default for every target.
out="$(run_make up ENV_FILE=preset.env)"
check_contains 'explicit env file' '--env-file preset.env' "$out"
check_missing 'explicit env file replaces default' '--env-file .env.local' "$out"
check_contains 'explicit preset volume' 'vulcan_demo-data' "$(run_make clean-overlay ENV_FILE=preset.env)"
check_contains 'explicit preset compose down' '--env-file preset.env' "$(run_make down ENV_FILE=preset.env)"

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
out="$(run_make uninstall CONFIRM=1 ENV_FILE=preset.env)"
check_contains 'uninstall uses the explicit preset' '--env-file preset.env' "$out"
check_contains 'uninstall removes the image' 'docker rmi vulcan/game-stream:local' "$out"

# Targets that do not use Compose must work before any configuration exists.
rm "$workdir/.env.local"
out="$(run_help)"
check_contains 'help without env file' 'Show available targets' "$out"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
