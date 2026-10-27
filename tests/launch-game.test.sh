#!/bin/bash
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

fake_root="$workdir/wine"
mkdir -p "$fake_root/bin" "$workdir/game" "$workdir/home"
game_exe="$workdir/game/Game.exe"
wine_log="$workdir/wine.log"
: >"$game_exe"

cat >"$fake_root/bin/wine64" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$WINE_LOG"
if [ "$1" = "wineboot" ]; then
    if [ "${FAKE_WINEBOOT_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    mkdir -p "$WINEPREFIX/drive_c/windows/system32"
fi
exit 0
EOF
chmod 0755 "$fake_root/bin/wine64"

run_launch() {
    env -i PATH=/usr/bin:/bin HOME="$workdir/home" \
        WINEPREFIX="$workdir/prefix" \
        WINE_ROOT="$fake_root" \
        GAME_EXE="$game_exe" \
        GAMESCOPE_ENABLED=0 \
        D3D_BACKEND=wined3d \
        XINPUT_DLL="$workdir/missing.dll" \
        WINE_LOG="$wine_log" \
        "$@" bash "$repo_root/scripts/launch-game.sh"
}

# First launch: the empty prefix is initialized before the game starts.
run_launch 2>"$workdir/first.log"
check 'first launch initializes prefix' '1' "$(grep -c '^wineboot --init$' "$wine_log")"
check 'prefix has system32' 'yes' "$([ -d "$workdir/prefix/drive_c/windows/system32" ] && printf yes || printf no)"
check 'game starts after init' "$game_exe" "$(tail -n 1 "$wine_log")"

# Second launch reuses the prefix.
: >"$wine_log"
run_launch 2>"$workdir/second.log"
check 'second launch skips wineboot' '0' "$(grep -c '^wineboot --init$' "$wine_log")"
check 'second launch starts game' "$game_exe" "$(tail -n 1 "$wine_log")"

# A failing wineboot aborts the launch.
rm -rf "$workdir/prefix"
: >"$wine_log"
set +e
run_launch FAKE_WINEBOOT_FAIL=1 2>"$workdir/fail.log"
status=$?
set -e
check 'failed init exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'failed init reports the prefix' '1' "$(grep -c 'Wine prefix initialization failed' "$workdir/fail.log")"
check 'failed init does not start the game' '1' "$(grep -c '^wineboot --init$' "$wine_log")"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
