#!/bin/bash
# Verifies the DirectInput proxy is built, installed, and kept off the kernel
# input path.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

check_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: missing [%s] in %s\n' "$label" "$needle" "$file" >&2
        failures=$((failures + 1))
    fi
}

check_missing() {
    local label="$1" needle="$2" file="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf 'FAIL %s: unexpected [%s] in %s\n' "$label" "$needle" "$file" >&2
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$label"
    fi
}

native="$repo_root/native/dinput8.cpp"
def="$repo_root/native/dinput8.def"
probe="$repo_root/native/dinput_probe.cpp"
dockerfile="$repo_root/Dockerfile"
launcher="$repo_root/scripts/launch-game.sh"
compose="$repo_root/compose.yaml"
preset="$repo_root/.env.multi.example"
readme="$repo_root/README.md"

check_contains "proxy exports DirectInput8Create" 'DirectInput8Create' "$native"
check_contains "proxy enumerates devices" 'EnumDevices' "$native"
check_contains "proxy reads the pad state" 'kGamepadPath' "$native"
check_contains "proxy writes rumble" 'kRumblePath' "$native"
check_contains "proxy supports constant force" 'GUID_ConstantForce' "$native"
check_contains "proxy supports periodic force" 'DIEFT_PERIODIC' "$native"
check_contains "proxy forwards to the Wine builtin" 'dinput8_real.dll' "$native"
check_contains "proxy is an ANSI wrapper" 'DirectInput8A' "$native"

check_contains "exports DirectInput8Create" 'DirectInput8Create' "$def"
check_contains "exports DllGetClassObject" 'DllGetClassObject' "$def"
check_contains "probe checks the virtual joystick" 'FindDevice' "$probe"
check_contains "probe checks rumble" 'rumble is recorded' "$probe"

check_contains "image builds the proxy" '/out/x86_64/dinput8.dll' "$dockerfile"
check_contains "image builds the 32-bit proxy" '/out/i686/dinput8.dll' "$dockerfile"
check_contains "image installs the proxy" '/usr/lib/vulcan/dinput8.dll' "$dockerfile"
check_contains "image installs the 32-bit proxy" '/usr/lib/vulcan/dinput8_32.dll' "$dockerfile"
check_contains "runtime test stage exists" 'AS dinput-test' "$dockerfile"

check_contains "launcher defaults the proxy on" 'DINPUT_PROXY="${DINPUT_PROXY:-1}"' "$launcher"
check_contains "launcher preserves the Wine builtin" 'dinput8_real.dll' "$launcher"
check_contains "launcher overrides dinput8" 'dinput8=n,b' "$launcher"
check_contains "launcher installs the 32-bit proxy" 'syswow64/dinput8.dll' "$launcher"
check_contains "compose passes DINPUT_PROXY" 'DINPUT_PROXY:' "$compose"
check_contains "preset documents DINPUT_PROXY" 'DINPUT_PROXY=1' "$preset"
check_contains "readme documents DINPUT_PROXY" 'DINPUT_PROXY=0' "$readme"

check_missing "compose has no uinput device" '/dev/uinput' "$compose"
check_missing "compose has no uhid device" '/dev/uhid' "$compose"

if [ "$failures" -ne 0 ]; then
    printf '%d checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
