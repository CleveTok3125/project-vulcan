#!/bin/bash
set -Eeuo pipefail

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export WINEPREFIX="${WINEPREFIX:-/data/prefix}"
export WINE_ROOT="${WINE_ROOT:-${PROTONPATH:-/data/spritz-wine-tkg}}"
export UMU_USE_STEAM="${UMU_USE_STEAM:-1}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH="${WINEARCH:-win64}"
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
DXVK_DIR="${DXVK_DIR:-/data/dxvk}"

GAME_EXE="${GAME_EXE:-/games/zzz/ZenlessZoneZero.exe}"
GAME_WIDTH="${GAME_WIDTH:-1920}"
GAME_HEIGHT="${GAME_HEIGHT:-1080}"
GAME_FPS="${GAME_FPS:-144}"
GAMESCOPE_ENABLED="${GAMESCOPE_ENABLED:-1}"
GAMESCOPE_RT="${GAMESCOPE_RT:-0}"
GAMESCOPE_GRAB_CURSOR="${GAMESCOPE_GRAB_CURSOR:-0}"
GAMESCOPE_FORCE_WINDOWS_FULLSCREEN="${GAMESCOPE_FORCE_WINDOWS_FULLSCREEN:-1}"

if [ ! -e "$GAME_EXE" ]; then
    printf '[vulcan] game executable not found: %s\n' "$GAME_EXE" >&2
    exit 1
fi

cd "$(dirname "$GAME_EXE")"

if [ "$D3D_BACKEND" = "dxvk" ]; then
    if [ ! -d "$WINEPREFIX/drive_c/windows/system32" ]; then
        printf '[vulcan] Wine prefix not initialized: %s\n' "$WINEPREFIX" >&2
        exit 1
    fi
    for dll in d3d11.dll dxgi.dll; do
        src="$DXVK_DIR/x64/$dll"
        if [ ! -f "$src" ]; then
            printf '[vulcan] missing DXVK file: %s\n' "$src" >&2
            exit 1
        fi
        install -m 0644 "$src" "$WINEPREFIX/drive_c/windows/system32/$dll"
    done
fi

runner=()
if [ -x "$WINE_ROOT/bin/wine64" ]; then
    runner=("$WINE_ROOT/bin/wine64" "$GAME_EXE")
else
    printf '[vulcan] wine64 not found under WINE_ROOT: %s\n' "$WINE_ROOT" >&2
    exit 1
fi

if [ "$GAMESCOPE_ENABLED" = "1" ]; then
    args=(
        --backend wayland
        -W "$GAME_WIDTH" -H "$GAME_HEIGHT"
        -w "$GAME_WIDTH" -h "$GAME_HEIGHT"
        -r "$GAME_FPS"
        -f
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
