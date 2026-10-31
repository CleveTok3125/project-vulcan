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
mkdir -p "$fake_root/bin" "$workdir/bin" "$workdir/games/test" "$workdir/games/other" "$workdir/home" "$workdir/wine-mount/other/bin"
capture_log="$workdir/capture.log"
: >"$capture_log"

cat >"$workdir/bin/obs-gamecapture" <<'EOF'
#!/bin/sh
printf 'gamecapture:%s:%s\n' "${OBS_VKCAPTURE_NAME-}" "$*" >>"${CAPTURE_LOG:?}"
exec "$@"
EOF
cat >"$workdir/bin/gamescope" <<'EOF'
#!/bin/sh
printf 'gamescope:%s\n' "$*" >>"${CAPTURE_LOG:?}"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    shift
done
[ "$#" -gt 0 ] && shift
exec "$@"
EOF
chmod 0755 "$workdir/bin/obs-gamecapture" "$workdir/bin/gamescope"
game_exe="$workdir/games/test/Game.exe"
other_exe="$workdir/games/other/Other.exe"
wine_log="$workdir/wine.log"
: >"$game_exe"
: >"$other_exe"

cat >"$fake_root/bin/wine64" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$WINE_LOG"
printf 'env:%s:%s:%s:%s:%s\n' \
    "${WINEESYNC-}" "${WINEFSYNC-}" "${XMODIFIERS-}" \
    "${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP-}" "${DXVK_HUD-}" >>"$WINE_LOG"
