/*
 * Native XInput proxy for Vulcan.
 *
 * The Linux input daemon writes the current pad state to
 * C:\vulcan-gamepad.bin. This DLL exposes that state through the XInput API
 * so no kernel input device is needed on the host.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <string.h>

#define VULCAN_GAMEPAD_MAGIC 0x56475031u

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint16_t buttons;
    uint8_t left_trigger;
    uint8_t right_trigger;
    int16_t thumb_lx;
    int16_t thumb_ly;
    int16_t thumb_rx;
    int16_t thumb_ry;
    uint8_t connected;
    uint8_t padding[7];
} vulcan_gamepad_state_t;

static void read_state(vulcan_gamepad_state_t *state) {
    HANDLE file;
    DWORD read = 0;

    memset(state, 0, sizeof(*state));
    file = CreateFileA(
        "C:\\vulcan-gamepad.bin",
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    if (!ReadFile(file, state, sizeof(*state), &read, NULL) || read != sizeof(*state)) {
        memset(state, 0, sizeof(*state));
    }
    CloseHandle(file);
    if (state->magic != VULCAN_GAMEPAD_MAGIC) {
        memset(state, 0, sizeof(*state));
    }
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state) {
    vulcan_gamepad_state_t raw;

    if (index != 0 || state == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    read_state(&raw);
    if (!raw.connected) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    memset(state, 0, sizeof(*state));
    state->dwPacketNumber = raw.sequence;
    state->Gamepad.wButtons = raw.buttons;
    state->Gamepad.bLeftTrigger = raw.left_trigger;
    state->Gamepad.bRightTrigger = raw.right_trigger;
    state->Gamepad.sThumbLX = raw.thumb_lx;
    state->Gamepad.sThumbLY = raw.thumb_ly;
    state->Gamepad.sThumbRX = raw.thumb_rx;
    state->Gamepad.sThumbRY = raw.thumb_ry;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration) {
    (void)index;
    (void)vibration;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *capabilities) {
    (void)flags;
    if (index != 0 || capabilities == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    memset(capabilities, 0, sizeof(*capabilities));
    capabilities->Type = XINPUT_DEVTYPE_GAMEPAD;
    capabilities->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    capabilities->Gamepad.wButtons = 0xF3FF;
    capabilities->Gamepad.bLeftTrigger = 0xFF;
    capabilities->Gamepad.bRightTrigger = 0xFF;
    capabilities->Gamepad.sThumbLX = 0x7FFF;
    capabilities->Gamepad.sThumbLY = 0x7FFF;
    capabilities->Gamepad.sThumbRX = 0x7FFF;
    capabilities->Gamepad.sThumbRY = 0x7FFF;
    return ERROR_SUCCESS;
}

void WINAPI XInputEnable(BOOL enable) {
    (void)enable;
}

DWORD WINAPI XInputGetBatteryInformation(
    DWORD index,
    BYTE device_type,
    XINPUT_BATTERY_INFORMATION *battery
) {
    (void)device_type;
    if (index != 0 || battery == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    memset(battery, 0, sizeof(*battery));
    battery->BatteryType = BATTERY_TYPE_WIRED;
    battery->BatteryLevel = BATTERY_LEVEL_FULL;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD flags, XINPUT_KEYSTROKE *keystroke) {
    (void)index;
    (void)flags;
    (void)keystroke;
    return ERROR_EMPTY;
}

DWORD WINAPI XInputGetAudioDeviceIds(
    DWORD index,
    LPWSTR render_device_id,
    UINT *render_count,
    LPWSTR capture_device_id,
    UINT *capture_count
) {
    (void)index;
    (void)render_device_id;
    (void)render_count;
    (void)capture_device_id;
    (void)capture_count;
    return ERROR_NOT_SUPPORTED;
}

/* Ordinal 100, used by games that want the guide button state. */
DWORD WINAPI XInputGetStateEx(DWORD index, XINPUT_STATE *state) {
    return XInputGetState(index, state);
}
