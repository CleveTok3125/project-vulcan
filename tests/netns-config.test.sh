#!/bin/bash
# Verifies that SESSION_NETWORK selects the host namespace or the published
# Apollo ports, and that the published set follows APOLLO_PORT.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

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

mkdir -p "$workdir/source"
cat >"$workdir/preset.env" <<EOF
SESSION_ID=demo
GAMES_CATALOG=games.yaml
AUDIO_RUNTIME_DIR=$workdir/audio
RENDER_NODE=/dev/dri/renderD128
SPRITZ_DIR=$workdir/source
APOLLO_PORT=48006
GID_RENDER=1000
GID_VIDEO=1000
SESSION_NETWORK=netns
EOF

netns_override="$workdir/compose.netns.yaml"
"$repo_root/scripts/generate-netns-config.sh" "$workdir/preset.env" "$netns_override"
generated="$(cat "$netns_override")"

check 'override publishes every listener' '8' \
    "$(printf '%s\n' "$generated" | grep -c '^      - "')"
for published in 48001/tcp 48006/tcp 48007/tcp 48027/tcp \
    48015/udp 48016/udp 48017/udp 48019/udp; do
    port="${published%%/*}"
    check "override publishes ${published}" 'yes' \
        "$(grep -Fq "\"${port}:${published}\"" "$netns_override" && printf yes || printf no)"
done

# A bad base port stops the generator before compose sees the file.
printf 'APOLLO_PORT=not-a-port\n' >"$workdir/bad.env"
if "$repo_root/scripts/generate-netns-config.sh" "$workdir/bad.env" "$workdir/bad.yaml" \
    2>"$workdir/bad.log"; then
    printf 'FAIL invalid APOLLO_PORT was accepted\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   invalid APOLLO_PORT is rejected\n'
fi
check 'invalid APOLLO_PORT is reported' '1' "$(grep -c 'invalid APOLLO_PORT' "$workdir/bad.log")"
check 'invalid APOLLO_PORT writes nothing' 'no' \
    "$([ -e "$workdir/bad.yaml" ] && printf yes || printf no)"

if "$repo_root/scripts/generate-netns-config.sh" "$workdir/missing.env" "$workdir/missing.yaml" \
    2>"$workdir/missing.log"; then
    printf 'FAIL missing preset was accepted\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   missing preset is rejected\n'
fi
check 'missing preset is reported' '1' "$(grep -c 'missing preset' "$workdir/missing.log")"

if ! docker compose version >/dev/null 2>&1; then
    printf 'skip compose render: docker compose is not available\n'
else
    render() {
        BASE_IMAGE=vulcan/base:test docker compose --env-file "$workdir/preset.env" \
            -f "$repo_root/compose.yaml" "$@" config 2>/dev/null
    }

    host_config="$(render -f "$repo_root/compose.host.yaml")"
    check_contains 'host mode shares the host namespace' 'network_mode: host' "$host_config"
    check_missing 'host mode publishes nothing' 'published:' "$host_config"

    netns_config="$(render -f "$netns_override")"
    check_missing 'netns mode drops the host namespace' 'network_mode: host' "$netns_config"
    check 'netns mode publishes the whole set' '8' \
        "$(printf '%s\n' "$netns_config" | grep -c 'published:')"
    check_contains 'netns mode publishes the web port' 'published: "48007"' "$netns_config"
    check_contains 'netns mode keeps the session network' 'name: vulcan-demo_default' "$netns_config"
fi

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
