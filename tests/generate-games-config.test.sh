#!/bin/bash
# Verifies the host-side game catalog conversion and mount generation.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/generate-games-config.sh"
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

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    printf 'skip generate-games-config: python3 PyYAML is not available\n'
    exit 0
fi

cat >"$workdir/yq" <<'EOF'
#!/bin/sh
for last; do :; done
python3 - "$last" <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(yaml.safe_load(handle), separators=(",", ":")))
PY
EOF
chmod 0755 "$workdir/yq"

mkdir -p "$workdir/games/Game A" "$workdir/games/Game B" "$workdir/wine/beta"
: >"$workdir/games/Game A/Alpha.exe"
: >"$workdir/games/Game B/Beta.exe"

cat >"$workdir/games.yaml" <<EOF
games:
  - id: alpha
    name: Alpha Game
    source: $workdir/games/Game A
    exe: Alpha.exe
  - id: beta
    name: Beta Game
    source: $workdir/games/Game B
    exe: Beta.exe
    wine_source: $workdir/wine/beta
    reset_paths:
      - Data/Login
EOF

YQ="$workdir/yq" "$script" "$workdir/games.yaml" "$workdir/out"

check 'game count' '2' "$(jq '.games | length' "$workdir/out/games.json")"
check 'source kept' "$workdir/games/Game A" \
    "$(jq -r '.games[0].source' "$workdir/out/games.json")"
check 'reset path kept' 'Data/Login' \
    "$(jq -r '.games[1].reset_paths[0]' "$workdir/out/games.json")"

compose="$(cat "$workdir/out/compose.games.yaml")"
check_contains 'compose has service' 'services:' "$compose"
check_contains 'compose mounts the first game' \
    "\"$workdir/games/Game A:/games-ro/alpha:ro\"" "$compose"
check_contains 'compose mounts the second game' \
    "\"$workdir/games/Game B:/games-ro/beta:ro\"" "$compose"
check_contains 'compose mounts the game wine tree' \
    "\"$workdir/wine/beta:/wine/beta:ro\"" "$compose"

# The generated override is valid YAML and carries the expected mounts.
if python3 - "$workdir/out/compose.games.yaml" "$workdir/games/Game A" "$workdir/games/Game B" "$workdir/wine/beta" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
assert data["services"]["game"]["volumes"] == [
    f"{sys.argv[2]}:/games-ro/alpha:ro",
    f"{sys.argv[3]}:/games-ro/beta:ro",
    f"{sys.argv[4]}:/wine/beta:ro",
]
PY
then
    printf 'ok   generated compose is valid yaml\n'
else
    printf 'FAIL generated compose is not valid yaml\n' >&2
    failures=$((failures + 1))
fi

# Missing executables are rejected before Compose sees the catalog.
rm "$workdir/games/Game B/Beta.exe"
if output="$(YQ="$workdir/yq" "$script" "$workdir/games.yaml" "$workdir/missing" 2>&1)"; then
    printf 'FAIL missing game executable is rejected\n' >&2
    failures=$((failures + 1))
elif grep -Fq 'game executable not found' <<<"$output"; then
    printf 'ok   missing game executable is rejected\n'
else
    printf 'FAIL missing game executable: missing message in [%s]\n' "$output" >&2
    failures=$((failures + 1))
fi

# A malformed catalog is rejected before output is written.
cat >"$workdir/bad.yaml" <<EOF
games:
  - id: ../bad
    name: Bad
    source: $workdir/games/Game A
    exe: Alpha.exe
EOF
if YQ="$workdir/yq" "$script" "$workdir/bad.yaml" "$workdir/bad-out" >/dev/null 2>&1; then
    printf 'FAIL malformed catalog is rejected\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   malformed catalog is rejected\n'
fi

if [ -e "$workdir/bad-out/games.json" ]; then
    printf 'FAIL rejected catalog writes games.json\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   rejected catalog writes no output\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
