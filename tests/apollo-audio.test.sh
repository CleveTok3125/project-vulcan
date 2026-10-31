#!/bin/bash
# Verifies Apollo captures the session's explicit null-sink monitor.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/config/apollo/sunshine.conf.in"
entrypoint="$repo_root/scripts/entrypoint.sh"

failures=0

check_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in %s\n' "$label" "$needle" "$file" >&2
        failures=$((failures + 1))
    fi
}

check_contains 'apollo captures the virtual sink' 'audio_sink = sink-sunshine-stereo' "$template"
check_contains 'entrypoint creates that sink' 'sink_name=vulcan_game' "$entrypoint"
check_contains 'entrypoint makes it the default sink' 'set-default-sink vulcan_game' "$entrypoint"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
