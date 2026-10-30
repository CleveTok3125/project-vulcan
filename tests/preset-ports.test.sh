#!/bin/bash
# Verifies that overlapping Apollo port ranges are rejected across presets.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/check-ports.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0

write_preset() {
    local path="$1"
    shift
    printf '%s\n' "$@" >"$workdir/$path"
}

expect_ok() {
    local label="$1"
    shift
    if output="$("$script" "$@" 2>&1)"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: expected success, got [%s]\n' "$label" "$output" >&2
        failures=$((failures + 1))
    fi
}

expect_collision() {
    local label="$1" needle="$2"
    shift 2
    if output="$("$script" "$@" 2>&1)"; then
        printf 'FAIL %s: expected a collision\n' "$label" >&2
        failures=$((failures + 1))
    elif grep -Fq -- "$needle" <<<"$output"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in [%s]\n' "$label" "$needle" "$output" >&2
        failures=$((failures + 1))
    fi
}

write_preset safe.env 'APOLLO_PORT=47989'
write_preset other.env 'APOLLO_PORT=48006'
write_preset third.env 'APOLLO_PORT=47999'
write_preset close.env 'APOLLO_PORT=47991'
write_preset adjacent.env 'APOLLO_PORT=47990'
write_preset default.env 'SESSION_ID=demo'
write_preset invalid.env 'APOLLO_PORT=not-a-port'
write_preset low.env 'APOLLO_PORT=700'

expect_ok "separate ranges" \
    "$workdir/safe.env" "$workdir/other.env" "$workdir/third.env"
expect_collision "overlapping udp ranges" "udp/48000" \
    "$workdir/safe.env" "$workdir/close.env"
expect_collision "overlapping udp ranges report every port" "udp/48002" \
    "$workdir/safe.env" "$workdir/close.env"
expect_ok "same number on another protocol" \
    "$workdir/safe.env" "$workdir/third.env"
expect_collision "overlapping tcp range" "tcp/47990" \
    "$workdir/safe.env" "$workdir/adjacent.env"
expect_collision "missing APOLLO_PORT uses the default" "tcp/47989" \
    "$workdir/default.env" "$workdir/safe.env"
expect_collision "invalid APOLLO_PORT" "invalid APOLLO_PORT" \
    "$workdir/invalid.env"
expect_collision "low APOLLO_PORT" "out of range" \
    "$workdir/low.env"

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
