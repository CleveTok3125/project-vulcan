/*
 * Runtime probe for the Vulcan XInput proxy.
 *
 * Loads the xinput1_4.dll next to this executable, drives it through the
 * state file the daemon publishes, and checks the documented functions plus
 * the undocumented ordinals 100 and 108 that SDL resolves.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define STATE_PATH "C:\\vulcan-gamepad.bin"
#define RUMBLE_DIR "C:\\vulcan-data"
#define RUMBLE_PATH "C:\\vulcan-data\\vulcan-rumble.bin"
#define RUMBLE_LOCK "C:\\vulcan-data\\vulcan-rumble.lock"
#define VULCAN_GAMEPAD_MAGIC 0x56475031u
#define VULCAN_RUMBLE_MAGIC 0x5647524Du
#define VULCAN_BUTTONS_MASK 0xF3FFu

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

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint16_t left;
    uint16_t right;
    uint32_t reserved;
} vulcan_rumble_t;

_Static_assert(sizeof(vulcan_rumble_t) == 16, "unexpected rumble record size");

typedef DWORD(WINAPI *get_state_fn)(DWORD, XINPUT_STATE *);
typedef DWORD(WINAPI *set_state_fn)(DWORD, XINPUT_VIBRATION *);
typedef DWORD(WINAPI *get_capabilities_fn)(DWORD, DWORD, XINPUT_CAPABILITIES *);
typedef DWORD(WINAPI *get_capabilities_ex_fn)(DWORD, DWORD, DWORD, XINPUT_CAPABILITIES_EX *);
typedef DWORD(WINAPI *get_battery_fn)(DWORD, BYTE, XINPUT_BATTERY_INFORMATION *);
typedef DWORD(WINAPI *get_keystroke_fn)(DWORD, DWORD, XINPUT_KEYSTROKE *);
typedef void(WINAPI *enable_fn)(BOOL);

static get_state_fn p_get_state;
static get_state_fn p_get_state_ex;
static set_state_fn p_set_state;
static get_capabilities_fn p_get_capabilities;
static get_capabilities_ex_fn p_get_capabilities_ex;
static get_battery_fn p_get_battery;
static get_keystroke_fn p_get_keystroke;
static enable_fn p_enable;

static int failures;

static void check(const char *name, int ok) {
    if (ok) {
        printf("ok   %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    failures++;
}

static void write_state(uint8_t connected, uint32_t sequence) {
    vulcan_gamepad_state_t state;
    HANDLE file;
    DWORD written = 0;

    memset(&state, 0, sizeof(state));
    state.magic = VULCAN_GAMEPAD_MAGIC;
    state.sequence = sequence;
    state.buttons = 0x1401; /* A, guide, dpad up */
    state.left_trigger = 25;
    state.right_trigger = 200;
    state.thumb_lx = -1234;
    state.thumb_ly = 2345;
    state.thumb_rx = -3456;
    state.thumb_ry = 4567;
    state.connected = connected;

    file = CreateFileA(
        STATE_PATH,
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE) {
        printf("FAIL cannot create state file\n");
        failures++;
        return;
    }
    WriteFile(file, &state, sizeof(state), &written, NULL);
    CloseHandle(file);
    if (written != sizeof(state)) {
        printf("FAIL short state write\n");
        failures++;
    }
}

