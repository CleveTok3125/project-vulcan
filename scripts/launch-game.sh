#!/bin/bash
set -Eeuo pipefail

# The Apollo app list calls this script with the selected catalog game id.
GAME_ID="${1:-}"
if [ -z "$GAME_ID" ]; then
    printf 'usage: %s <game_id>\n' "$(basename "$0")" >&2
    exit 2
fi

# shellcheck source=game-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/game-lib.sh"

GAMES_CATALOG_PATH="${GAMES_CATALOG_PATH:-/config/games/games.json}"
GAMES_MOUNT="${GAMES_MOUNT:-/games}"
WINE_MOUNT="${WINE_MOUNT:-/wine}"
PREFIX_ROOT="${PREFIX_ROOT:-/data/prefix}"
VULCAN_RUN_DIR="${VULCAN_RUN_DIR:-/data/run}"

validate_games_catalog "$GAMES_CATALOG_PATH" || exit 1

game_name="$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" name)"
if [ -z "$game_name" ]; then
    printf '[vulcan] game not found: %s\n' "$GAME_ID" >&2
    exit 1
fi
printf '[vulcan] starting %s (%s)\n' "$game_name" "$GAME_ID" >&2

GAME_RUNNER="$(game_runner "$GAMES_CATALOG_PATH" "$GAME_ID")"
export GAME_ID
if [ "$GAME_RUNNER" = "wine" ]; then
    game_exe_rel="$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" exe)"
    export GAME_EXE="${GAMES_MOUNT}/${GAME_ID}/${game_exe_rel}"
    GAME_RESET_PATHS="$(game_reset_paths "$GAMES_CATALOG_PATH" "$GAME_ID" | paste -sd: -)"
    export GAME_RESET_PATHS
    export WINEPREFIX="${WINEPREFIX:-${PREFIX_ROOT}/${GAME_ID}}"
    if [ -n "$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" wine_source)" ]; then
        export WINE_ROOT="${WINE_MOUNT}/${GAME_ID}"
    fi
fi

# One container owns one display, audio sink, and input socket. Keep one game
# process at a time; the descriptor is inherited by the game wrapper.
install -d -m 0755 "$VULCAN_RUN_DIR"
exec 9>"$VULCAN_RUN_DIR/game.lock"
if ! flock -n 9; then
    printf '[vulcan] another game is already running\n' >&2
    exit 1
fi

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/data/home/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/data/home/.cache}"
# The Windows build prefers LOCALAPPDATA, which points into the prefix, so the
# cache must be redirected to survive prefix and AppData resets.
# DXVK_STATE_CACHE_PATH covers 2.x, DXVK_SHADER_CACHE_PATH covers 3.x.
export DXVK_SHADER_CACHE_PATH="${DXVK_SHADER_CACHE_PATH:-/data/home/.cache/dxvk}"
export DXVK_STATE_CACHE_PATH="${DXVK_STATE_CACHE_PATH:-/data/home/.cache/dxvk}"
# No input method runs in the container; keep the host one out of the tools.
export XMODIFIERS="${XMODIFIERS:-@im=none}"
# Keep the NVIDIA GL shader cache instead of letting the driver prune it.
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}"
# The gamepad arrives as a file that the XInput proxy and the DSU server read;
# disabling it removes both paths.
INPUT_GAMEPAD="${INPUT_GAMEPAD:-1}"

GAME_WIDTH="${GAME_WIDTH:-1920}"
GAME_HEIGHT="${GAME_HEIGHT:-1080}"
GAME_FPS="${GAME_FPS:-144}"
GAMESCOPE_ENABLED="${GAMESCOPE_ENABLED:-1}"
GAMESCOPE_RT="${GAMESCOPE_RT:-0}"
# gamescope hides a client cursor it cannot hand to the nested host, so it
# paints the cursor into its own frames instead.
GAMESCOPE_GRAB_CURSOR="${GAMESCOPE_GRAB_CURSOR:-1}"
GAMESCOPE_HIDE_CURSOR_DELAY="${GAMESCOPE_HIDE_CURSOR_DELAY:-86400000}"
GAMESCOPE_TOUCH_MODE="${GAMESCOPE_TOUCH_MODE:-4}"
GAMESCOPE_FORCE_WINDOWS_FULLSCREEN="${GAMESCOPE_FORCE_WINDOWS_FULLSCREEN:-1}"

GAMESCOPE_ARGS=()
gamescope_args GAMESCOPE_ARGS

# OBS is an optional receiver; a missing wrapper must not stop the game.
# The wrapper sets OBS_VKCAPTURE for the game process. Clear it here so the
# layer does not load into gamescope's own Vulkan instance.
OBS_VKCAPTURE_ENABLED="${OBS_VKCAPTURE:-1}"
unset OBS_VKCAPTURE
OBS_GAMECAPTURE_BIN="${OBS_GAMECAPTURE_BIN:-/usr/bin/obs-gamecapture}"

