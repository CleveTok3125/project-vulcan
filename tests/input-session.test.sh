#!/bin/bash
# Verifies the input path stays on the per-session socket and does not fall
# back to kernel input devices shared with another session.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

check_missing() {
    local label="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf 'FAIL %s: unexpected [%s] in %s\n' "$label" "$needle" "$file" >&2
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$label"
    fi
}

entrypoint="$repo_root/scripts/entrypoint.sh"
session_start="$repo_root/scripts/session-start.sh"
compose="$repo_root/compose.yaml"
inputd="$repo_root/rust/inputd/src/main.rs"
preset="$repo_root/.env.multi.example"

check_contains "sway uses only the headless backend" 'SWAY_BACKENDS="headless"' "$entrypoint"
check_missing "entrypoint starts no input broker" "vulcan-input-broker" "$entrypoint"
check_missing "entrypoint starts no xtest bridge" "vulcan-input-bridge" "$entrypoint"
check_missing "entrypoint creates no input nodes" "/dev/input" "$entrypoint"
check_missing "entrypoint creates no network namespace" "ip netns" "$entrypoint"

check_contains "apollo loads the socket shim" \
    "LD_PRELOAD=/usr/lib/libvulcan_uinput_shim.so" "$session_start"
check_contains "session sets the input socket" "VULCAN_INPUT_SOCKET=" "$session_start"

check_missing "compose passes no input device cgroup" "device_cgroup_rules" "$compose"
check_missing "compose grants no mknod" "MKNOD" "$compose"
check_missing "compose grants no net_admin" "NET_ADMIN" "$compose"
check_missing "compose exposes no kernel input env" "INPUT_BACKEND" "$compose"

check_contains "preset keeps the socket transport" "INPUT_TRANSPORT=socket" "$preset"
check_missing "preset keeps no kernel input backend" "INPUT_BACKEND" "$preset"

check_missing "inputd does not scan a preset path" "/games/" "$inputd"
check_missing "inputd does not scan the shared tmp" '"/tmp"' "$inputd"
check_contains "inputd resolves the per-session EIS socket" "fn socket_in(" "$inputd"

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
