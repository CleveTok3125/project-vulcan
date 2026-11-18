#!/bin/bash
# Verifies that build patches live under docker/patches, are referenced by the
# Dockerfile, and appear in the patch index.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
    printf 'FAIL %s\n' "$*" >&2
    failures=$((failures + 1))
}

patches=()
while IFS= read -r patch; do
    patches+=("$patch")
done < <(cd "$repo_root" && git ls-files '*.patch')

if [ "${#patches[@]}" -eq 0 ]; then
    fail 'no build patches found'
fi

for patch in "${patches[@]}"; do
    case "$patch" in
        docker/patches/*.patch) ;;
        *) fail "patch outside docker/patches: $patch" ;;
    esac

    if ! grep -Fq -- "$patch" "$repo_root/Dockerfile"; then
        fail "Dockerfile does not reference $patch"
    fi

    name="${patch##*/}"
    if ! grep -Fq -- "$name" "$repo_root/docker/patches/README.md"; then
        fail "patch index does not mention $name"
    fi
done

if [ ! -f "$repo_root/docker/patches/README.md" ]; then
    fail 'missing docker/patches/README.md'
fi

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'all checks passed\n'