# wrap_capture prefixes a runner array with the capture sender.
#
# Multiple sessions may run the same executable, so each one carries a distinct
# capture name that OBS can select. A session network namespace reaches the
# plugin through the capture relay, which the session start script runs.
wrap_capture() {
    local -n target="$1"
    [ "$OBS_VKCAPTURE_ENABLED" = "1" ] || return 0
    export OBS_VKCAPTURE_NAME="${OBS_VKCAPTURE_NAME:-${SESSION_ID:-vulcan}-${GAME_ID}}"
    if [ -x "$OBS_GAMECAPTURE_BIN" ]; then
        target=("$OBS_GAMECAPTURE_BIN" "${target[@]}")
    else
        printf '[vulcan] obs-gamecapture not found: %s; OBS capture disabled\n' \
            "$OBS_GAMECAPTURE_BIN" >&2
    fi
}

# run_eden launches the emulator and the DSU controller server.
#
# Eden keeps its data in the session volume: firmware, saves, installed
# updates, and the controller mapping. The game itself stays on the read-only
# image mount.
run_eden() {
    local rom game_path eden_bin dsud_bin dsud_ready="" dsud_pid=""

    rom="$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" rom)"
    game_path="${GAMES_MOUNT}/${GAME_ID}/${rom}"
    if [ ! -e "$game_path" ]; then
        printf '[vulcan] game rom not found: %s\n' "$game_path" >&2
        exit 1
    fi

    eden_bin="${EDEN_BIN:-eden}"
    if ! command -v "$eden_bin" >/dev/null 2>&1; then
        printf '[vulcan] eden not found: %s\n' "$eden_bin" >&2
        exit 1
    fi

    stop_dsud() {
        if [ -n "${dsud_pid:-}" ]; then
            kill -TERM "$dsud_pid" 2>/dev/null || true
            wait "$dsud_pid" 2>/dev/null || true
        fi
        if [ -n "${dsud_ready:-}" ]; then
            rm -f -- "$dsud_ready"
        fi
    }
    trap stop_dsud EXIT
    trap 'stop_dsud; exit 143' TERM INT

    if [ "$INPUT_GAMEPAD" = "1" ] && [ "${VULCAN_DSUD:-1}" = "1" ]; then
        dsud_bin="${VULCAN_DSUD_BIN:-/usr/local/bin/vulcan-dsud}"
        if [ -x "$dsud_bin" ]; then
            # The endpoint is exclusive. Another session on the host network
            # namespace may already serve it, and the emulator would then read
            # that session's pad, so a server that cannot bind stops the launch.
            dsud_ready="$(mktemp "${TMPDIR:-/tmp}/vulcan-dsud.XXXXXX")"
            rm -f -- "$dsud_ready"
            "$dsud_bin" 9>&- \
                --pad-file "${VULCAN_GAMEPAD_STATE:-/data/vulcan-gamepad.bin}" \
                --port "${VULCAN_DSUD_PORT:-26760}" \
                --ready-file "$dsud_ready" &
            dsud_pid=$!
            if ! wait_for_dsud "$dsud_pid" "$dsud_ready"; then
                printf '[vulcan] controller server did not start on %s\n' \
                    "$(dsud_endpoint)" >&2
                printf '[vulcan] free the port or set VULCAN_DSUD_PORT; set VULCAN_DSUD=0 to play without controller input\n' >&2
                stop_dsud
                exit 1
            fi
        else
            printf '[vulcan] vulcan-dsud not found: %s; controller input disabled\n' \
                "$dsud_bin" >&2
        fi
    fi

    local -a runner=("$eden_bin" -f -g "$game_path")
    wrap_capture runner

    if [ "$GAMESCOPE_ENABLED" = "1" ]; then
        gamescope "${GAMESCOPE_ARGS[@]}" -- "${runner[@]}" 9>&- &
    else
        "${runner[@]}" 9>&- &
    fi
    game_pid=$!

    local status=0
    wait "$game_pid" || status=$?
    exit "$status"
}

if [ "$GAME_RUNNER" = "eden" ]; then
    run_eden
fi

export WINE_ROOT="${WINE_ROOT:-${PROTONPATH:-/data/spritz-wine-tkg}}"
export UMU_USE_STEAM="${UMU_USE_STEAM:-1}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH="${WINEARCH:-win64}"
# Eventfd/futex synchronisation avoids wineserver round trips. fsync needs
# futex_waitv (Linux 5.16 or later).
export WINEESYNC="${WINEESYNC:-1}"
export WINEFSYNC="${WINEFSYNC:-1}"
# Empty by default; set to e.g. fps,frametimes to show the DXVK overlay.
export DXVK_HUD="${DXVK_HUD:-}"
D3D_BACKEND="${D3D_BACKEND:-dxvk}"
case "$D3D_BACKEND" in
    wined3d)
        export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d11,dxgi=b}"
        ;;
    dxvk)
        export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d11,dxgi,d3d12,d3d12core=n,b}"
        ;;
    *)
        printf '[vulcan] unsupported D3D_BACKEND: %s\n' "$D3D_BACKEND" >&2
        exit 1
        ;;
