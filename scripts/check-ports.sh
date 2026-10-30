#!/bin/bash
# Rejects Apollo presets whose port ranges overlap.
#
# Apollo offsets every listener from APOLLO_PORT, and the presets share the
# host network namespace, so two ranges on the same protocol cannot coexist.
set -Eeuo pipefail

# Prints "<protocol> <port>" for every listener derived from a base port.
apollo_ports() {
    local base="$1"
    printf 'tcp %d\n' "$((base - 5))" "$base" "$((base + 1))" "$((base + 21))"
    printf 'udp %d\n' "$((base + 9))" "$((base + 10))" "$((base + 11))" "$((base + 13))"
}

# Reads APOLLO_PORT from a preset; the container defaults to 47989.
read_port() {
    local preset="$1" value
    value="$(sed -n 's/^[[:space:]]*APOLLO_PORT[[:space:]]*=[[:space:]]*//p' "$preset" | tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "${value:-47989}"
}

if [ "$#" -eq 0 ]; then
    printf 'usage: %s PRESET...\n' "$(basename "$0")" >&2
    exit 2
fi

declare -A owner=()
failures=0

for preset in "$@"; do
    base="$(read_port "$preset")"
    if ! [[ "$base" =~ ^[0-9]+$ ]]; then
        printf 'invalid APOLLO_PORT in %s: [%s]\n' "$preset" "$base" >&2
        failures=1
        continue
    fi
    if ((base < 1029 || base > 65514)); then
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
