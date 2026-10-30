#!/bin/bash
# Verifies that only the listed heavy packages download through aria2.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/docker/pacman-aria2"
list="$repo_root/docker/aria2-heavy-packages"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$workdir/bin"
for tool in curl aria2c; do
    cat >"$workdir/bin/$tool" <<'EOF'
#!/bin/sh
basename "$0" >>"$CALL_LOG"
exit 0
EOF
    chmod +x "$workdir/bin/$tool"
done

calls="$workdir/calls"
failures=0

choose() {
    local label="$1" expected="$2" path="$3" list_path="${4:-$list}"
    : >"$calls"
    PATH="$workdir/bin:$PATH" CALL_LOG="$calls" ARIA2_HEAVY_PACKAGES="$list_path" \
        sh "$wrapper" "https://example.invalid/package" "$path"
    actual="$(head -n 1 "$calls" 2>/dev/null || true)"
    if [ "$actual" = "$expected" ]; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: expected %s, got [%s]\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

choose "cuda uses aria2" aria2c \
    /var/cache/pacman/pkg/cuda-13.0.2-1-x86_64.pkg.tar.zst
choose "a partial cuda download keeps aria2" aria2c \
    /var/cache/pacman/pkg/cuda-13.0.2-1-x86_64.pkg.tar.zst.part
choose "nvidia-utils uses aria2" aria2c \
    /var/cache/pacman/pkg/nvidia-utils-580.95-1-x86_64.pkg.tar.zst
choose "mingw-w64-gcc uses aria2" aria2c \
    /var/cache/pacman/pkg/mingw-w64-gcc-14.2.0-1-x86_64.pkg.tar.zst
choose "rust uses curl" curl \
    /var/cache/pacman/pkg/rust-1.90.0-1-x86_64.pkg.tar.zst
choose "a database uses curl" curl \
    /var/lib/pacman/sync/core.db
choose "a package signature uses curl" curl \
    /var/cache/pacman/pkg/cuda-13.0.2-1-x86_64.pkg.tar.zst.sig
choose "a missing list falls back to curl" curl \
    /var/cache/pacman/pkg/cuda-13.0.2-1-x86_64.pkg.tar.zst "$workdir/absent"

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
