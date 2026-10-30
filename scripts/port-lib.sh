# Apollo port helpers shared by check-ports.sh and show-ports.sh.

# Prints "<protocol> <port>" for every listener derived from a base port.
apollo_ports() {
    local base="$1"
    printf 'tcp %d\n' "$((base - 5))" "$base" "$((base + 1))" "$((base + 21))"
    printf 'udp %d\n' "$((base + 9))" "$((base + 10))" "$((base + 11))" "$((base + 13))"
}

# Reads APOLLO_PORT from a preset; the container defaults to 47989.
read_apollo_port() {
    local preset="$1" value
    value="$(sed -n 's/^[[:space:]]*APOLLO_PORT[[:space:]]*=[[:space:]]*//p' "$preset" | tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "${value:-47989}"
}

# Reports whether the value is a base port Apollo accepts.
apollo_port_is_valid() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1029 && value <= 65514))
}
