/*
 * Runtime probe for the Vulcan DirectInput8 proxy.
 *
 * The probe creates the virtual joystick, reads the state file, and verifies
 * that a constant-force effect writes and clears the rumble record.
 */
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define STATE_PATH "C:\\vulcan-gamepad.bin"
#define RUMBLE_DIR "C:\\vulcan-data"
#define RUMBLE_PATH "C:\\vulcan-data\\vulcan-rumble.bin"
#define GAMEPAD_MAGIC 0x56475031u
#define RUMBLE_MAGIC 0x5647524Du

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
} gamepad_state_t;

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint16_t left;
    uint16_t right;
    uint32_t reserved;
} rumble_t;

typedef HRESULT(WINAPI *direct_input_create_fn)(
    HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);

static int failures;

static void check(const char *name, int ok) {
    if (ok) {
        printf("ok   %s\n", name);
    } else {
        printf("FAIL %s\n", name);
        failures++;
    }
}

static int write_state(void) {
    gamepad_state_t state;
    HANDLE file;
    DWORD written = 0;

    memset(&state, 0, sizeof(state));
    state.magic = GAMEPAD_MAGIC;
    state.sequence = 11;
    state.buttons = 0x1001u;
    state.left_trigger = 25;
    state.right_trigger = 200;
    state.thumb_lx = -1234;
    state.thumb_ly = 2345;
    state.thumb_rx = -3456;
    state.thumb_ry = 4567;
    state.connected = 1;

    file = CreateFileA(STATE_PATH, GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }
    WriteFile(file, &state, sizeof(state), &written, NULL);
    CloseHandle(file);
    return written == sizeof(state);
}

static int read_rumble(rumble_t *record) {
    HANDLE file;
    DWORD read = 0;
    int ok;

    memset(record, 0, sizeof(*record));
    file = CreateFileA(RUMBLE_PATH, GENERIC_READ,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }
    ok = ReadFile(file, record, sizeof(*record), &read, NULL)
        && read == sizeof(*record);
    CloseHandle(file);
    return ok;
}

static BOOL CALLBACK enum_device(
    LPCDIDEVICEINSTANCEW instance,
    LPVOID context
) {
    (void)instance;
    (void)context;
    return DIENUM_CONTINUE;
}

static int run_probe(direct_input_create_fn create) {
    IDirectInput8W *direct_input = NULL;
    IDirectInputDevice8W *device = NULL;
    IDirectInputEffect *effect = NULL;
    DIDEVICEINSTANCEW instance;
    DICONSTANTFORCE constant;
    DIEFFECT effect_params;
    DWORD axes[1];
    LONG direction[1];
    DIJOYSTATE2 state;
    rumble_t rumble;
    HRESULT result;

    check("state file written", write_state() != 0);
    check("rumble directory exists",
          CreateDirectoryA(RUMBLE_DIR, NULL) != 0
              || GetLastError() == ERROR_ALREADY_EXISTS);

    result = create(GetModuleHandleA(NULL), DIRECTINPUT_VERSION,
                    IID_IDirectInput8W, (LPVOID *)&direct_input, NULL);
    check("DirectInput8Create succeeds", SUCCEEDED(result) && direct_input != NULL);
    if (direct_input == NULL) {
        return failures;
    }

    result = direct_input->EnumDevices(
        DI8DEVCLASS_GAMECTRL, enum_device, NULL, DIEDFL_ATTACHEDONLY);
    check("EnumDevices succeeds", SUCCEEDED(result));

    memset(&instance, 0, sizeof(instance));
    instance.dwSize = sizeof(instance);
    result = direct_input->FindDevice(
        GUID_Joystick, L"Controller (XBOX 360 For Windows)", &instance.guidInstance);
    check("virtual device is found", SUCCEEDED(result));
    if (FAILED(result)) {
        direct_input->Release();
        return failures;
    }

    result = direct_input->CreateDevice(
        instance.guidInstance, &device, NULL);
    check("virtual device is created", SUCCEEDED(result) && device != NULL);
    if (device == NULL) {
        direct_input->Release();
        return failures;
    }

    result = device->SetDataFormat(&c_dfDIJoystick2);
    check("DIJOYSTATE2 format is accepted", SUCCEEDED(result));
    result = device->SetCooperativeLevel(
        NULL, DISCL_BACKGROUND | DISCL_NONEXCLUSIVE);
    check("cooperative level is accepted", SUCCEEDED(result));
    result = device->Acquire();
    check("device acquires", SUCCEEDED(result));

    memset(&state, 0, sizeof(state));
    result = device->GetDeviceState(sizeof(state), &state);
    check("GetDeviceState succeeds", SUCCEEDED(result));
    check("A button is reported", (state.rgbButtons[0] & 0x80u) != 0);
    check("left stick is reported", state.lX == -1234 && state.lY == -2345);
    check("triggers are reported", state.lZ == 25 * 257 && state.lRz == 200 * 257);
    check("dpad up is reported", state.rgdwPOV[0] == 0);

    memset(&constant, 0, sizeof(constant));
    constant.lMagnitude = 8000;
    memset(&effect_params, 0, sizeof(effect_params));
    effect_params.dwSize = sizeof(effect_params);
    effect_params.dwFlags = DIEFF_CARTESIAN | DIEFF_OBJECTOFFSETS;
    effect_params.dwDuration = 250000;
    effect_params.dwGain = 10000;
    effect_params.cAxes = 1;
    effect_params.rgdwAxes = axes;
    effect_params.rglDirection = direction;
    effect_params.cbTypeSpecificParams = sizeof(constant);
    effect_params.lpvTypeSpecificParams = &constant;
    axes[0] = DIJOFS_X;
    direction[0] = 0;

    result = device->CreateEffect(
        GUID_ConstantForce, &effect_params, &effect, NULL);
    check("constant effect is created", SUCCEEDED(result) && effect != NULL);
    if (effect != NULL) {
        result = effect->Start(0, 0);
        check("effect starts", SUCCEEDED(result));
        Sleep(80);
        memset(&rumble, 0, sizeof(rumble));
        check("rumble is recorded",
              read_rumble(&rumble) && rumble.magic == RUMBLE_MAGIC
                  && (rumble.left != 0 || rumble.right != 0));
        result = effect->Stop();
        check("effect stops", SUCCEEDED(result));
        Sleep(80);
        memset(&rumble, 0, sizeof(rumble));
        check("rumble is cleared",
              read_rumble(&rumble) && rumble.left == 0 && rumble.right == 0);
        effect->Release();
    }

    device->Unacquire();
    device->Release();
    direct_input->Release();
    return failures;
}