static void create_rumble_dir(void) {
    if (!CreateDirectoryA(RUMBLE_DIR, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
        printf("FAIL cannot create rumble directory\n");
        failures++;
    }
}

static int read_rumble(vulcan_rumble_t *record) {
    HANDLE file;
    DWORD read = 0;
    int ok;

    memset(record, 0, sizeof(*record));
    file = CreateFileA(
        RUMBLE_PATH,
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
    ok = ReadFile(file, record, sizeof(*record), &read, NULL)
        && read == (DWORD)sizeof(*record);
    CloseHandle(file);
    return ok;
}

/* GetProcAddress returns FARPROC; copy it instead of casting between
 * incompatible function pointer types. */
static int load_symbol(HMODULE module, LPCSTR name, void *target, size_t size) {
    FARPROC proc = GetProcAddress(module, name);
    if (proc == NULL) {
        return 0;
    }
    memcpy(target, &proc, size);
    return 1;
}

int main(void) {
    HMODULE module;
    XINPUT_STATE state;
    XINPUT_CAPABILITIES capabilities;
    XINPUT_CAPABILITIES_EX capabilities_ex;
    XINPUT_BATTERY_INFORMATION battery;
    XINPUT_KEYSTROKE keystroke;
    XINPUT_VIBRATION vibration;
    XINPUT_GAMEPAD neutral;
    vulcan_rumble_t rumble;
    DWORD result;
    int loaded;

    module = LoadLibraryA("xinput1_4.dll");
    if (module == NULL) {
        printf("FAIL cannot load xinput1_4.dll\n");
        return 1;
    }
    loaded = load_symbol(module, "XInputGetState", &p_get_state, sizeof(p_get_state));
    loaded &= load_symbol(module, "XInputSetState", &p_set_state, sizeof(p_set_state));
    loaded &= load_symbol(module, "XInputGetCapabilities", &p_get_capabilities,
                          sizeof(p_get_capabilities));
    loaded &= load_symbol(module, "XInputGetBatteryInformation", &p_get_battery,
                          sizeof(p_get_battery));
    loaded &= load_symbol(module, "XInputGetKeystroke", &p_get_keystroke,
                          sizeof(p_get_keystroke));
    loaded &= load_symbol(module, "XInputEnable", &p_enable, sizeof(p_enable));
    loaded &= load_symbol(module, (LPCSTR)(ULONG_PTR)108, &p_get_capabilities_ex,
                          sizeof(p_get_capabilities_ex));
    loaded &= load_symbol(module, (LPCSTR)(ULONG_PTR)100, &p_get_state_ex,
                          sizeof(p_get_state_ex));

    check("documented exports resolve", loaded != 0);
    check("ordinal 100 resolves", p_get_state_ex != NULL);
    check("ordinal 108 resolves", p_get_capabilities_ex != NULL);

    DeleteFileA(STATE_PATH);
    memset(&state, 0, sizeof(state));
    result = p_get_state(0, &state);
    check("absent state reports the virtual pad", result == ERROR_SUCCESS);
    memset(&neutral, 0, sizeof(neutral));
    check("absent state is neutral",
          memcmp(&state.Gamepad, &neutral, sizeof(neutral)) == 0);
    memset(&capabilities, 0, sizeof(capabilities));
    check("absent capabilities succeed",
          p_get_capabilities(0, 0, &capabilities) == ERROR_SUCCESS);
    check("absent extended capabilities succeed",
          p_get_capabilities_ex != NULL
              && p_get_capabilities_ex(1, 0, 0, &capabilities_ex)
                  == ERROR_SUCCESS);
    memset(&battery, 0, sizeof(battery));
    check("absent battery succeeds",
          p_get_battery(0, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_SUCCESS
              && battery.BatteryType == BATTERY_TYPE_WIRED);
    check("absent keystroke is empty",
          p_get_keystroke(0, 0, &keystroke) == ERROR_EMPTY);

    write_state(1, 7);
    memset(&state, 0, sizeof(state));
    result = p_get_state(0, &state);
    check("connected state is reported", result == ERROR_SUCCESS);
    check("packet number follows the sequence", state.dwPacketNumber == 7);
    check("documented state hides the guide bit", state.Gamepad.wButtons == 0x1001);
    check("triggers are reported",
          state.Gamepad.bLeftTrigger == 25 && state.Gamepad.bRightTrigger == 200);
    check("sticks are reported",
          state.Gamepad.sThumbLX == -1234 && state.Gamepad.sThumbLY == 2345
              && state.Gamepad.sThumbRX == -3456 && state.Gamepad.sThumbRY == 4567);

    if (p_get_state_ex != NULL) {
        memset(&state, 0, sizeof(state));
        result = p_get_state_ex(0, &state);
        check("ordinal 100 reports the guide bit",
              result == ERROR_SUCCESS && state.Gamepad.wButtons == 0x1401);
    }

    memset(&capabilities, 0, sizeof(capabilities));
    result = p_get_capabilities(0, 0, &capabilities);
    check("connected capabilities succeed", result == ERROR_SUCCESS);
    check("capabilities report a gamepad",
          capabilities.Type == XINPUT_DEVTYPE_GAMEPAD
              && capabilities.SubType == XINPUT_DEVSUBTYPE_GAMEPAD);
    check("capabilities mask skips the guide bit",
          capabilities.Gamepad.wButtons == VULCAN_BUTTONS_MASK);

    if (p_get_capabilities_ex != NULL) {
        memset(&capabilities_ex, 0, sizeof(capabilities_ex));
        result = p_get_capabilities_ex(1, 0, 0, &capabilities_ex);
        check("extended capabilities succeed", result == ERROR_SUCCESS);
        check("extended capabilities expose the pad identity",
              capabilities_ex.VendorId == 0x045E
                  && capabilities_ex.ProductId == 0x028E
                  && capabilities_ex.VersionNumber == 0x0110);
        check("extended capabilities keep the mask",
              capabilities_ex.Capabilities.Gamepad.wButtons == VULCAN_BUTTONS_MASK);
    }

    create_rumble_dir();
    DeleteFileA(RUMBLE_PATH);
    DeleteFileA(RUMBLE_LOCK);

    memset(&vibration, 0, sizeof(vibration));
    check("set state succeeds", p_set_state(0, &vibration) == ERROR_SUCCESS);
    check("first rumble record is written",
          read_rumble(&rumble) && rumble.magic == VULCAN_RUMBLE_MAGIC);
    check("first rumble record has sequence 1", rumble.sequence == 1);
    check("rumble lock is held",
          GetFileAttributesA(RUMBLE_LOCK) != INVALID_FILE_ATTRIBUTES);
    check("zero rumble is recorded", rumble.left == 0 && rumble.right == 0);

    vibration.wLeftMotorSpeed = 1234;
    vibration.wRightMotorSpeed = 5678;
    check("non-zero rumble succeeds", p_set_state(0, &vibration) == ERROR_SUCCESS);
    memset(&rumble, 0, sizeof(rumble));
    check("non-zero rumble is recorded",
          read_rumble(&rumble) && rumble.left == 1234 && rumble.right == 5678);
    check("rumble sequence advances", rumble.sequence == 2);

    check("duplicate rumble succeeds", p_set_state(0, &vibration) == ERROR_SUCCESS);
    memset(&rumble, 0, sizeof(rumble));
    check("duplicate rumble does not advance the sequence",
          read_rumble(&rumble) && rumble.sequence == 2);

    DeleteFileA(RUMBLE_PATH);
    check("missing rumble record is rewritten",
          p_set_state(0, &vibration) == ERROR_SUCCESS);
    memset(&rumble, 0, sizeof(rumble));
    check("rewritten rumble keeps the values",
          read_rumble(&rumble) && rumble.left == 1234 && rumble.right == 5678);
    check("rewritten rumble advances the sequence", rumble.sequence == 3);

    vibration.wLeftMotorSpeed = 0;
    vibration.wRightMotorSpeed = 0;
    check("stop rumble succeeds", p_set_state(0, &vibration) == ERROR_SUCCESS);
    memset(&rumble, 0, sizeof(rumble));
    check("stop rumble is recorded",
          read_rumble(&rumble) && rumble.left == 0 && rumble.right == 0);
    check("stop rumble advances the sequence", rumble.sequence == 4);

    check("null rumble is rejected", p_set_state(0, NULL) == ERROR_DEVICE_NOT_CONNECTED);
    check("another pad rumble is rejected", p_set_state(1, &vibration) == ERROR_DEVICE_NOT_CONNECTED);

    p_enable(FALSE);
    memset(&state, 0, sizeof(state));
    result = p_get_state(0, &state);
    check("disabled state is neutral",
          result == ERROR_SUCCESS && state.Gamepad.wButtons == 0
              && state.Gamepad.bLeftTrigger == 0 && state.Gamepad.sThumbLX == 0);
    p_enable(TRUE);
    memset(&state, 0, sizeof(state));
    result = p_get_state(0, &state);
    check("re-enabled state restores input",
          result == ERROR_SUCCESS && state.Gamepad.wButtons == 0x1001);

    write_state(0, 9);
    memset(&state, 0, sizeof(state));
    result = p_get_state(0, &state);
    check("disconnected state stays attached", result == ERROR_SUCCESS);
    check("disconnected state reads the new packet number",
          state.dwPacketNumber == 9);
    memset(&neutral, 0, sizeof(neutral));
    check("disconnected state is neutral",
          memcmp(&state.Gamepad, &neutral, sizeof(neutral)) == 0);
    check("disconnected capabilities succeed",
          p_get_capabilities(0, 0, &capabilities) == ERROR_SUCCESS);
    vibration.wLeftMotorSpeed = 65535;
    vibration.wRightMotorSpeed = 65535;
    check("disconnected rumble succeeds",
          p_set_state(0, &vibration) == ERROR_SUCCESS);
    memset(&rumble, 0, sizeof(rumble));
    check("disconnected rumble is recorded",
          read_rumble(&rumble) && rumble.sequence == 5
              && rumble.left == 65535 && rumble.right == 65535);

    DeleteFileA(STATE_PATH);
    DeleteFileA(RUMBLE_PATH);
    FreeLibrary(module);
    check("rumble lock is released",
          GetFileAttributesA(RUMBLE_LOCK) == INVALID_FILE_ATTRIBUTES);
    RemoveDirectoryA(RUMBLE_DIR);

    if (failures != 0) {
        printf("%d checks failed\n", failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}
