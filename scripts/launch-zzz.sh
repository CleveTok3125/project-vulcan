#!/bin/bash
set -Eeuo pipefail

export HOME="${HOME:-/data/home}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/data/home/.local/share}"
export WINEPREFIX="${WINEPREFIX:-/data/prefix}"
export PROTONPATH="${PROTONPATH:-/data/spritz-wine-tkg}"
export UMU_USE_STEAM="${UMU_USE_STEAM:-1}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH="${WINEARCH:-win64}"

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

runner=()
if [ -x "$PROTONPATH/bin/wine64" ]; then
    runner=("$PROTONPATH/bin/wine64" "$GAME_EXE")
elif [ -x "$PROTONPATH/proton" ]; then
    printf '[vulcan] wine64 not found; falling back to proton\n' >&2
    runner=(umu-run "$GAME_EXE")
else
    printf '[vulcan] no wine64 or proton under PROTONPATH: %s\n' "$PROTONPATH" >&2
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
