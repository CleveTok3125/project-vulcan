#!/bin/bash
# Runs the Eden AppImage extracted at build time.
#
# The game image has no FUSE, so the image is unpacked into /opt/eden and this
# wrapper keeps the AppRun environment the release expects.
set -Eeuo pipefail

APPDIR="${APPDIR:-/opt/eden}"
export APPDIR

if [ ! -x "$APPDIR/AppRun" ]; then
    printf '[vulcan] eden AppImage is not extracted at %s\n' "$APPDIR" >&2
    exit 1
fi

exec "$APPDIR/AppRun" "$@"