esac
if [ "$INPUT_GAMEPAD" = "1" ]; then
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES};xinput1_4,xinput1_3,xinput9_1_0=n,b"
fi

DXVK_DIR="${DXVK_DIR:-/data/dxvk}"

if [ ! -e "$GAME_EXE" ]; then
    printf '[vulcan] game executable not found: %s\n' "$GAME_EXE" >&2
    exit 1
fi

cd "$(dirname "$GAME_EXE")"

# Wine 11 ships one loader named `wine`; Spritz and Proton trees keep `wine64`.
wine_bin=""
for loader in wine64 wine; do
    if [ -x "$WINE_ROOT/bin/${loader}" ]; then
        wine_bin="$WINE_ROOT/bin/${loader}"
        break
    fi
done
if [ -z "$wine_bin" ]; then
    printf '[vulcan] wine loader not found under %s/bin\n' "$WINE_ROOT" >&2
    exit 1
fi

runner=("$wine_bin" "$GAME_EXE")

# Mirror the Lutris prefix command: the capture layer stays inside gamescope
# and wraps only the Wine process.
wrap_capture runner

# The prefix lives in the container volume. A fresh volume starts empty, so
# create the default Wine prefix here instead of shipping one in the image.
if [ ! -d "$WINEPREFIX/drive_c/windows/system32" ]; then
    printf '[vulcan] initializing Wine prefix: %s\n' "$WINEPREFIX" >&2
    WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
        "$wine_bin" wineboot --init \
        || {
            printf '[vulcan] Wine prefix initialization failed: %s\n' "$WINEPREFIX" >&2
            exit 1
        }
fi

