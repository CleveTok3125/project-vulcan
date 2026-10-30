#!/bin/bash
# Rejects Apollo presets whose port ranges overlap.
#
# Apollo offsets every listener from APOLLO_PORT, and the presets share the
# host network namespace, so two ranges on the same protocol cannot coexist.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=port-lib.sh
source "$script_dir/port-lib.sh"

if [ "$#" -eq 0 ]; then
    printf 'usage: %s PRESET_FILE...\n' "$(basename "$0")" >&2
    exit 2
fi

declare -A owner=()
failures=0

for preset in "$@"; do
    base="$(read_apollo_port "$preset")"
    if ! [[ "$base" =~ ^[0-9]+$ ]]; then
        printf 'invalid APOLLO_PORT in %s: [%s]\n' "$preset" "$base" >&2
        failures=1
        continue
    fi
    if ! apollo_port_is_valid "$base"; then
        printf 'APOLLO_PORT out of range in %s: %d\n' "$preset" "$base" >&2
        failures=1
        continue
    fi

    while read -r protocol port; do
        key="${protocol}/${port}"
        previous="${owner[$key]:-}"
        if [ -n "$previous" ]; then
            printf 'collision: %s used by %s and %s\n' "$key" "$previous" "$preset" >&2
            failures=1
        else
            owner[$key]="$preset"
        fi
    done < <(apollo_ports "$base")
done

exit "$failures"
