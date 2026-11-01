/*
 * Native XInput proxy for Vulcan.
 *
 * The Linux input daemon writes the current pad state to
 * C:\vulcan-gamepad.bin. This DLL exposes that state through the XInput API
 * so no kernel input device is needed on the host.
 *
 * The daemon replaces the file atomically, so every call opens it again
 * instead of caching a handle that would keep reading the previous inode.
 *
 * XInputSetState writes the motor speeds to C:\vulcan-data\vulcan-rumble.bin.
 * The session reads that file and forwards it to the streaming client.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define VULCAN_GAMEPAD_MAGIC 0x56475031u
#define VULCAN_RUMBLE_MAGIC 0x5647524Du
#define VULCAN_RUMBLE_PATH "C:\\vulcan-data\\vulcan-rumble.bin"
#define VULCAN_RUMBLE_TMP "C:\\vulcan-data\\vulcan-rumble.%lu.tmp"
#define VULCAN_RUMBLE_LOCK "C:\\vulcan-data\\vulcan-rumble.lock"

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

/* Layout is mirrored by Apollo's rumble reader. */
typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint16_t left;
    uint16_t right;
    uint32_t reserved;
} vulcan_rumble_t;

_Static_assert(sizeof(vulcan_rumble_t) == 16, "unexpected rumble record size");

/*
 * XInputGetCapabilitiesEx is undocumented but declared by mingw's xinput.h.
 * The layout matches what SDL and Wine use for ordinal 108.
 */

static volatile LONG xinput_enabled = 1;
static CRITICAL_SECTION rumble_lock;
static uint32_t rumble_sequence = 0;
static uint16_t rumble_left = 0;
static uint16_t rumble_right = 0;
static int rumble_initialized = 0;
static HANDLE rumble_guard = INVALID_HANDLE_VALUE;

/* Reads the daemon state. Reports whether the file holds a valid record; a
 * valid record with connected == 0 means the client pad has no data yet. */
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
    return state->magic == VULCAN_GAMEPAD_MAGIC;
}

/*
 * Holds a delete-on-close file for the life of the process. Apollo treats the
 * file as the game's liveness marker, so a crash stops rumble too.
 */
static int open_rumble_guard(void) {
    if (rumble_guard != INVALID_HANDLE_VALUE) {
        return 1;
    }
    rumble_guard = CreateFileA(
        VULCAN_RUMBLE_LOCK,
        GENERIC_WRITE | DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE,
        NULL
    );
    return rumble_guard != INVALID_HANDLE_VALUE;
}

/* Writes one complete record; the reader only ever sees a full file. */
static int write_rumble(uint16_t left, uint16_t right) {
    vulcan_rumble_t record;
    char tmp[sizeof(VULCAN_RUMBLE_TMP) + 16];
    HANDLE file;
    DWORD written = 0;
    int ok = 0;

    if (rumble_initialized && left == rumble_left && right == rumble_right
        && GetFileAttributesA(VULCAN_RUMBLE_PATH) != INVALID_FILE_ATTRIBUTES) {
        return open_rumble_guard();
    }

    record.magic = VULCAN_RUMBLE_MAGIC;
    record.sequence = rumble_sequence + 1;
    record.left = left;
    record.right = right;
    record.reserved = 0;

    snprintf(tmp, sizeof(tmp), VULCAN_RUMBLE_TMP, (unsigned long)GetCurrentProcessId());
    file = CreateFileA(
        tmp,
        GENERIC_WRITE,
        0,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }
    if (WriteFile(file, &record, sizeof(record), &written, NULL)
        && written == (DWORD)sizeof(record)) {
        ok = 1;
    }
    CloseHandle(file);
    if (!ok) {
        DeleteFileA(tmp);
        return 0;
    }
    if (!MoveFileExA(tmp, VULCAN_RUMBLE_PATH, MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileA(tmp);
        return 0;
    }

    rumble_left = left;
    rumble_right = right;
    rumble_sequence = record.sequence;
    rumble_initialized = 1;
    return open_rumble_guard();
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
    memset(state, 0, sizeof(*state));
    /* The virtual pad stays attached for the whole session. Games that
     * enumerate XInput once at startup must see it before the client
     * publishes the first pad report. */
    if (!read_state(&raw)) {
        return ERROR_SUCCESS;
    }
    state->dwPacketNumber = raw.sequence;
    if (raw.connected == 0 || xinput_enabled == 0) {
        return ERROR_SUCCESS;
    }
    state->Gamepad.wButtons = raw.buttons & buttons_mask;
    state->Gamepad.bLeftTrigger = raw.left_trigger;
    state->Gamepad.bRightTrigger = raw.right_trigger;
    state->Gamepad.sThumbLX = raw.thumb_lx;
    state->Gamepad.sThumbLY = raw.thumb_ly;
    state->Gamepad.sThumbRX = raw.thumb_rx;
    state->Gamepad.sThumbRY = raw.thumb_ry;
    return ERROR_SUCCESS;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        InitializeCriticalSection(&rumble_lock);
    } else if (reason == DLL_PROCESS_DETACH && rumble_guard != INVALID_HANDLE_VALUE) {
        CloseHandle(rumble_guard);
        rumble_guard = INVALID_HANDLE_VALUE;
    }
    return TRUE;
}

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state) {
    return fill_state(index, state, VULCAN_BUTTONS_MASK);
}

/* Vibration is recorded for the session to forward to the streaming client. */
DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration) {
    if (index != 0 || vibration == NULL) {
        return ERROR_DEVICE_NOT_CONNECTED;
    }

    EnterCriticalSection(&rumble_lock);
    (void)write_rumble(vibration->wLeftMotorSpeed, vibration->wRightMotorSpeed);
    LeaveCriticalSection(&rumble_lock);
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *capabilities) {
    (void)flags;
    if (index != 0 || capabilities == NULL) {
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
    (void)reserved;
    (void)flags;
    if (index != 0 || capabilities == NULL) {
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
    (void)flags;
    if (index != 0) {
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