printf 'overrides:%s\n' "${WINEDLLOVERRIDES-}" >>"$WINE_LOG"
if [ "$1" = "wineboot" ]; then
    if [ "${FAKE_WINEBOOT_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    mkdir -p "$WINEPREFIX/drive_c/windows/system32"
fi
exit 0
EOF
chmod 0755 "$fake_root/bin/wine64"
cp "$fake_root/bin/wine64" "$workdir/wine-mount/other/bin/wine64"

catalog="$workdir/games.json"
cat >"$catalog" <<'EOF'
{
  "games": [
    {
      "id": "test",
      "name": "Test Game",
      "source": "/srv/games/test",
      "exe": "Game.exe",
      "reset_paths": ["State/Login"]
    },
    {
      "id": "other",
      "name": "Other Game",
      "source": "/srv/games/other",
      "exe": "Other.exe",
      "wine_source": "/srv/wine/other"
    }
  ]
}
EOF

run_launch() {
    local game_id="$1"
    shift
    env -i PATH="$workdir/bin:/usr/bin:/bin" HOME="$workdir/home" \
        SESSION_ID=session-a \
        OBS_GAMECAPTURE_BIN="$workdir/bin/obs-gamecapture" \
        CAPTURE_LOG="$capture_log" \
        GAMES_CATALOG_PATH="$catalog" \
        GAMES_MOUNT="$workdir/games" \
        WINE_MOUNT="$workdir/wine-mount" \
        PREFIX_ROOT="$workdir/prefix" \
        VULCAN_RUN_DIR="$workdir/run" \
        WINE_ROOT="$fake_root" \
        GAMESCOPE_ENABLED=0 \
        D3D_BACKEND=wined3d \
        XINPUT_DLL="$workdir/missing.dll" \
        WINE_LOG="$wine_log" \
        "$@" bash "$repo_root/scripts/launch-game.sh" "$game_id"
}

# First launch: the per-game prefix is initialized before the game starts.
run_launch test 2>"$workdir/first.log"
check 'first launch initializes prefix' '1' "$(grep -c '^wineboot --init$' "$wine_log")"
check 'prefix is scoped by game' 'yes' \
    "$([ -d "$workdir/prefix/test/drive_c/windows/system32" ] && printf yes || printf no)"
check 'game starts after init' '1' "$(grep -cx -- "$game_exe" "$wine_log")"
check 'wine environment defaults' 'yes' "$(grep -qx 'env:1:1:@im=none:1:' "$wine_log" && printf yes || printf no)"

# The default wraps only the Wine command, just like the Lutris prefix command.
check 'game capture wrapper used' '1' "$(grep -c '^gamecapture:' "$capture_log")"
check 'game capture wraps the wine loader' 'yes' \
    "$(grep -q "^gamecapture:.*${fake_root}/bin/wine64" "$capture_log" && printf yes || printf no)"
check 'capture name is session scoped' 'session-a-test' \
    "$(sed -n 's/^gamecapture:\([^:]*\):.*/\1/p' "$capture_log" | head -n 1)"

# A custom capture name is preserved for clients that need it.
: >"$capture_log"
run_launch test OBS_VKCAPTURE_NAME=custom-name 2>"$workdir/custom-name.log"
check 'custom capture name is preserved' 'custom-name' \
    "$(sed -n 's/^gamecapture:\([^:]*\):.*/\1/p' "$capture_log" | head -n 1)"

# The wrapper can be disabled for troubleshooting.
: >"$capture_log"
run_launch test OBS_VKCAPTURE=0 2>"$workdir/no-capture.log"
check 'game capture can be disabled' '0' "$(grep -c '^gamecapture:' "$capture_log")"

# With gamescope, the wrapper stays inside the gamescope command line.
: >"$capture_log"
run_launch test GAMESCOPE_ENABLED=1 2>"$workdir/gamescope.log"
check 'gamescope is outer command' 'gamescope:' "$(head -n 1 "$capture_log" | cut -d: -f1):"
check 'game capture is inside gamescope' 'gamecapture:' "$(sed -n '2p' "$capture_log" | cut -d: -f1):"

# A missing wrapper must not prevent the game from starting.
: >"$capture_log"
run_launch test OBS_GAMECAPTURE_BIN="$workdir/missing-obs-gamecapture" 2>"$workdir/no-wrapper.log"
check 'missing wrapper is reported' '1' "$(grep -c 'obs-gamecapture not found' "$workdir/no-wrapper.log")"
check 'missing wrapper still starts the game' 'yes' \
    "$([ "$(grep -cx -- "$game_exe" "$wine_log")" -gt 0 ] && printf yes || printf no)"

# Second launch reuses the prefix.
: >"$wine_log"
run_launch test 2>"$workdir/second.log"
check 'second launch skips wineboot' '0' "$(grep -c '^wineboot --init$' "$wine_log")"
check 'second launch starts game' '1' "$(grep -cx -- "$game_exe" "$wine_log")"

# Each game gets its own prefix and executable.
: >"$wine_log"
run_launch other 2>"$workdir/other.log"
check 'other game starts' '1' "$(grep -cx -- "$other_exe" "$wine_log")"
check 'other game has its own prefix' 'yes' \
    "$([ -d "$workdir/prefix/other/drive_c/windows/system32" ] && printf yes || printf no)"
check 'other game uses its catalog wine tree' 'yes' \
    "$([ -x "$workdir/wine-mount/other/bin/wine64" ] && grep -q '^wineboot --init$' "$wine_log" && printf yes || printf no)"
check 'other game does not reuse test prefix' 'yes' \
    "$([ ! -e "$workdir/prefix/other/.vulcan-reset-paths" ] && printf yes || printf no)"

# A missing game id is rejected before touching Wine.
: >"$wine_log"
set +e
run_launch "" 2>"$workdir/no-id.log"
status=$?
set -e
check 'missing game id exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'missing game id prints usage' '1' "$(grep -c 'usage:' "$workdir/no-id.log")"
check 'missing game id starts no game' '0' "$(grep -c -- "$game_exe" "$wine_log")"

# An unknown game id is rejected.
set +e
run_launch absent 2>"$workdir/absent.log"
status=$?
set -e
check 'unknown game id exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'unknown game id is reported' '1' "$(grep -c 'game not found' "$workdir/absent.log")"

# A missing catalog is rejected.
set +e
run_launch test GAMES_CATALOG_PATH="$workdir/missing.json" 2>"$workdir/no-catalog.log"
status=$?
set -e
check 'missing catalog exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'missing catalog is reported' '1' "$(grep -c 'missing game catalog' "$workdir/no-catalog.log")"

# Unsafe catalog entries are rejected before Wine starts.
jq '.games[0].reset_paths[0] = "../outside"' "$catalog" >"$workdir/unsafe.json"
: >"$wine_log"
set +e
run_launch test GAMES_CATALOG_PATH="$workdir/unsafe.json" 2>"$workdir/unsafe.log"
status=$?
set -e
check 'unsafe catalog exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'unsafe catalog is reported' '1' "$(grep -c 'reset path must be relative' "$workdir/unsafe.log")"
check 'unsafe catalog starts no game' '0' "$(grep -c -- "$game_exe" "$wine_log")"

# Wine 11 ships a single `wine` loader; a tree without wine64 still runs.
wine_only_root="$workdir/wine-unified"
mkdir -p "$wine_only_root/bin"
cp "$fake_root/bin/wine64" "$wine_only_root/bin/wine"
: >"$wine_log"
run_launch test WINE_ROOT="$wine_only_root" 2>"$workdir/wine-unified.log"
check 'unified wine loader starts game' '1' "$(grep -cx -- "$game_exe" "$wine_log")"

# A tree without any loader aborts the launch.
: >"$wine_log"
set +e
run_launch test WINE_ROOT="$workdir/wine-empty" 2>"$workdir/wine-missing.log"
status=$?
set -e
check 'missing wine loader exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'missing wine loader is reported' '1' "$(grep -c 'wine loader not found' "$workdir/wine-missing.log")"
check 'missing wine loader does not start game' '0' "$(grep -c -- "$game_exe" "$wine_log")"

# DXVK_HUD passes through when set.
: >"$wine_log"
run_launch test DXVK_HUD=fps 2>"$workdir/hud.log"
check 'dxvk hud override' 'yes' "$(grep -qx 'env:1:1:@im=none:1:fps' "$wine_log" && printf yes || printf no)"

# The XInput proxy installs and overrides only while the gamepad is enabled.
xinput_dll="$workdir/xinput1_4.dll"
: >"$xinput_dll"
: >"$wine_log"
run_launch test XINPUT_DLL="$xinput_dll" 2>"$workdir/gamepad.log"
check 'xinput proxy installed' 'yes' \
    "$([ -f "$workdir/prefix/test/drive_c/windows/system32/xinput1_4.dll" ] && printf yes || printf no)"
check 'gamepad state symlink installed' '/data/vulcan-gamepad.bin' \
    "$(readlink "$workdir/prefix/test/drive_c/vulcan-gamepad.bin" 2>/dev/null || true)"
check 'xinput override enabled' 'yes' \
    "$(grep -q 'xinput1_4' "$wine_log" && printf yes || printf no)"

rm -rf "$workdir/prefix/test"
: >"$wine_log"
run_launch test INPUT_GAMEPAD=0 XINPUT_DLL="$xinput_dll" 2>"$workdir/gamepad-off.log"
check 'xinput proxy skipped when disabled' 'no' \
    "$([ -f "$workdir/prefix/test/drive_c/windows/system32/xinput1_4.dll" ] && printf yes || printf no)"
check 'xinput override skipped when disabled' 'no' \
    "$(grep -q 'xinput1_4' "$wine_log" && printf yes || printf no)"

# Stored game state is cleared once per prefix using the catalog entry.
rm -rf "$workdir/prefix/test"
mkdir -p "$workdir/games/test/State/Login"
: >"$workdir/games/test/State/Login/token"
run_launch test 2>"$workdir/reset.log"
check 'reset removes stored state' 'no' \
    "$([ -e "$workdir/games/test/State/Login" ] && printf yes || printf no)"
check 'reset writes the marker' 'yes' \
    "$([ -e "$workdir/prefix/test/.vulcan-reset-paths" ] && printf yes || printf no)"

mkdir -p "$workdir/games/test/State/Login"
: >"$workdir/games/test/State/Login/token"
run_launch test 2>"$workdir/reset-second.log"
check 'reset runs once per prefix' 'yes' \
    "$([ -e "$workdir/games/test/State/Login" ] && printf yes || printf no)"

# A failing wineboot aborts the launch.
rm -rf "$workdir/prefix/test"
: >"$wine_log"
set +e
run_launch test FAKE_WINEBOOT_FAIL=1 2>"$workdir/fail.log"
status=$?
set -e
check 'failed init exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'failed init reports the prefix' '1' "$(grep -c 'Wine prefix initialization failed' "$workdir/fail.log")"
check 'failed init does not start the game' '1' "$(grep -c '^wineboot --init$' "$wine_log")"

# A second launch is rejected while another game holds the lock.
mkdir -p "$workdir/run"
exec 9>"$workdir/run/game.lock"
flock -n 9
set +e
run_launch test 2>"$workdir/locked.log"
status=$?
set -e
exec 9>&-
check 'locked session exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'locked session is reported' '1' "$(grep -c 'another game is already running' "$workdir/locked.log")"

if [ "$failures" -ne 0 ]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
