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

# game_runner prints the launcher kind for a game id.
#
# An entry without a runner is a Wine game, which keeps catalogs written before
# the native runner existed valid.
game_runner() {
    local catalog="$1" id="$2" runner
    runner="$(game_field "$catalog" "$id" runner)"
    printf '%s\n' "${runner:-wine}"
}

# catalog_eden_content prints the shared update/DLC directory, empty when unset.
catalog_eden_content() {
    jq -r '.eden_content // ""' "$1"
}

# catalog_has_eden_runner reports whether any entry uses the Eden runner.
catalog_has_eden_runner() {
    local catalog="$1" id
    while IFS= read -r id; do
        if [ "$(game_runner "$catalog" "$id")" = "eden" ]; then
            return 0
        fi
    done < <(game_ids "$catalog")
    return 1
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

    # The setup app opens the emulator without a game so updates, DLC, and the
    # DSU controller mapping can be prepared once per session volume.
    if catalog_has_eden_runner "$catalog"; then
        uuid="$(derive_app_uuid eden-setup)"
        specs="$(jq -c --arg name 'Eden Setup' \
            --arg cmd '/usr/local/bin/eden-setup.sh' \
            --arg uuid "$uuid" \
            '. + [{name: $name, cmd: $cmd, uuid: $uuid}]' <<<"$specs")"
    fi

    printf '%s\n' "$specs"
}

# validate_games_catalog checks the catalog shape and every entry.
#
# The catalog is mounted read-only in the container. Reject malformed entries
# before creating overlays or Apollo apps.
validate_games_catalog() {
    local catalog="${1:-}"
    local id name exe source reset uuid wine_source runner rom eden_content
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

        runner="$(game_runner "$catalog" "$id")"
        case "$runner" in
            wine)
                exe="$(game_field "$catalog" "$id" exe)"
                if ! is_safe_relative_path "$exe"; then
                    printf '[vulcan] %s: exe must be relative and stay inside the game directory\n' "$id" >&2
                    return 1
                fi
                if [ -n "$(game_field "$catalog" "$id" rom)" ]; then
                    printf '[vulcan] %s: wine entries must not set rom\n' "$id" >&2
                    return 1
                fi
                ;;
            eden)
                rom="$(game_field "$catalog" "$id" rom)"
                if ! is_safe_relative_path "$rom"; then
                    printf '[vulcan] %s: rom must be relative and stay inside the game directory\n' "$id" >&2
                    return 1
                fi
                if [ -n "$(game_field "$catalog" "$id" exe)" ]; then
                    printf '[vulcan] %s: eden entries must not set exe\n' "$id" >&2
                    return 1
                fi
                ;;
            *)
                printf '[vulcan] %s: unsupported runner: %s\n' "$id" "$runner" >&2
                return 1
                ;;
        esac

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
            if [ "$runner" = "eden" ]; then
                printf '[vulcan] %s: eden entries must not set wine_source\n' "$id" >&2
                return 1
            fi
        fi

        if ! jq -e --arg id "$id" \
            '.games[] | select(.id == $id) | ((.reset_paths // []) | type == "array")' \
            "$catalog" >/dev/null 2>&1; then
            printf '[vulcan] %s: reset_paths must be an array\n' "$id" >&2
            return 1
        fi

        if [ "$runner" = "eden" ] \
            && jq -e --arg id "$id" '.games[] | select(.id == $id) | (.reset_paths // []) | length > 0' \
                "$catalog" >/dev/null 2>&1; then
            printf '[vulcan] %s: eden entries must not set reset_paths\n' "$id" >&2
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

    eden_content="$(catalog_eden_content "$catalog")"
    if [ -n "$eden_content" ]; then
        case "$eden_content" in
            /*)
                ;;
            *)
                printf '[vulcan] eden_content must be absolute\n' >&2
                return 1
                ;;
        esac
    fi
}