# A fresh volume mounts the host game directory as a read-only lower layer, so
# state written there outside the container, such as stored logins, is still
# visible. Clear the configured paths once per prefix; removals land in the
# overlay upper layer and never touch the host files.
reset_marker="$WINEPREFIX/.vulcan-reset-paths"
if [ -n "${GAME_RESET_PATHS:-}" ] && [ ! -e "$reset_marker" ]; then
    printf '[vulcan] clearing stored game state\n' >&2
    IFS=':' read -r -a reset_paths <<<"$GAME_RESET_PATHS"
    for reset_path in "${reset_paths[@]}"; do
        case "$reset_path" in
            "" | /* | *..*)
                printf '[vulcan] ignoring unsafe reset path: %s\n' "$reset_path" >&2
                continue
                ;;
        esac
        rm -rf -- "$reset_path"
    done
    : >"$reset_marker"
fi

if [ "$D3D_BACKEND" = "dxvk" ]; then
    for dll in d3d11.dll dxgi.dll; do
        src="$DXVK_DIR/x64/$dll"
        if [ ! -f "$src" ]; then
            printf '[vulcan] missing DXVK file: %s\n' "$src" >&2
            exit 1
        fi
        install -m 0644 "$src" "$WINEPREFIX/drive_c/windows/system32/$dll"
    done
fi

XINPUT_DLL="${XINPUT_DLL:-/usr/lib/vulcan/xinput1_4.dll}"
XINPUT_DLL_32="${XINPUT_DLL_32:-/usr/lib/vulcan/xinput1_4_32.dll}"
if [ "$INPUT_GAMEPAD" = "1" ]; then
    if [ "$WINEARCH" = "win32" ]; then
        # A 32-bit prefix stores 32-bit modules in system32.
        if [ -f "$XINPUT_DLL_32" ]; then
            for dll in xinput1_4.dll xinput1_3.dll xinput9_1_0.dll; do
                install -m 0644 "$XINPUT_DLL_32" "$WINEPREFIX/drive_c/windows/system32/$dll"
            done
        else
            printf '[vulcan] 32-bit XInput proxy not found: %s; gamepad disabled\n' "$XINPUT_DLL_32" >&2
        fi
    else
        if [ -f "$XINPUT_DLL" ]; then
            for dll in xinput1_4.dll xinput1_3.dll xinput9_1_0.dll; do
                install -m 0644 "$XINPUT_DLL" "$WINEPREFIX/drive_c/windows/system32/$dll"
            done
        else
            printf '[vulcan] XInput proxy not found: %s; gamepad disabled\n' "$XINPUT_DLL" >&2
        fi
        # A 32-bit process resolves system32 to syswow64, so it needs its own copy.
        if [ ! -f "$XINPUT_DLL_32" ]; then
            printf '[vulcan] 32-bit XInput proxy not found: %s\n' "$XINPUT_DLL_32" >&2
        elif [ ! -d "$WINEPREFIX/drive_c/windows/syswow64" ]; then
            printf '[vulcan] prefix has no syswow64; 32-bit proxy not installed\n' >&2
        else
            for dll in xinput1_4.dll xinput1_3.dll xinput9_1_0.dll; do
                install -m 0644 "$XINPUT_DLL_32" "$WINEPREFIX/drive_c/windows/syswow64/$dll"
            done
        fi
    fi
    ln -sfn "${VULCAN_GAMEPAD_STATE:-/data/vulcan-gamepad.bin}" \
        "$WINEPREFIX/drive_c/vulcan-gamepad.bin"
    rumble_dir="${VULCAN_RUMBLE_DIR:-/data}"
    case "$rumble_dir" in
        /*) ;;
        *) rumble_dir="$(cd "$rumble_dir" 2>/dev/null && pwd)" || rumble_dir="" ;;
    esac
    if [ -n "$rumble_dir" ] && [ -d "$rumble_dir" ]; then
        ln -sfnT "$rumble_dir" "$WINEPREFIX/drive_c/vulcan-data" 2>/dev/null \
            || printf '[vulcan] cannot link the rumble directory: %s\n' "$rumble_dir" >&2
    else
        printf '[vulcan] rumble directory not found: %s\n' "${VULCAN_RUMBLE_DIR:-/data}" >&2
    fi
fi

rumble_state_dir="${rumble_dir:-${VULCAN_RUMBLE_DIR:-/data}}"

cleanup_rumble() {
    rm -f -- "$rumble_state_dir/vulcan-rumble.bin" \
        "$rumble_state_dir/vulcan-rumble.lock" 2>/dev/null || true
}

wineserver_bin="${WINE_ROOT}/bin/wineserver"
if [ ! -x "$wineserver_bin" ]; then
    wineserver_bin="$(command -v wineserver 2>/dev/null || true)"
fi
kill_wine() {
    if [ -n "${WINEPREFIX:-}" ] && [ -n "${wineserver_bin:-}" ]; then
        WINEPREFIX="$WINEPREFIX" "$wineserver_bin" -k >/dev/null 2>&1 || true
    fi
    # wineserver -k can leave an orphaned Wine service holding gamescope open;
    # the service ignores TERM.
    pkill -KILL -f 'winedevice\.exe' >/dev/null 2>&1 || true
}

game_basename="${GAME_EXE##*/}"
game_running() {
    local proc argv0 name
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        IFS= read -r -d '' argv0 <"$proc/cmdline" 2>/dev/null || true
        [ -n "$argv0" ] || continue
        name="${argv0##*/}"
        name="${name##*\\}"
        case "$name" in
            "$game_basename"|steam.exe) return 0 ;;
        esac
    done
    return 1
}

game_pid=""
forward_term() {
    kill_wine
    if [ -n "$game_pid" ]; then
        kill -TERM "$game_pid" 2>/dev/null || true
        wait "$game_pid" 2>/dev/null || true
    fi
    exit 143
}

trap cleanup_rumble EXIT
trap forward_term TERM INT

# A previous game can leave a stale record or lock after a crash.
if [ "$INPUT_GAMEPAD" = "1" ]; then
    rm -f -- "$rumble_state_dir/vulcan-rumble.bin" \
        "$rumble_state_dir/vulcan-rumble.lock" 2>/dev/null || true
fi

if [ "$GAMESCOPE_ENABLED" = "1" ]; then
    gamescope "${GAMESCOPE_ARGS[@]}" -- "${runner[@]}" 9>&- &
    game_pid=$!
else
    "${runner[@]}" 9>&- &
    game_pid=$!
fi

# Wine services keep gamescope and the wrapper alive after the game exits.
# Probe the game process itself and kill the prefix's Wine server once it is gone.
game_seen=0
while kill -0 "$game_pid" 2>/dev/null; do
    if game_running; then
        game_seen=1
    elif [ "$game_seen" = 1 ]; then
        printf '[vulcan] game exited; stopping Wine\n' >&2
        kill_wine
        for _ in $(seq 1 25); do
            kill -0 "$game_pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$game_pid" 2>/dev/null; then
            kill -TERM "$game_pid" 2>/dev/null || true
            for _ in $(seq 1 25); do
                kill -0 "$game_pid" 2>/dev/null || break
                sleep 0.2
            done
        fi
        if kill -0 "$game_pid" 2>/dev/null; then
            kill -KILL "$game_pid" 2>/dev/null || true
        fi
        break
    fi
    sleep 0.5
done

status=0
wait "$game_pid" || status=$?
exit "$status"
