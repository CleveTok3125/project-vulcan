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
check_contains 'default volume' 'vulcan_zzz-data' "$(run_make clean)"

# An explicit file replaces the default for every target.
out="$(run_make up ENV_FILE=preset.env)"
check_contains 'explicit env file' '--env-file preset.env' "$out"
check_missing 'explicit env file replaces default' '--env-file .env.local' "$out"
check_contains 'explicit preset volume' 'vulcan_demo-data' "$(run_make clean ENV_FILE=preset.env)"
check_contains 'explicit preset compose down' '--env-file preset.env' "$(run_make down ENV_FILE=preset.env)"

# The session shell runs outside Compose and sets the session environment.
out="$(run_make shell)"
check_contains 'session shell runs as the game user' '--user 1000' "$out"
check_contains 'session shell sets the runtime dir' 'XDG_RUNTIME_DIR=/run/user/1000' "$out"
check_contains 'session shell sets the wayland display' 'WAYLAND_DISPLAY=' "$out"

# Targets that do not use Compose must work before any configuration exists.
rm "$workdir/.env.local"
out="$(run_help)"
check_contains 'help without env file' 'Show available targets' "$out"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
