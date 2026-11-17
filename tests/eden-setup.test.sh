#!/bin/bash
# Verifies the Eden setup app: no game argument, DSU server lifetime, guards.
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

mkdir -p "$workdir/bin" "$workdir/home" "$workdir/run"
eden_log="$workdir/eden.log"
dsud_log="$workdir/dsud.log"
gamescope_log="$workdir/gamescope.log"
: >"$eden_log"
: >"$dsud_log"
: >"$gamescope_log"

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
# Give the controller server time to start before this process exits.
sleep 0.3
exit 0
EOF
cat >"$workdir/bin/gamescope" <<'EOF'
#!/bin/sh
printf 'gamescope:%s\n' "$*" >>"${GAMESCOPE_LOG:?}"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    shift
done
shift
exec "$@"
EOF
cat >"$workdir/bin/vulcan-dsud" <<'EOF'
#!/bin/bash
printf 'dsud:%s\n' "$*" >>"${DSUD_LOG:?}"
printf '%s\n' "$$" >"${DSUD_PID_FILE:?}"
exec -a vulcan-dsud-fake sleep 30
EOF
chmod 0755 "$workdir/bin/eden" "$workdir/bin/gamescope" "$workdir/bin/vulcan-dsud"

cat >"$workdir/eden.json" <<'EOF'
{
  "games": [
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
cat >"$workdir/wine-only.json" <<'EOF'
{
  "games": [
    {
      "id": "test",
      "name": "Test Game",
      "source": "/srv/games/test",
      "exe": "Game.exe"
    }
  ]
}
EOF

run_setup() {
    env -i PATH="$workdir/bin:/usr/bin:/bin" HOME="$workdir/home" \
        GAMES_CATALOG_PATH="$workdir/eden.json" \
        VULCAN_RUN_DIR="$workdir/run" \
        VULCAN_DSUD_BIN="$workdir/bin/vulcan-dsud" \
        EDEN_LOG="$eden_log" \
        EDEN_LOCK_LOG="$workdir/eden-lock" \
        DSUD_LOG="$dsud_log" \
        GAMESCOPE_LOG="$gamescope_log" \
        DSUD_PID_FILE="$workdir/dsud.pid" \
        "$@" bash "$repo_root/scripts/eden-setup.sh"
}

run_setup 2>"$workdir/setup.log"
check 'setup opens eden without a game' 'eden:' "$(cat "$eden_log")"
check 'setup does not leak the session lock' 'no' "$(cat "$workdir/eden-lock")"
check 'setup runs under gamescope' 'yes' \
    "$(grep -q '^gamescope:.*--backend wayland' "$gamescope_log" && printf yes || printf no)"
check 'setup starts the dsu server' \
    'dsud:--pad-file /data/vulcan-gamepad.bin --port 26760' "$(head -n 1 "$dsud_log")"
check 'setup stops the dsu server' 'no' \
    "$([ -e "$workdir/dsud.pid" ] && kill -0 "$(cat "$workdir/dsud.pid")" 2>/dev/null \
       && printf yes || printf no)"

: >"$gamescope_log"
run_setup GAMESCOPE_ENABLED=0 2>"$workdir/no-gamescope.log"
check 'setup can skip gamescope' '0' "$(wc -l <"$gamescope_log")"

: >"$dsud_log"
run_setup VULCAN_DSUD=0 2>"$workdir/no-dsud.log"
check 'setup can skip the dsu server' '0' "$(wc -l <"$dsud_log")"

set +e
run_setup GAMES_CATALOG_PATH="$workdir/wine-only.json" 2>"$workdir/no-eden.log"
status=$?
set -e
check 'wine-only session exits non-zero' 'yes' "$([ "$status" -ne 0 ] && printf yes || printf no)"
check 'wine-only session is reported' '1' "$(grep -c 'no eden entry' "$workdir/no-eden.log")"

exec 9>"$workdir/run/game.lock"
flock -n 9
set +e
run_setup 2>"$workdir/locked.log"
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