static int run_probe_ansi(direct_input_create_fn create) {
    IDirectInput8A *direct_input = NULL;
    IDirectInputDevice8A *device = NULL;
    DIDEVICEINSTANCEA instance;
    DIJOYSTATE2 state;
    HRESULT result;

    result = create(GetModuleHandleA(NULL), DIRECTINPUT_VERSION,
                    IID_IDirectInput8A, (LPVOID *)&direct_input, NULL);
    check("ANSI DirectInput8Create succeeds",
          SUCCEEDED(result) && direct_input != NULL);
    if (direct_input == NULL) {
        return failures;
    }

    memset(&instance, 0, sizeof(instance));
    instance.dwSize = sizeof(instance);
    result = direct_input->FindDevice(
        GUID_Joystick, "Controller (XBOX 360 For Windows)",
        &instance.guidInstance);
    check("ANSI virtual device is found", SUCCEEDED(result));
    if (FAILED(result)) {
        direct_input->Release();
        return failures;
    }

    result = direct_input->CreateDevice(
        instance.guidInstance, &device, NULL);
    check("ANSI virtual device is created", SUCCEEDED(result) && device != NULL);
    if (device == NULL) {
        direct_input->Release();
        return failures;
    }

    result = device->SetDataFormat(&c_dfDIJoystick2);
    check("ANSI DIJOYSTATE2 format is accepted", SUCCEEDED(result));
    result = device->Acquire();
    check("ANSI device acquires", SUCCEEDED(result));
    memset(&state, 0, sizeof(state));
    result = device->GetDeviceState(sizeof(state), &state);
    check("ANSI GetDeviceState succeeds", SUCCEEDED(result));
    check("ANSI A button is reported", (state.rgbButtons[0] & 0x80u) != 0);
    check("ANSI left stick is reported", state.lX == -1234 && state.lY == -2345);

    device->Release();
    direct_input->Release();
    return failures;
}

int main(void) {
    HMODULE module;
    direct_input_create_fn create = NULL;
    FARPROC proc;

    module = LoadLibraryA("dinput8.dll");
    if (module == NULL) {
        printf("FAIL cannot load dinput8.dll\n");
        return 1;
    }
    proc = GetProcAddress(module, "DirectInput8Create");
    if (proc == NULL) {
        printf("FAIL DirectInput8Create is missing\n");
        return 1;
    }
    memcpy(&create, &proc, sizeof(create));
    if (create == NULL) {
        printf("FAIL DirectInput8Create is null\n");
        return 1;
    }
    run_probe(create);
    run_probe_ansi(create);
    if (failures != 0) {
        printf("%d checks failed\n", failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}
