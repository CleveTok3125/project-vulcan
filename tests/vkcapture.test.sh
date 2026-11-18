#!/bin/bash
# Verifies the OBS capture layer is built without pulling OBS into the image.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/Dockerfile"
compose="$repo_root/compose.yaml"
launcher="$repo_root/scripts/launch-game.sh"
makefile="$repo_root/Makefile"

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

check_contains 'capture builder stage' 'AS vkcapture-builder' "$dockerfile"
check_contains 'plugin build disabled' '-DBUILD_PLUGIN=OFF' "$dockerfile"
check_contains 'capture ref is an argument' 'ARG OBS_VKCAPTURE_REF' "$dockerfile"
check_contains 'capture tools are copied' 'COPY --from=vkcapture-builder' "$dockerfile"
check_missing 'image does not install obs-studio' 'pacman -S --noconfirm --needed --disable-download-timeout obs-studio' "$dockerfile"

check_contains 'compose passes the capture ref' 'OBS_VKCAPTURE_REF' "$compose"
check_contains 'capture is enabled by default' 'OBS_VKCAPTURE: "${OBS_VKCAPTURE:-1}"' "$compose"
check_contains 'compose passes the capture name override' 'OBS_VKCAPTURE_NAME' "$compose"
check_contains 'image tag includes the capture ref' '$(OBS_VKCAPTURE_REF)' "$makefile"
check_contains 'launcher defaults capture on' 'OBS_VKCAPTURE_ENABLED="${OBS_VKCAPTURE:-1}"' "$launcher"
check_contains 'launcher keeps the layer out of gamescope' 'unset OBS_VKCAPTURE' "$launcher"
check_contains 'launcher wraps the runner' 'target=("$OBS_GAMECAPTURE_BIN" "${target[@]}")' "$launcher"
check_contains 'launcher uses the capture helper for wine' 'wrap_capture runner' "$launcher"
check_missing 'launcher does not skip capture in a session namespace' \
    'OBS capture needs the host network namespace' "$launcher"
check_contains 'capture layer applies the device-proc fallback' \
    'obs-vkcapture-device-proc-fallback.patch' "$dockerfile"
check_contains 'fallback uses the instance proc address' \
    'gipa(idata->instance' "$repo_root/docker/patches/obs-vkcapture-device-proc-fallback.patch"
check_contains 'image ships the capture relay' 'vulcan-capture-bridge' "$dockerfile"
check_contains 'image asserts the relay frame size' 'CAPTURE_TEXTURE_DATA_SIZE == 128' "$dockerfile"
check_contains 'session start runs the relay' \
    'vulcan-capture-bridge game' "$repo_root/scripts/session-start.sh"
check_contains 'capture name is session scoped' 'OBS_VKCAPTURE_NAME' "$launcher"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
