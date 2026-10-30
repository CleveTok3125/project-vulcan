#!/bin/bash
# Verifies the Apollo port table printed for one or more presets.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/show-ports.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0

check_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grep -Fq -- "$needle" <<<"$haystack"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in [%s]\n' "$label" "$needle" "$haystack" >&2
        failures=$((failures + 1))
    fi
}

printf 'APOLLO_PORT=48006\n' >"$workdir/first.env"
printf 'APOLLO_PORT=47989\n' >"$workdir/second.env"
printf 'APOLLO_PORT=not-a-port\n' >"$workdir/invalid.env"
printf 'GAME_ID=demo\n' >"$workdir/default.env"

out="$("$script" "$workdir/first.env" "$workdir/second.env")"
check_contains "header names the ports" 'HTTPS' "$out"
check_contains "header names the control port" 'CONTROL' "$out"
check_contains "first HTTPS port" '48001' "$out"
check_contains "first web port" '48007' "$out"
check_contains "first RTSP port" '48027' "$out"
check_contains "first video port" '48015' "$out"
check_contains "first mic port" '48019' "$out"
check_contains "second HTTPS port" '47984' "$out"
check_contains "second RTSP port" '48010' "$out"
check_contains "second video port" '47998' "$out"

out="$("$script" "$workdir/default.env")"
check_contains "missing APOLLO_PORT uses the default" '47989' "$out"

if output="$("$script" "$workdir/invalid.env" 2>&1)"; then
    printf 'FAIL invalid APOLLO_PORT was accepted\n' >&2
    failures=$((failures + 1))
else
    check_contains "invalid APOLLO_PORT is reported" 'invalid APOLLO_PORT' "$output"
fi

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
