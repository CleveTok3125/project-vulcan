#!/bin/bash
# Writes the Compose override that publishes one preset's Apollo ports.
#
# The session network namespace gives the container its own loopback, which
# isolates the gamepad endpoint, so the client reaches Apollo through published
# ports instead of the host network. The set comes from port-lib.sh so it stays
# in step with the collision check.
set -Eeuo pipefail

usage() {
    printf 'usage: %s <preset> <output>\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
preset="$1"
output="$2"

if [ ! -f "$preset" ]; then
    printf '[vulcan] missing preset: %s\n' "$preset" >&2
    exit 1
fi

# shellcheck source=port-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/port-lib.sh"

base="$(read_apollo_port "$preset")"
if ! apollo_port_is_valid "$base"; then
    printf '[vulcan] invalid APOLLO_PORT in %s: [%s]\n' "$preset" "$base" >&2
    exit 1
fi

install -d -m 0755 "$(dirname "$output")"
tmp="$output.$$"
trap 'rm -f "$tmp"' EXIT

{
    printf '# Generated from %s; publishes the Apollo ports for the session namespace.\n' "$preset"
    printf 'services:\n  game:\n    ports:\n'
    while read -r protocol port; do
        printf '      - "%d:%d/%s"\n' "$port" "$port" "$protocol"
    done < <(apollo_ports "$base")
} >"$tmp"

mv "$tmp" "$output"
