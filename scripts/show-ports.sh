#!/bin/bash
# Prints the Apollo ports derived from each preset's APOLLO_PORT.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=port-lib.sh
source "$script_dir/port-lib.sh"

if [ "$#" -eq 0 ]; then
    printf 'usage: %s PRESET_FILE...\n' "$(basename "$0")" >&2
    exit 2
fi

printf '%-24s %6s %7s %7s %7s %7s %7s %8s %7s %6s\n' \
    PRESET BASE HTTPS HTTP WEB RTSP VIDEO CONTROL AUDIO MIC

for preset in "$@"; do
    base="$(read_apollo_port "$preset")"
    if ! apollo_port_is_valid "$base"; then
        printf 'invalid APOLLO_PORT in %s: [%s]\n' "$preset" "$base" >&2
        exit 1
    fi
    printf '%-24s %6d %7d %7d %7d %7d %7d %8d %7d %6d\n' \
        "$preset" "$base" \
        "$((base - 5))" "$base" "$((base + 1))" "$((base + 21))" \
        "$((base + 9))" "$((base + 10))" "$((base + 11))" "$((base + 13))"
done
