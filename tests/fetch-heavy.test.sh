#!/bin/bash
# Verifies the heavy package prefetch puts packages in the pacman cache.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/docker/fetch-heavy"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$workdir/bin" "$workdir/cache"
calls="$workdir/calls"
failures=0

cat >"$workdir/bin/pacman" <<'EOF'
#!/bin/sh
for last; do :; done
case "$last" in
    cuda) printf 'cuda https://example.test/cuda-13.0.2-1-x86_64.pkg.tar.zst\n' ;;
    mingw-w64-gcc) printf 'mingw-w64-gcc https://example.test/mingw-w64-gcc-14.2.0-1-x86_64.pkg.tar.zst\n' ;;
    fail) printf 'fail https://example.test/fail-1-x86_64.pkg.tar.zst\n' ;;
esac
EOF

cat >"$workdir/bin/aria2c" <<'EOF'
#!/bin/sh
dir=.
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) dir=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s/%s\n' "$dir" "$out" >>"$CALL_LOG"
[ "${FAIL_ARIA2:-0}" = "1" ] && exit 1
: >"$dir/$out"
EOF

chmod +x "$workdir/bin/pacman" "$workdir/bin/aria2c"

run_prefetch() {
    PATH="$workdir/bin:$PATH" PACMAN_CACHE="$workdir/cache" CALL_LOG="$calls" \
        FAIL_ARIA2="${FAIL_ARIA2:-0}" sh "$script" "$@"
}

check_file() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing %s\n' "$label" "$path" >&2
        failures=$((failures + 1))
    fi
}

: >"$calls"
run_prefetch cuda
check_file "cuda is cached" "$workdir/cache/cuda-13.0.2-1-x86_64.pkg.tar.zst"
if grep -Fq 'cuda-13.0.2-1-x86_64.pkg.tar.zst.part' "$calls"; then
    printf 'ok   aria2 downloads to a part file\n'
else
    printf 'FAIL aria2 did not use the part file: [%s]\n' "$(cat "$calls")" >&2
    failures=$((failures + 1))
fi

before="$(wc -l <"$calls")"
run_prefetch cuda
after="$(wc -l <"$calls")"
if [ "$before" = "$after" ]; then
    printf 'ok   a cached package is not downloaded again\n'
else
    printf 'FAIL a cached package was downloaded again\n' >&2
    failures=$((failures + 1))
fi

run_prefetch mingw-w64-gcc
check_file "mingw-w64-gcc is cached" \
    "$workdir/cache/mingw-w64-gcc-14.2.0-1-x86_64.pkg.tar.zst"

FAIL_ARIA2=1 run_prefetch fail
if [ -e "$workdir/cache/fail-1-x86_64.pkg.tar.zst" ]; then
    printf 'FAIL a failed download left a complete package\n' >&2
    failures=$((failures + 1))
else
    printf 'ok   a failed download leaves no package\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
