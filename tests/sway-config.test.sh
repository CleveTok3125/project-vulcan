#!/bin/bash
# Verifies the Sway template renders with the expected Xwayland mode.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/config-lib.sh
source "$repo_root/scripts/config-lib.sh"

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

render() {
    sed \
        -e "s|@MODE@|1920x1080@144Hz|g" \
        -e "s|@XWAYLAND@|$1|g" \
        "$repo_root/config/sway/config.in"
}

with_gamescope="$(render "$(sway_xwayland 1)")"
without_gamescope="$(render "$(sway_xwayland 0)")"

check_contains "xwayland is disabled under gamescope" "xwayland disable" "$with_gamescope"
check_contains "xwayland is enabled without gamescope" "xwayland enable" "$without_gamescope"
check_contains "the output keeps its mode" "resolution 1920x1080@144Hz" "$with_gamescope"
check_contains "the background keeps swaybg" "swaybg_command" "$with_gamescope"
check_missing "no mode placeholder remains" "@MODE@" "$with_gamescope"
check_missing "no xwayland placeholder remains" "@XWAYLAND@" "$with_gamescope"

if grep -Fq -- '@XWAYLAND@' "$repo_root/scripts/entrypoint.sh"; then
    printf 'ok   entrypoint renders the xwayland placeholder\n'
else
    printf 'FAIL entrypoint does not render @XWAYLAND@\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
