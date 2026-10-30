#!/bin/bash
# Helpers for the multi-game catalog. Sourced by the entrypoint and launcher.

if ! declare -F is_valid_game_id >/dev/null 2>&1; then
    # shellcheck source=config-lib.sh
    source "$(dirname "${BASH_SOURCE[0]}")/config-lib.sh"
fi

# is_safe_relative_path reports whether a path stays inside its base directory.
is_safe_relative_path() {
    [ -n "${1:-}" ] || return 1
    case "$1" in
        /* | *$'\n'* | *'\'*)
            return 1
            ;;
    esac
    case "/$1/" in
        *"/../"* | *"/./"*)
            return 1
            ;;
    esac
    return 0
}

# game_ids prints one game id per line.
game_ids() {
    jq -r '.games[].id' "$1"
}

# game_count prints the number of catalog entries.
game_count() {
    jq '.games | length' "$1"
}

# game_field prints one string field for a game id.
game_field() {
    local catalog="$1" id="$2" field="$3"
    jq -r --arg id "$id" --arg field "$field" \
        'first(.games[] | select(.id == $id) | .[$field] // "")' "$catalog"
}

# game_reset_paths prints the reset paths for a game id, one per line.
game_reset_paths() {
    local catalog="$1" id="$2"
    jq -r --arg id "$id" \
        '.games[] | select(.id == $id) | .reset_paths[]? // empty' "$catalog"
}

# build_app_specs prints the Apollo app specs as a JSON array.
#
# Each spec carries the catalog name, the launcher command, and a stable UUID.
# An explicit catalog uuid wins over the derived one.
build_app_specs() {
    local catalog="$1"
    local specs='[]'
    local id name uuid

    while IFS= read -r id; do
        name="$(game_field "$catalog" "$id" name)"
        uuid="$(game_field "$catalog" "$id" uuid)"
        [ -n "$uuid" ] || uuid="$(derive_app_uuid "$id")"
        specs="$(jq -c --arg name "$name" \
            --arg cmd "/usr/local/bin/launch-game.sh $id" \
            --arg uuid "$uuid" \
            '. + [{name: $name, cmd: $cmd, uuid: $uuid}]' <<<"$specs")"
    done < <(game_ids "$catalog")

    printf '%s\n' "$specs"
}

# validate_games_catalog checks the catalog shape and every entry.
#
# The catalog is mounted read-only in the container. Reject malformed entries
# before creating overlays or Apollo apps.
validate_games_catalog() {
    local catalog="${1:-}"
    local id name exe source reset uuid wine_source
    local -A seen=()

    if [ ! -r "$catalog" ]; then
        printf '[vulcan] missing game catalog: %s\n' "$catalog" >&2
        return 1
    fi

    if ! jq -e 'type == "object" and (.games | type == "array") and (.games | length > 0)' \
        "$catalog" >/dev/null 2>&1; then
        printf '[vulcan] %s: at least one game is required\n' "$catalog" >&2
        return 1
    fi

    while IFS= read -r id; do
        if ! is_valid_game_id "$id"; then
            printf '[vulcan] invalid game id: %s\n' "$id" >&2
            return 1
        fi
        if [ -n "${seen[$id]:-}" ]; then
            printf '[vulcan] duplicate game id: %s\n' "$id" >&2
            return 1
        fi
        seen[$id]=1

        name="$(game_field "$catalog" "$id" name)"
        if [ -z "$name" ]; then
            printf '[vulcan] %s: name must not be empty\n' "$id" >&2
            return 1
        fi

        exe="$(game_field "$catalog" "$id" exe)"
        if ! is_safe_relative_path "$exe"; then
            printf '[vulcan] %s: exe must be relative and stay inside the game directory\n' "$id" >&2
            return 1
        fi

        source="$(game_field "$catalog" "$id" source)"
        case "$source" in
            /*)
                ;;
            *)
                printf '[vulcan] %s: source must be absolute\n' "$id" >&2
                return 1
                ;;
        esac

        wine_source="$(game_field "$catalog" "$id" wine_source)"
        if [ -n "$wine_source" ]; then
            case "$wine_source" in
                /*)
                    ;;
                *)
                    printf '[vulcan] %s: wine_source must be absolute\n' "$id" >&2
                    return 1
                    ;;
            esac
        fi

        if ! jq -e --arg id "$id" \
            '.games[] | select(.id == $id) | ((.reset_paths // []) | type == "array")' \
            "$catalog" >/dev/null 2>&1; then
            printf '[vulcan] %s: reset_paths must be an array\n' "$id" >&2
            return 1
        fi

        while IFS= read -r reset; do
            if ! is_safe_relative_path "$reset"; then
                printf '[vulcan] %s: reset path must be relative and stay inside the game directory: %s\n' \
                    "$id" "$reset" >&2
                return 1
            fi
        done < <(game_reset_paths "$catalog" "$id")

        uuid="$(game_field "$catalog" "$id" uuid)"
        if [ -n "$uuid" ] && [[ ! "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            printf '[vulcan] %s: invalid uuid: %s\n' "$id" "$uuid" >&2
            return 1
        fi
    done < <(game_ids "$catalog")
}
