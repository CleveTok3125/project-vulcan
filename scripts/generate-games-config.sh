#!/bin/bash
# Converts games.yaml into the container catalog and Compose mount override.
set -Eeuo pipefail

usage() {
    printf 'usage: %s <games.yaml> <output-dir>\n' "$(basename "$0")" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
catalog="$1"
outdir="$2"
YQ="${YQ:-yq}"

if ! command -v "$YQ" >/dev/null 2>&1; then
    printf '[vulcan] missing yq: install go-yq or set YQ\n' >&2
    exit 1
fi

# shellcheck source=game-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/game-lib.sh"

install -d -m 0755 "$outdir"
json_tmp="$outdir/.games.json.$$"
compose_tmp="$outdir/.compose.games.yaml.$$"
trap 'rm -f "$json_tmp" "$json_tmp.pretty" "$compose_tmp"' EXIT

if ! "$YQ" -o=json '.' "$catalog" >"$json_tmp"; then
    printf '[vulcan] failed to parse game catalog: %s\n' "$catalog" >&2
    exit 1
fi
jq . "$json_tmp" >"$json_tmp.pretty"
mv "$json_tmp.pretty" "$json_tmp"
validate_games_catalog "$json_tmp" || exit 1

while IFS= read -r id; do
    source="$(game_field "$json_tmp" "$id" source)"
    runner="$(game_runner "$json_tmp" "$id")"
    wine_source="$(game_field "$json_tmp" "$id" wine_source)"
    source="${source%/}"
    if [ ! -d "$source" ]; then
        printf '[vulcan] %s: game directory not found: %s\n' "$id" "$source" >&2
        exit 1
    fi
    if [ "$runner" = "eden" ]; then
        rom="$(game_field "$json_tmp" "$id" rom)"
        if [ ! -e "$source/$rom" ]; then
            printf '[vulcan] %s: game rom not found: %s/%s\n' "$id" "$source" "$rom" >&2
            exit 1
        fi
    else
        exe="$(game_field "$json_tmp" "$id" exe)"
        if [ ! -f "$source/$exe" ]; then
            printf '[vulcan] %s: game executable not found: %s/%s\n' "$id" "$source" "$exe" >&2
            exit 1
        fi
    fi
    if [ -n "$wine_source" ]; then
        wine_source="${wine_source%/}"
        if [ ! -d "$wine_source" ]; then
            printf '[vulcan] %s: wine directory not found: %s\n' "$id" "$wine_source" >&2
            exit 1
        fi
    fi
done < <(game_ids "$json_tmp")

eden_content="$(catalog_eden_content "$json_tmp")"
if [ -n "$eden_content" ]; then
    eden_content="${eden_content%/}"
    if [ ! -d "$eden_content" ]; then
        printf '[vulcan] eden_content directory not found: %s\n' "$eden_content" >&2
        exit 1
    fi
fi

{
    printf 'services:\n'
    printf '  game:\n'
    printf '    volumes:\n'
    jq -r '.games[] | ("\(.source):/games-ro/\(.id):ro") | "      - \(@json)"' "$json_tmp"
    jq -r '.games[] | select(.wine_source != null and .wine_source != "")
        | ("\(.wine_source):/wine/\(.id):ro") | "      - \(@json)"' "$json_tmp"
    if [ -n "$eden_content" ]; then
        jq -rn --arg mount "${eden_content}:/eden-content:ro" '"      - \($mount|@json)"'
    fi
} >"$compose_tmp"

mv "$json_tmp" "$outdir/games.json"
mv "$compose_tmp" "$outdir/compose.games.yaml"
