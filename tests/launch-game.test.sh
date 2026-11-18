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
mkdir -p "$fake_root/bin" "$workdir/bin" "$workdir/games/test" "$workdir/games/other" \
    "$workdir/games/native" "$workdir/home" "$workdir/wine-mount/other/bin" \
    "$workdir/rumble" "$workdir/rumble-custom"
capture_log="$workdir/capture.log"
eden_log="$workdir/eden.log"
dsud_log="$workdir/dsud.log"
: >"$capture_log"
: >"$eden_log"
: >"$dsud_log"
: >"$workdir/games/native/game.xci"

cat >"$workdir/bin/eden" <<'EOF'
#!/bin/sh
printf 'eden:%s\n' "$*" >>"${EDEN_LOG:?}"
_lock=no
for _fd in /proc/self/fd/*; do
    case "$(readlink "$_fd" 2>/dev/null)" in
        *game.lock*) _lock=yes ;;
    esac
done
printf '%s\n' "$_lock" >"${EDEN_LOCK_LOG:?}"
if [ "${FAKE_EDEN_SLEEP:-0}" = "1" ]; then
    exec -a eden-fake sleep 30
fi
# Give the controller server time to start before this process exits.
sleep 0.3
exit "${FAKE_EDEN_STATUS:-0}"
EOF
cat >"$workdir/bin/vulcan-dsud" <<'EOF'
#!/bin/bash
printf 'dsud:%s\n' "$*" >>"${DSUD_LOG:?}"
printf '%s\n' "$$" >"${DSUD_PID_FILE:?}"
if [ "${DSUD_FAIL:-0}" = "1" ]; then
    printf 'cannot bind 127.0.0.1:26760; set --port to a free port\n' >&2
    exit 1
fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--ready-file" ]; then
        printf '127.0.0.1:26760\n' >"$2"
        break
    fi
    shift
done
exec -a vulcan-dsud-fake sleep 30
EOF
chmod 0755 "$workdir/bin/eden" "$workdir/bin/vulcan-dsud"

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
if [ "${FAKE_GAMESCOPE_HOLD:-0}" = "1" ]; then
    if [ -n "${GAMESCOPE_PID_LOG:-}" ]; then
        printf '%s\n' "$$" >"$GAMESCOPE_PID_LOG"
    fi
    ( exec -a winedevice.exe sleep 30 ) &
    "$@" &
    child=$!
    wait "$child" || true
    trap 'exit 0' TERM
    for _ in $(seq 1 30); do
        sleep 1
    done
else
    exec "$@"
fi
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
    mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
fi
if [ "$1" != "wineboot" ] && [ "${FAKE_WINE_EXEC:-0}" = "1" ]; then
    printf 'pid:%s\n' "$$" >>"$WINE_LOG"
    exec -a "$1" sleep 30
fi
if [ "$1" != "wineboot" ] && [ "${FAKE_WINE_SLEEP:-0}" = "1" ]; then
    trap 'printf "term\n" >>"$WINE_LOG"; exit 143' TERM
    printf 'pid:%s\n' "$$" >>"$WINE_LOG"
    for _ in $(seq 1 30); do
        sleep 1
    done
fi
exit 0
EOF
chmod 0755 "$fake_root/bin/wine64"
cp "$fake_root/bin/wine64" "$workdir/wine-mount/other/bin/wine64"

cat >"$fake_root/bin/wineserver" <<'EOF'
#!/bin/sh
printf 'wineserver:%s\n' "$*" >>"${WINE_LOG:?}"
if [ -n "${GAMESCOPE_PID_LOG:-}" ] && [ -f "$GAMESCOPE_PID_LOG" ]; then
    kill -TERM "$(cat "$GAMESCOPE_PID_LOG")" 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$fake_root/bin/wineserver"
cp "$fake_root/bin/wineserver" "$workdir/wine-mount/other/bin/wineserver"

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
    },
    {
      "id": "native",
      "name": "Native Game",
      "runner": "eden",
      "source": "/srv/games/native",
      "rom": "game.xci"
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
        VULCAN_RUMBLE_DIR="$workdir/rumble" \
        WINE_ROOT="$fake_root" \
        GAMESCOPE_ENABLED=0 \
        D3D_BACKEND=wined3d \
        XINPUT_DLL="$workdir/missing.dll" \
        WINE_LOG="$wine_log" \
        EDEN_LOG="$eden_log" \
        EDEN_LOCK_LOG="$workdir/eden-lock" \
        DSUD_LOG="$dsud_log" \
        DSUD_PID_FILE="$workdir/dsud.pid" \
        VULCAN_DSUD_BIN="$workdir/bin/vulcan-dsud" \
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
check 'rumble directory symlink installed' "$workdir/rumble" \
    "$(readlink "$workdir/prefix/test/drive_c/vulcan-data" 2>/dev/null || true)"
check 'xinput override enabled' 'yes' \
    "$(grep -q 'xinput1_4' "$wine_log" && printf yes || printf no)"

rm -rf "$workdir/prefix/test"
: >"$wine_log"
run_launch test INPUT_GAMEPAD=0 XINPUT_DLL="$xinput_dll" 2>"$workdir/gamepad-off.log"
check 'xinput proxy skipped when disabled' 'no' \
    "$([ -f "$workdir/prefix/test/drive_c/windows/system32/xinput1_4.dll" ] && printf yes || printf no)"
check 'rumble symlink skipped when disabled' 'no' \
    "$([ -L "$workdir/prefix/test/drive_c/vulcan-data" ] && printf yes || printf no)"
check 'xinput override skipped when disabled' 'no' \
    "$(grep -q 'xinput1_4' "$wine_log" && printf yes || printf no)"

# A custom rumble directory is linked for the session.
rm -rf "$workdir/prefix/test"
run_launch test XINPUT_DLL="$xinput_dll" VULCAN_RUMBLE_DIR="$workdir/rumble-custom" 2>"$workdir/gamepad-rumble.log"
check 'custom rumble directory is linked' "$workdir/rumble-custom" \
    "$(readlink "$workdir/prefix/test/drive_c/vulcan-data" 2>/dev/null || true)"

# A missing rumble directory is reported and leaves no dangling link.
rm -rf "$workdir/prefix/test"
run_launch test XINPUT_DLL="$xinput_dll" VULCAN_RUMBLE_DIR="$workdir/missing-rumble" \
    2>"$workdir/gamepad-rumble-missing.log"
check 'missing rumble directory is reported' '1' \
    "$(grep -c 'rumble directory not found' "$workdir/gamepad-rumble-missing.log")"
check 'missing rumble directory is not linked' 'no' \
    "$([ -L "$workdir/prefix/test/drive_c/vulcan-data" ] && printf yes || printf no)"

# The wrapper clears stale rumble state and forwards termination.
rm -rf "$workdir/prefix/test"
: >"$workdir/rumble/vulcan-rumble.bin"
: >"$workdir/rumble/vulcan-rumble.lock"
: >"$wine_log"
run_launch test XINPUT_DLL="$xinput_dll" FAKE_WINE_SLEEP=1 2>"$workdir/signal.log" &
wrapper_host=$!
for _ in $(seq 1 100); do
    grep -q '^pid:' "$wine_log" && break
    sleep 0.05
done
check 'wrapper starts the game' '1' "$(grep -c '^pid:' "$wine_log")"
check 'wrapper clears stale rumble state at start' 'no' \
    "$([ -e "$workdir/rumble/vulcan-rumble.bin" ] || [ -e "$workdir/rumble/vulcan-rumble.lock" ] && printf yes || printf no)"

game_wrapper="$(pgrep -f "$repo_root/scripts/launch-game.sh test" | head -n 1 || true)"
: >"$workdir/rumble/vulcan-rumble.bin"
: >"$workdir/rumble/vulcan-rumble.lock"
if [ -n "$game_wrapper" ]; then
    kill -TERM "$game_wrapper"
else
    pkill -TERM -P "$wrapper_host" 2>/dev/null || true
fi
set +e
wait "$wrapper_host" 2>/dev/null
status=$?
set -e
check 'wrapper receives a launch process' 'yes' "$([ -n "$game_wrapper" ] && printf yes || printf no)"
check 'wrapper forwards termination' '1' "$(grep -c '^term$' "$wine_log")"
check 'wrapper clears rumble state at exit' 'no' \
    "$([ -e "$workdir/rumble/vulcan-rumble.bin" ] || [ -e "$workdir/rumble/vulcan-rumble.lock" ] && printf yes || printf no)"
check 'wrapper exits after termination' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"

# Wine services can keep gamescope alive after the game exits. The wrapper
# watches the game process and kills the prefix's wineserver.
rm -rf "$workdir/prefix/test"
: >"$wine_log"
: >"$workdir/gamescope.pid"
run_launch test XINPUT_DLL="$xinput_dll" GAMESCOPE_ENABLED=1 \
    FAKE_GAMESCOPE_HOLD=1 FAKE_WINE_EXEC=1 \
    GAMESCOPE_PID_LOG="$workdir/gamescope.pid" \
    2>"$workdir/watcher.log" &
watcher_host=$!
for _ in $(seq 1 100); do
    grep -q '^pid:' "$wine_log" && break
    sleep 0.05
done
sleep 0.8
wine_pid="$(sed -n 's/^pid://p' "$wine_log" | tail -n 1)"
check 'watcher sees the game process' '1' "$([ -n "$wine_pid" ] && printf 1 || printf 0)"
if [ -n "$wine_pid" ]; then
    kill -TERM "$wine_pid"
fi
set +e
wait "$watcher_host" 2>/dev/null
set -e
check 'watcher runs wineserver -k' '1' "$(grep -c '^wineserver:-k$' "$wine_log")"
check 'watcher kills winedevice' 'no' \
    "$(pgrep -f 'winedevice\.exe' >/dev/null 2>&1 && printf yes || printf no)"
check 'watcher clears rumble state' 'no' \
    "$([ -e "$workdir/rumble/vulcan-rumble.bin" ] || [ -e "$workdir/rumble/vulcan-rumble.lock" ] && printf yes || printf no)"
check 'watcher exits the wrapper' 'yes' "$([ -n "$wine_pid" ] && printf yes || printf no)"

# A 32-bit process resolves system32 to syswow64 and needs its own copy.
rm -rf "$workdir/prefix/test"
xinput_dll_32="$workdir/xinput1_4_32.dll"
printf 'xinput32' >"$xinput_dll_32"
: >"$wine_log"
run_launch test XINPUT_DLL="$xinput_dll" XINPUT_DLL_32="$xinput_dll_32" 2>"$workdir/gamepad-32.log"
check '32-bit xinput proxy installed' 'yes' \
    "$([ -f "$workdir/prefix/test/drive_c/windows/syswow64/xinput1_4.dll" ] && printf yes || printf no)"
check '32-bit proxy keeps its own binary' 'xinput32' \
    "$(cat "$workdir/prefix/test/drive_c/windows/syswow64/xinput1_4.dll" 2>/dev/null || true)"
check '32-bit alias xinput1_3 installed' 'xinput32' \
    "$(cat "$workdir/prefix/test/drive_c/windows/syswow64/xinput1_3.dll" 2>/dev/null || true)"
check '32-bit alias xinput9_1_0 installed' 'xinput32' \
    "$(cat "$workdir/prefix/test/drive_c/windows/syswow64/xinput9_1_0.dll" 2>/dev/null || true)"

# A missing 32-bit proxy is reported without disturbing the 64-bit install.
rm -rf "$workdir/prefix/test"
: >"$wine_log"
run_launch test XINPUT_DLL="$xinput_dll" XINPUT_DLL_32="$workdir/missing32.dll" 2>"$workdir/gamepad-32-missing.log"
check 'missing 32-bit proxy is reported' '1' \
    "$(grep -c '32-bit XInput proxy not found' "$workdir/gamepad-32-missing.log")"
check 'missing 32-bit proxy keeps the 64-bit install' 'yes' \
    "$([ -f "$workdir/prefix/test/drive_c/windows/system32/xinput1_4.dll" ] && printf yes || printf no)"

# A win32 prefix stores 32-bit modules in system32.
rm -rf "$workdir/prefix/test"
: >"$wine_log"
run_launch test WINEARCH=win32 XINPUT_DLL="$xinput_dll" XINPUT_DLL_32="$xinput_dll_32" 2>"$workdir/gamepad-win32.log"
check 'win32 prefix receives the 32-bit proxy' 'xinput32' \
    "$(cat "$workdir/prefix/test/drive_c/windows/system32/xinput1_4.dll" 2>/dev/null || true)"
check 'win32 prefix receives the rumble directory' "$workdir/rumble" \
    "$(readlink "$workdir/prefix/test/drive_c/vulcan-data" 2>/dev/null || true)"
check 'win32 prefix logs no missing proxy' '0' \
    "$(grep -c 'XInput proxy not found' "$workdir/gamepad-win32.log" || true)"

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

# A native emulator entry starts the emulator and the DSU controller server.
: >"$wine_log"
: >"$eden_log"
: >"$dsud_log"
rm -f "$workdir/dsud.pid"
run_launch native 2>"$workdir/eden-launch.log"
check 'eden receives the rom' "eden:-f -g $workdir/games/native/game.xci" "$(cat "$eden_log")"
check 'eden launch does not touch wine' '0' "$(wc -l <"$wine_log")"
check 'eden does not inherit the session lock' 'no' "$(cat "$workdir/eden-lock")"
check 'dsud receives the pad file' 'yes' \
    "$(grep -q '^dsud:--pad-file /data/vulcan-gamepad.bin --port 26760 --ready-file ' "$dsud_log" \
        && printf yes || printf no)"
check 'dsud stops with the emulator' 'no' \
    "$([ -e "$workdir/dsud.pid" ] && kill -0 "$(cat "$workdir/dsud.pid")" 2>/dev/null && printf yes || printf no)"

# The controller server can be disabled for troubleshooting.
: >"$dsud_log"
run_launch native VULCAN_DSUD=0 2>"$workdir/eden-no-dsud.log"
check 'dsud can be disabled' '0' "$(wc -l <"$dsud_log")"

# The pad switch covers the controller server as well.
: >"$dsud_log"
run_launch native INPUT_GAMEPAD=0 2>"$workdir/eden-no-pad.log"
check 'the pad switch skips the controller server' '0' "$(wc -l <"$dsud_log")"

# A controller server that cannot claim the endpoint stops the launch: the
# emulator would otherwise read the pad of whichever session owns the port.
: >"$eden_log"
set +e
run_launch native DSUD_FAIL=1 2>"$workdir/eden-dsud-taken.log"
status=$?
set -e
check 'busy controller port exits non-zero' 'yes' \
    "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'busy controller port is reported' '1' \
    "$(grep -c 'controller server did not start on 127.0.0.1:26760' "$workdir/eden-dsud-taken.log")"
check 'busy controller port starts no emulator' '0' "$(wc -l <"$eden_log")"

# gamescope wraps the emulator and the capture sender stays inside it.
: >"$capture_log"
run_launch native GAMESCOPE_ENABLED=1 2>"$workdir/eden-gamescope.log"
check 'gamescope is the outer command for eden' 'gamescope:' \
    "$(head -n 1 "$capture_log" | cut -d: -f1):"
check 'eden runs inside gamescope' 'gamecapture:' \
    "$(sed -n '2p' "$capture_log" | cut -d: -f1):"

# A missing rom aborts before the emulator starts.
mv "$workdir/games/native/game.xci" "$workdir/games/native/game.xci.bak"
: >"$eden_log"
set +e
run_launch native 2>"$workdir/eden-missing-rom.log"
status=$?
set -e
mv "$workdir/games/native/game.xci.bak" "$workdir/games/native/game.xci"
check 'missing rom exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'missing rom is reported' '1' "$(grep -c 'game rom not found' "$workdir/eden-missing-rom.log")"
check 'missing rom starts no emulator' '0' "$(wc -l <"$eden_log")"

# A missing emulator is reported.
set +e
run_launch native EDEN_BIN="$workdir/missing-eden" 2>"$workdir/eden-missing.log"
status=$?
set -e
check 'missing eden exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'missing eden is reported' '1' "$(grep -c 'eden not found' "$workdir/eden-missing.log")"

# The emulator exit status reaches Apollo.
set +e
run_launch native FAKE_EDEN_STATUS=7 2>"$workdir/eden-status.log"
status=$?
set -e
check 'eden exit status is preserved' '7' "$status"

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
