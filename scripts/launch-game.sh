#!/bin/bash
set -Eeuo pipefail

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export WINEPREFIX="${WINEPREFIX:-/data/prefix}"
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

GAME_EXE="${GAME_EXE:?set GAME_EXE in .env.local}"
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

runner=()
if [ -x "$WINE_ROOT/bin/wine64" ]; then
    runner=("$WINE_ROOT/bin/wine64" "$GAME_EXE")
else
    printf '[vulcan] wine64 not found under WINE_ROOT: %s\n' "$WINE_ROOT" >&2
    exit 1
fi

# The prefix lives in the container volume. A fresh volume starts empty, so
# create the default Wine prefix here instead of shipping one in the image.
if [ ! -d "$WINEPREFIX/drive_c/windows/system32" ]; then
    printf '[vulcan] initializing Wine prefix: %s\n' "$WINEPREFIX" >&2
    WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
        "$WINE_ROOT/bin/wine64" wineboot --init \
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
