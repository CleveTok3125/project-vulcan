/*
 * Native XInput proxy for Vulcan.
 *
 * The Linux input daemon writes the current pad state to
 * C:\vulcan-gamepad.bin. This DLL exposes that state through the XInput API
 * so no kernel input device is needed on the host.
 *
 * The daemon replaces the file atomically, so every call opens it again
 * instead of caching a handle that would keep reading the previous inode.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <string.h>

#define VULCAN_GAMEPAD_MAGIC 0x56475031u

/* Documented buttons; the guide bit (0x0400) is reported only by ordinal 100. */
#define VULCAN_BUTTONS_MASK 0xF3FFu
#define VULCAN_PAD_VENDOR_ID 0x045Eu
#define VULCAN_PAD_PRODUCT_ID 0x028Eu
#define VULCAN_PAD_VERSION 0x0110u

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

/*
 * XInputGetCapabilitiesEx is undocumented but declared by mingw's xinput.h.
 * The layout matches what SDL and Wine use for ordinal 108.
 */

static volatile LONG xinput_enabled = 1;

/* Reports whether the daemon published a connected pad state. */
static int read_state(vulcan_gamepad_state_t *state) {
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
        return 0;
    }
    if (!ReadFile(file, state, sizeof(*state), &read, NULL) || read != sizeof(*state)) {
        memset(state, 0, sizeof(*state));
    }
    CloseHandle(file);
    return state->magic == VULCAN_GAMEPAD_MAGIC && state->connected != 0;
}

static void fill_capabilities(XINPUT_CAPABILITIES *capabilities) {
    memset(capabilities, 0, sizeof(*capabilities));
    capabilities->Type = XINPUT_DEVTYPE_GAMEPAD;
    capabilities->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    capabilities->Gamepad.wButtons = VULCAN_BUTTONS_MASK;
    capabilities->Gamepad.bLeftTrigger = 0xFF;
    capabilities->Gamepad.bRightTrigger = 0xFF;
    capabilities->Gamepad.sThumbLX = 0x7FFF;
    capabilities->Gamepad.sThumbLY = 0x7FFF;
    capabilities->Gamepad.sThumbRX = 0x7FFF;
    capabilities->Gamepad.sThumbRY = 0x7FFF;
}

static DWORD fill_state(DWORD index, XINPUT_STATE *state, WORD buttons_mask) {
    vulcan_gamepad_state_t raw;

    if (index != 0 || state == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    memset(state, 0, sizeof(*state));
    state->dwPacketNumber = raw.sequence;
    if (xinput_enabled != 0) {
        state->Gamepad.wButtons = raw.buttons & buttons_mask;
        state->Gamepad.bLeftTrigger = raw.left_trigger;
        state->Gamepad.bRightTrigger = raw.right_trigger;
        state->Gamepad.sThumbLX = raw.thumb_lx;
        state->Gamepad.sThumbLY = raw.thumb_ly;
        state->Gamepad.sThumbRX = raw.thumb_rx;
        state->Gamepad.sThumbRY = raw.thumb_ry;
    }
    return ERROR_SUCCESS;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state) {
    return fill_state(index, state, VULCAN_BUTTONS_MASK);
}

/* Vibration cannot reach the host pad, so the request is accepted and dropped. */
DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration) {
    vulcan_gamepad_state_t raw;

    if (index != 0 || vibration == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *capabilities) {
    vulcan_gamepad_state_t raw;

    (void)flags;
    if (index != 0 || capabilities == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    fill_capabilities(capabilities);
    return ERROR_SUCCESS;
}

/* Ordinal 108; undocumented but used by SDL for the vendor and product IDs. */
DWORD WINAPI XInputGetCapabilitiesEx(
    DWORD reserved,
    DWORD index,
    DWORD flags,
    XINPUT_CAPABILITIES_EX *capabilities
) {
    vulcan_gamepad_state_t raw;

    (void)reserved;
    (void)flags;
    if (index != 0 || capabilities == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    memset(capabilities, 0, sizeof(*capabilities));
    fill_capabilities(&capabilities->Capabilities);
    capabilities->VendorId = VULCAN_PAD_VENDOR_ID;
    capabilities->ProductId = VULCAN_PAD_PRODUCT_ID;
    capabilities->VersionNumber = VULCAN_PAD_VERSION;
    return ERROR_SUCCESS;
}

void WINAPI XInputEnable(BOOL enable) {
    InterlockedExchange(&xinput_enabled, enable ? 1 : 0);
}

DWORD WINAPI XInputGetBatteryInformation(
    DWORD index,
    BYTE device_type,
    XINPUT_BATTERY_INFORMATION *battery
) {
    vulcan_gamepad_state_t raw;

    (void)device_type;
    if (index != 0 || battery == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    memset(battery, 0, sizeof(*battery));
    battery->BatteryType = BATTERY_TYPE_WIRED;
    battery->BatteryLevel = BATTERY_LEVEL_FULL;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD flags, XINPUT_KEYSTROKE *keystroke) {
    vulcan_gamepad_state_t raw;

    (void)flags;
    if (index != 0) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (!read_state(&raw)) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    if (keystroke != NULL) {
        memset(keystroke, 0, sizeof(*keystroke));
    }
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

/* Ordinal 100, used by games and SDL that want the guide button state. */
DWORD WINAPI XInputGetStateEx(DWORD index, XINPUT_STATE *state) {
    return fill_state(index, state, 0xFFFF);
}
