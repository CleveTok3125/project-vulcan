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

game_exe_rel="$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" exe)"
export GAME_ID
export GAME_EXE="${GAMES_MOUNT}/${GAME_ID}/${game_exe_rel}"
GAME_RESET_PATHS="$(game_reset_paths "$GAMES_CATALOG_PATH" "$GAME_ID" | paste -sd: -)"
export GAME_RESET_PATHS
export WINEPREFIX="${WINEPREFIX:-${PREFIX_ROOT}/${GAME_ID}}"
if [ -n "$(game_field "$GAMES_CATALOG_PATH" "$GAME_ID" wine_source)" ]; then
    export WINE_ROOT="${WINE_MOUNT}/${GAME_ID}"
fi

# One container owns one display, audio sink, and input socket. Keep one game
# process at a time; the lock survives the exec into Wine.
install -d -m 0755 "$VULCAN_RUN_DIR"
exec 9>"$VULCAN_RUN_DIR/game.lock"
if ! flock -n 9; then
    printf '[vulcan] another game is already running\n' >&2
    exit 1
fi

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export WINE_ROOT="${WINE_ROOT:-${PROTONPATH:-/data/spritz-wine-tkg}}"
export UMU_USE_STEAM="${UMU_USE_STEAM:-1}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH="${WINEARCH:-win64}"
# The gamepad arrives as a file that the XInput proxy reads; disabling it skips
# both the file and the DLL.
INPUT_GAMEPAD="${INPUT_GAMEPAD:-1}"
# Eventfd/futex synchronisation avoids wineserver round trips. fsync needs
# futex_waitv (Linux 5.16 or later).
export WINEESYNC="${WINEESYNC:-1}"
export WINEFSYNC="${WINEFSYNC:-1}"
# No input method runs in the container; keep the host one out of Wine.
export XMODIFIERS="${XMODIFIERS:-@im=none}"
# Keep the NVIDIA GL shader cache instead of letting the driver prune it.
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}"
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

# Mirror the Lutris prefix command: keep the capture layer inside gamescope
# and wrap only the Wine process. OBS is an optional receiver; a missing
# wrapper must not stop the game.
OBS_VKCAPTURE="${OBS_VKCAPTURE:-1}"
OBS_GAMECAPTURE_BIN="${OBS_GAMECAPTURE_BIN:-/usr/bin/obs-gamecapture}"
if [ "$OBS_VKCAPTURE" = "1" ]; then
    if [ -x "$OBS_GAMECAPTURE_BIN" ]; then
        runner=("$OBS_GAMECAPTURE_BIN" "${runner[@]}")
    else
        printf '[vulcan] obs-gamecapture not found: %s; OBS capture disabled\n' \
            "$OBS_GAMECAPTURE_BIN" >&2
    fi
fi

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
if [ "$INPUT_GAMEPAD" = "1" ]; then
    if [ -f "$XINPUT_DLL" ]; then
        for dll in xinput1_4.dll xinput1_3.dll xinput9_1_0.dll; do
            install -m 0644 "$XINPUT_DLL" "$WINEPREFIX/drive_c/windows/system32/$dll"
        done
    else
        printf '[vulcan] XInput proxy not found: %s; gamepad disabled\n' "$XINPUT_DLL" >&2
    fi
    ln -sfn "${VULCAN_GAMEPAD_STATE:-/data/vulcan-gamepad.bin}" \
        "$WINEPREFIX/drive_c/vulcan-gamepad.bin"
fi

if [ "$GAMESCOPE_ENABLED" = "1" ]; then
    args=(
        --backend wayland
        -W "$GAME_WIDTH" -H "$GAME_HEIGHT"
        -w "$GAME_WIDTH" -h "$GAME_HEIGHT"
        -r "$GAME_FPS"
        -f
        -C "$GAMESCOPE_HIDE_CURSOR_DELAY"
        --default-touch-mode "$GAMESCOPE_TOUCH_MODE"
    )

    if [ "$GAMESCOPE_RT" = "1" ]; then
        args+=(--rt)
    fi
    if [ "$GAMESCOPE_GRAB_CURSOR" = "1" ]; then
        args+=(--force-grab-cursor)
    fi
    if [ "$GAMESCOPE_FORCE_WINDOWS_FULLSCREEN" = "1" ]; then
        args+=(--force-windows-fullscreen)
    fi

    exec gamescope "${args[@]}" -- "${runner[@]}"
fi

exec "${runner[@]}"
