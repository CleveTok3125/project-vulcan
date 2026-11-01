/*
 * Native DirectInput8 proxy for Vulcan.
 *
 * The Linux input daemon publishes the current pad state to
 * C:\vulcan-gamepad.bin. XInput games read it through xinput1_4.dll; this
 * proxy adds the same pad as a DirectInput joystick for games that use
 * DirectInput, including Zenless Zone Zero.
 *
 * DirectInput force feedback is mapped to the two grip motors and written to
 * C:\vulcan-data\vulcan-rumble.bin. The Apollo build watches that file.
 */
#define DIRECTINPUT_VERSION 0x0800
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dinput.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <new>

namespace {

constexpr uint32_t kGamepadMagic = 0x56475031u;
constexpr uint32_t kRumbleMagic = 0x5647524Du;
constexpr DWORD kMaxAxes = 4;
constexpr DWORD kMaxTypeSpecificBytes = 256;
constexpr size_t kMaxEffects = 32;
constexpr DWORD kRumblePollMs = 10;
constexpr LONG kMaxForce = 10000;

constexpr char kGamepadPath[] = "C:\\vulcan-gamepad.bin";
constexpr char kRumblePath[] = "C:\\vulcan-data\\vulcan-rumble.bin";
constexpr char kRumbleTmp[] = "C:\\vulcan-data\\vulcan-rumble.%lu.tmp";
constexpr char kRumbleLock[] = "C:\\vulcan-data\\vulcan-rumble.lock";
constexpr wchar_t kDeviceName[] = L"Controller (XBOX 360 For Windows)";

/* Stable instance GUID for the one virtual pad. */
const GUID kVirtualGuid = {
    0x9f2c4d10u, 0x6a3b, 0x4c2d,
    {0x9e, 0x8f, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66}};

/* Product GUID for an Xbox 360 wired controller. */
const GUID kProductGuid = {
    0x045e028eu, 0x0000, 0x0000,
    {0x00, 0x00, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}};

struct GamepadState {
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
};

struct RumbleRecord {
    uint32_t magic;
    uint32_t sequence;
    uint16_t left;
    uint16_t right;
    uint32_t reserved;
};

static_assert(sizeof(GamepadState) == 28, "unexpected gamepad state size");
static_assert(sizeof(RumbleRecord) == 16, "unexpected rumble record size");

bool read_gamepad(GamepadState *state) noexcept {
    if (state == nullptr) {
        return false;
    }
    memset(state, 0, sizeof(*state));
    HANDLE file = CreateFileA(
        kGamepadPath,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD read = 0;
    const BOOL ok = ReadFile(file, state, sizeof(*state), &read, nullptr);
    CloseHandle(file);
    if (!ok || read != sizeof(*state)) {
        memset(state, 0, sizeof(*state));
        return false;
    }
    return state->magic == kGamepadMagic && state->connected != 0;
}

void copy_wide(wchar_t *dst, size_t count, const wchar_t *src) noexcept {
    if (dst == nullptr || count == 0) {
        return;
    }
    size_t i = 0;
    if (src != nullptr) {
        for (; i + 1 < count && src[i] != L'\0'; ++i) {
            dst[i] = src[i];
        }
    }
    dst[i] = L'\0';
}

void copy_ansi_from_wide(char *dst, size_t count, const wchar_t *src) noexcept {
    if (dst == nullptr || count == 0) {
        return;
    }
    dst[0] = '\0';
    if (src == nullptr || count > static_cast<size_t>(INT_MAX)) {
        return;
    }
    const int written = WideCharToMultiByte(
        CP_ACP, 0, src, -1, dst, static_cast<int>(count), nullptr, nullptr);
    if (written <= 0) {
        dst[0] = '\0';
    }
}

LONG abs_long(LONG value) noexcept {
    if (value == INT32_MIN) {
        return kMaxForce;
    }
    return value < 0 ? -value : value;
}

LONG clamp_force(LONG value) noexcept {
    if (value < 0) {
        return 0;
    }
    if (value > kMaxForce) {
        return kMaxForce;
    }
    return value;
}

struct EffectState {
    GUID guid{};
    bool active{false};
    bool paused{false};
    DWORD gain{kMaxForce};
    DWORD axes_count{0};
    DWORD axes[kMaxAxes]{};
    LONG direction[kMaxAxes]{};
    bool has_envelope{false};
    DIENVELOPE envelope{};
    DWORD type_specific_size{0};
    BYTE type_specific[kMaxTypeSpecificBytes]{};
    DWORD effect_type{0};
    DWORD duration{0};
    DWORD start_delay{0};
    ULONGLONG start_time{0};
    ULONGLONG end_time{0};
    bool infinite{true};
};

struct EffectInfoEntry {
    const GUID *guid;
    const wchar_t *name;
    DWORD type;
};

const EffectInfoEntry kEffectEntries[] = {
    {&GUID_ConstantForce, L"Constant Force", DIEFT_CONSTANTFORCE},
    {&GUID_RampForce, L"Ramp Force", DIEFT_RAMPFORCE},
    {&GUID_Square, L"Square", DIEFT_PERIODIC},
    {&GUID_Sine, L"Sine", DIEFT_PERIODIC},
    {&GUID_Triangle, L"Triangle", DIEFT_PERIODIC},
    {&GUID_SawtoothUp, L"Sawtooth Up", DIEFT_PERIODIC},
    {&GUID_SawtoothDown, L"Sawtooth Down", DIEFT_PERIODIC},
    {&GUID_Spring, L"Spring", DIEFT_CONDITION},
    {&GUID_Damper, L"Damper", DIEFT_CONDITION},
    {&GUID_Inertia, L"Inertia", DIEFT_CONDITION},
    {&GUID_Friction, L"Friction", DIEFT_CONDITION},
};

const EffectInfoEntry *find_effect(const GUID &guid) noexcept {
    for (const auto &entry : kEffectEntries) {
        if (IsEqualGUID(guid, *entry.guid)) {
            return &entry;
        }
    }
    return nullptr;
}

bool copy_effect_state(EffectState *state, const DIEFFECT *effect) noexcept {
    if (state == nullptr || effect == nullptr) {
        return false;
    }
    if (effect->dwSize < sizeof(DIEFFECT)) {
        return false;
    }
    if (effect->cAxes > kMaxAxes) {
        return false;
    }
    if (effect->cbTypeSpecificParams > kMaxTypeSpecificBytes) {
        return false;
    }
    if (effect->cAxes > 0 && effect->rgdwAxes == nullptr) {
        return false;
    }
    if (effect->cAxes > 0 && effect->rglDirection == nullptr) {
        return false;
    }
    if (effect->cbTypeSpecificParams > 0 && effect->lpvTypeSpecificParams == nullptr) {
        return false;
    }

    state->gain = effect->dwGain > static_cast<DWORD>(kMaxForce)
        ? static_cast<DWORD>(kMaxForce)
        : effect->dwGain;
    state->duration = effect->dwDuration;
    state->start_delay = effect->dwStartDelay;
    state->infinite = state->duration == 0 || state->duration == INFINITE;
    state->axes_count = effect->cAxes;
    memset(state->axes, 0, sizeof(state->axes));
    memset(state->direction, 0, sizeof(state->direction));
    for (DWORD i = 0; i < effect->cAxes; ++i) {
        state->axes[i] = effect->rgdwAxes[i];
        state->direction[i] = effect->rglDirection[i];
    }

    state->type_specific_size = effect->cbTypeSpecificParams;
    memset(state->type_specific, 0, sizeof(state->type_specific));
    if (state->type_specific_size > 0) {
        memcpy(state->type_specific, effect->lpvTypeSpecificParams,
               state->type_specific_size);
    }

    state->has_envelope = false;
    memset(&state->envelope, 0, sizeof(state->envelope));
    if (effect->lpEnvelope != nullptr
        && effect->lpEnvelope->dwSize >= sizeof(DIENVELOPE)) {
        state->envelope = *effect->lpEnvelope;
        state->has_envelope = true;
    }
    return true;
}

DWORD effect_magnitude(const EffectState *state) noexcept {
    if (state == nullptr) {
        return 0;
    }
    LONG magnitude = 0;
    switch (state->effect_type) {
        case DIEFT_CONSTANTFORCE: {
            if (state->type_specific_size >= sizeof(DICONSTANTFORCE)) {
                DICONSTANTFORCE value{};
                memcpy(&value, state->type_specific, sizeof(value));
                magnitude = abs_long(value.lMagnitude);
            }
            break;
        }
        case DIEFT_RAMPFORCE: {
            if (state->type_specific_size >= sizeof(DIRAMPFORCE)) {
                DIRAMPFORCE value{};
                memcpy(&value, state->type_specific, sizeof(value));
                const LONG start = abs_long(value.lStart);
                const LONG end = abs_long(value.lEnd);
                magnitude = start > end ? start : end;
            }
            break;
        }
        case DIEFT_PERIODIC: {
            if (state->type_specific_size >= sizeof(DIPERIODIC)) {
                DIPERIODIC value{};
                memcpy(&value, state->type_specific, sizeof(value));
                magnitude = static_cast<LONG>(value.dwMagnitude);
            }
            break;
        }
        case DIEFT_CUSTOMFORCE: {
            if (state->type_specific_size >= sizeof(DICUSTOMFORCE)) {
                DICUSTOMFORCE value{};
                memcpy(&value, state->type_specific, sizeof(value));
                const uint64_t sample_count =
                    static_cast<uint64_t>(value.cChannels) * value.cSamples;
                const DWORD available = static_cast<DWORD>(
                    (state->type_specific_size - sizeof(DICUSTOMFORCE))
                    / sizeof(LONG));
                const DWORD count = sample_count < available
                    ? static_cast<DWORD>(sample_count)
                    : available;
                const auto *samples = reinterpret_cast<const LONG *>(
                    state->type_specific + sizeof(DICUSTOMFORCE));
                for (DWORD i = 0; i < count; ++i) {
                    const LONG sample = abs_long(samples[i]);
                    if (sample > magnitude) {
                        magnitude = sample;
                    }
                }
            }
            break;
        }
        case DIEFT_CONDITION: {
            if (state->type_specific_size >= sizeof(DICONDITION)) {
                DICONDITION value{};
                memcpy(&value, state->type_specific, sizeof(value));
                const LONG positive = abs_long(value.lPositiveCoefficient);
                const LONG negative = abs_long(value.lNegativeCoefficient);
                magnitude = positive > negative ? positive : negative;
            }
            break;
        }
        default:
            break;
    }
    return static_cast<DWORD>(clamp_force(magnitude));
}

class RumbleEngine {
public:
    RumbleEngine() noexcept {
        InitializeCriticalSection(&lock_);
        stop_event_ = CreateEventA(nullptr, TRUE, FALSE, nullptr);
    }

    RumbleEngine(const RumbleEngine &) = delete;
    RumbleEngine &operator=(const RumbleEngine &) = delete;

    ~RumbleEngine() noexcept {
        shutdown();
        if (stop_event_ != nullptr) {
            CloseHandle(stop_event_);
            stop_event_ = nullptr;
        }
        DeleteCriticalSection(&lock_);
    }

    bool register_effect(EffectState *state) noexcept {
        if (state == nullptr) {
            return false;
        }
        bool ok = false;
        EnterCriticalSection(&lock_);
        if (effect_count_ < kMaxEffects) {
            effects_[effect_count_++] = state;
            ok = true;
        }
        LeaveCriticalSection(&lock_);
        return ok;
    }

    void unregister_effect(EffectState *state) noexcept {
        if (state == nullptr) {
            return;
        }
        EnterCriticalSection(&lock_);
        for (size_t i = 0; i < effect_count_; ++i) {
            if (effects_[i] == state) {
                effects_[i] = effects_[effect_count_ - 1];
                effects_[effect_count_ - 1] = nullptr;
                --effect_count_;
                break;
            }
        }
        LeaveCriticalSection(&lock_);
    }

    void start_effect(EffectState *state, DWORD duration) noexcept {
        if (state == nullptr) {
            return;
        }
        EnterCriticalSection(&lock_);
        const ULONGLONG now = GetTickCount64();
        const DWORD effective_duration = duration != 0 ? duration : state->duration;
        const ULONGLONG delay_ms =
            static_cast<ULONGLONG>(state->start_delay) / 1000;
        state->active = true;
        state->start_time = now + delay_ms;
        state->infinite = effective_duration == 0
            || effective_duration == INFINITE;
        state->end_time = state->infinite
            ? 0
            : state->start_time + effective_duration / 1000;
        ensure_thread();
        LeaveCriticalSection(&lock_);
    }

    void stop_effect(EffectState *state) noexcept {
        if (state == nullptr) {
            return;
        }
        EnterCriticalSection(&lock_);
        state->active = false;
        LeaveCriticalSection(&lock_);
    }

    bool set_effect_parameters(
        EffectState *state,
        const DIEFFECT *effect
    ) noexcept {
        if (state == nullptr) {
            return false;
        }
        EffectState updated{};
        if (!copy_effect_state(&updated, effect)) {
            return false;
        }
        EnterCriticalSection(&lock_);
        updated.guid = state->guid;
        updated.effect_type = state->effect_type;
        *state = updated;
        LeaveCriticalSection(&lock_);
        return true;
    }

    void snapshot_effect(EffectState *state, EffectState *out) noexcept {
        if (state == nullptr || out == nullptr) {
            return;
        }
        EnterCriticalSection(&lock_);
        *out = *state;
        LeaveCriticalSection(&lock_);
    }

    void stop_all() noexcept {
        EnterCriticalSection(&lock_);
        for (size_t i = 0; i < effect_count_; ++i) {
            if (effects_[i] != nullptr) {
                effects_[i]->active = false;
            }
        }
        LeaveCriticalSection(&lock_);
    }

    void reset() noexcept {
        EnterCriticalSection(&lock_);
        for (size_t i = 0; i < effect_count_; ++i) {
            if (effects_[i] != nullptr) {
                effects_[i]->active = false;
            }
        }
        paused_ = false;
        actuators_ = true;
        LeaveCriticalSection(&lock_);
    }

    void set_paused(bool paused) noexcept {
        EnterCriticalSection(&lock_);
        paused_ = paused;
        LeaveCriticalSection(&lock_);
    }

    void set_actuators(bool enabled) noexcept {
        EnterCriticalSection(&lock_);
        actuators_ = enabled;
        LeaveCriticalSection(&lock_);
    }

    DWORD state() noexcept {
        DWORD result = DIGFFS_ACTUATORSON;
        EnterCriticalSection(&lock_);
        if (!actuators_) {
            result = DIGFFS_ACTUATORSOFF;
        }
        if (paused_) {
            result |= DIGFFS_PAUSED;
        }
        bool any_active = false;
        for (size_t i = 0; i < effect_count_; ++i) {
            if (effects_[i] != nullptr && effects_[i]->active) {
                any_active = true;
                break;
            }
        }
        if (!any_active) {
            result |= DIGFFS_EMPTY;
        }
        LeaveCriticalSection(&lock_);
        return result;
    }

    void shutdown() noexcept {
        if (stop_event_ != nullptr) {
            SetEvent(stop_event_);
        }
        if (thread_ != nullptr) {
            WaitForSingleObject(thread_, 1000);
            CloseHandle(thread_);
            thread_ = nullptr;
        }
        write_record(0, 0);
        if (lock_file_ != INVALID_HANDLE_VALUE) {
            CloseHandle(lock_file_);
            lock_file_ = INVALID_HANDLE_VALUE;
        }
    }

private:
    static DWORD WINAPI thread_entry(LPVOID context) noexcept {
        auto *engine = static_cast<RumbleEngine *>(context);
        if (engine == nullptr) {
            return 0;
        }
        engine->run();
        return 0;
    }

    void ensure_thread() noexcept {
        if (thread_ != nullptr || stop_event_ == nullptr) {
            return;
        }
        thread_ = CreateThread(nullptr, 0, thread_entry, this, 0, nullptr);
    }

    void run() noexcept {
        for (;;) {
            const DWORD wait = WaitForSingleObject(stop_event_, kRumblePollMs);
            if (wait == WAIT_OBJECT_0) {
                break;
            }
            EnterCriticalSection(&lock_);
            update();
            LeaveCriticalSection(&lock_);
        }
    }

    void update() noexcept {
        const ULONGLONG now = GetTickCount64();
        uint16_t left = 0;
        uint16_t right = 0;
        if (!paused_ && actuators_) {
            for (size_t i = 0; i < effect_count_; ++i) {
                EffectState *state = effects_[i];
                if (state == nullptr || !state->active) {
                    continue;
                }
                if (now < state->start_time) {
                    continue;
                }
                if (state->end_time != 0 && now >= state->end_time) {
                    state->active = false;
                    continue;
                }
                DWORD magnitude = effect_magnitude(state);
                magnitude = magnitude * state->gain / kMaxForce;
                if (state->has_envelope) {
                    const ULONGLONG elapsed = now - state->start_time;
                    const ULONGLONG attack =
                        static_cast<ULONGLONG>(state->envelope.dwAttackTime) / 1000;
                    const ULONGLONG fade =
                        static_cast<ULONGLONG>(state->envelope.dwFadeTime) / 1000;
                    if (attack > 0 && elapsed < attack) {
                        const DWORD level = state->envelope.dwAttackLevel;
                        magnitude = static_cast<DWORD>(
                            static_cast<ULONGLONG>(magnitude) * level / kMaxForce
                            + static_cast<ULONGLONG>(magnitude)
                                * (kMaxForce - level) * elapsed
                                / (kMaxForce * attack));
                    }
                    if (fade > 0 && state->end_time != 0) {
                        const ULONGLONG remaining = state->end_time - now;
                        if (remaining < fade) {
                            const DWORD level = state->envelope.dwFadeLevel;
                            magnitude = static_cast<DWORD>(
                                static_cast<ULONGLONG>(magnitude) * level / kMaxForce
                                + static_cast<ULONGLONG>(magnitude)
                                    * (kMaxForce - level) * remaining
                                    / (kMaxForce * fade));
                        }
                    }
                }
                if (magnitude > kMaxForce) {
                    magnitude = kMaxForce;
                }
                const uint16_t value = static_cast<uint16_t>(
                    static_cast<uint64_t>(magnitude) * 65535u / kMaxForce);
                const bool has_direction =
                    state->axes_count >= 2 && state->direction[0] != 0;
                if (has_direction && state->direction[0] < 0) {
                    if (value > left) {
                        left = value;
                    }
                } else if (has_direction) {
                    if (value > right) {
                        right = value;
                    }
                } else {
                    if (value > left) {
                        left = value;
                    }
                    if (value > right) {
                        right = value;
                    }
                }
            }
        }
        write_record(left, right);
    }

    bool ensure_lock() noexcept {
        if (lock_file_ != INVALID_HANDLE_VALUE) {
            return true;
        }
        lock_file_ = CreateFileA(
            kRumbleLock,
            GENERIC_WRITE | DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE,
            nullptr
        );
        return lock_file_ != INVALID_HANDLE_VALUE;
    }

    void write_record(uint16_t left, uint16_t right) noexcept {
        if (left == last_left_ && right == last_right_
            && GetFileAttributesA(kRumblePath) != INVALID_FILE_ATTRIBUTES) {
            return;
        }
        if (!ensure_lock()) {
            return;
        }
        RumbleRecord record{};
        record.magic = kRumbleMagic;
        record.sequence = sequence_ + 1;
        record.left = left;
        record.right = right;
        char tmp[sizeof(kRumbleTmp) + 32]{};
        snprintf(tmp, sizeof(tmp), kRumbleTmp,
                 static_cast<unsigned long>(GetCurrentProcessId()));
        HANDLE file = CreateFileA(
            tmp,
            GENERIC_WRITE,
            0,
            nullptr,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr
        );
        if (file == INVALID_HANDLE_VALUE) {
            return;
        }
        DWORD written = 0;
        const BOOL ok = WriteFile(file, &record, sizeof(record), &written, nullptr);
        CloseHandle(file);
        if (!ok || written != sizeof(record)) {
            DeleteFileA(tmp);
            return;
        }
        if (!MoveFileExA(tmp, kRumblePath, MOVEFILE_REPLACE_EXISTING)) {
            DeleteFileA(tmp);
            return;
        }
        last_left_ = left;
        last_right_ = right;
        ++sequence_;
    }

    CRITICAL_SECTION lock_{};
    HANDLE stop_event_{nullptr};
    HANDLE thread_{nullptr};
    EffectState *effects_[kMaxEffects]{};
    size_t effect_count_{0};
    bool paused_{false};
    bool actuators_{true};
    HANDLE lock_file_{INVALID_HANDLE_VALUE};
    uint32_t sequence_{0};
    uint16_t last_left_{0};
    uint16_t last_right_{0};
};

RumbleEngine &rumble_engine() noexcept {
    static RumbleEngine engine;
    return engine;
}

class VirtualEffect final : public IDirectInputEffect {
public:
    VirtualEffect(RumbleEngine *engine, const GUID &guid) noexcept
        : engine_(engine), guid_(guid) {
        state_.guid = guid;
        const EffectInfoEntry *entry = find_effect(guid);
        state_.effect_type = entry != nullptr ? entry->type : 0;
        state_.infinite = true;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IDirectInputEffect)) {
            *out = static_cast<IDirectInputEffect *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&ref_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG ref = InterlockedDecrement(&ref_);
        if (ref == 0) {
            if (engine_ != nullptr) {
                engine_->unregister_effect(&state_);
            }
            delete this;
        }
        return static_cast<ULONG>(ref);
    }

    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEffectGuid(LPGUID guid) override {
        if (guid == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        *guid = guid_;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetParameters(LPDIEFFECT effect, DWORD) override {
        if (effect == nullptr || effect->dwSize < sizeof(DIEFFECT)) {
            return DIERR_INVALIDPARAM;
        }
        if (engine_ != nullptr) {
            engine_->snapshot_effect(&state_, &parameters_cache_);
        } else {
            parameters_cache_ = state_;
        }
        memset(effect, 0, sizeof(DIEFFECT));
        effect->dwSize = sizeof(DIEFFECT);
        effect->dwFlags = DIEFF_CARTESIAN | DIEFF_OBJECTOFFSETS;
        effect->dwDuration = parameters_cache_.duration;
        effect->dwStartDelay = parameters_cache_.start_delay;
        effect->dwGain = parameters_cache_.gain;
        effect->cAxes = parameters_cache_.axes_count;
        effect->rgdwAxes = parameters_cache_.axes;
        effect->rglDirection = parameters_cache_.direction;
        effect->cbTypeSpecificParams = parameters_cache_.type_specific_size;
        effect->lpvTypeSpecificParams = parameters_cache_.type_specific;
        if (parameters_cache_.has_envelope) {
            effect->lpEnvelope = &parameters_cache_.envelope;
        }
        if (parameters_cache_.effect_type == DIEFT_CUSTOMFORCE
            && parameters_cache_.type_specific_size >= sizeof(DICUSTOMFORCE)) {
            auto *custom = reinterpret_cast<DICUSTOMFORCE *>(
                parameters_cache_.type_specific);
            custom->rglForceData = reinterpret_cast<LONG *>(
                parameters_cache_.type_specific + sizeof(DICUSTOMFORCE));
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SetParameters(LPCDIEFFECT effect, DWORD) override {
        if (engine_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        if (!engine_->set_effect_parameters(&state_, effect)) {
            return DIERR_INVALIDPARAM;
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Start(DWORD, DWORD duration) override {
        if (engine_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        engine_->start_effect(&state_, duration);
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Stop() override {
        if (engine_ != nullptr) {
            engine_->stop_effect(&state_);
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEffectStatus(LPDWORD flags) override {
        if (flags == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        EffectState snapshot{};
        if (engine_ != nullptr) {
            engine_->snapshot_effect(&state_, &snapshot);
        } else {
            snapshot = state_;
        }
        *flags = snapshot.active ? DIEGES_PLAYING : 0;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Download() override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Unload() override {
        if (engine_ != nullptr) {
            engine_->stop_effect(&state_);
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override {
        return DIERR_UNSUPPORTED;
    }

    EffectState &state_for_proxy() noexcept {
        return state_;
    }

private:
    ~VirtualEffect() noexcept = default;

    RumbleEngine *engine_{nullptr};
    GUID guid_{};
    EffectState state_{};
    EffectState parameters_cache_{};
    LONG ref_{1};
};

class VirtualDevice final : public IDirectInputDevice8W {
public:
    VirtualDevice(RumbleEngine *engine, const GUID &guid) noexcept
        : engine_(engine), guid_(guid) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown)
            || IsEqualIID(riid, IID_IDirectInputDevice8W)) {
            *out = static_cast<IDirectInputDevice8W *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&ref_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG ref = InterlockedDecrement(&ref_);
        if (ref == 0) {
            delete this;
        }
        return static_cast<ULONG>(ref);
    }

    HRESULT STDMETHODCALLTYPE GetCapabilities(LPDIDEVCAPS caps) override {
        if (caps == nullptr || caps->dwSize < sizeof(DIDEVCAPS)) {
            return DIERR_INVALIDPARAM;
        }
        memset(caps, 0, sizeof(*caps));
        caps->dwSize = sizeof(DIDEVCAPS);
        caps->dwFlags = DIDC_ATTACHED | DIDC_EMULATED | DIDC_POLLEDDEVICE
            | DIDC_FORCEFEEDBACK;
        caps->dwDevType = DI8DEVTYPE_GAMEPAD
            | (DI8DEVTYPEGAMEPAD_STANDARD << 8);
        caps->dwAxes = 6;
        caps->dwButtons = 11;
        caps->dwPOVs = 1;
        caps->dwFFSamplePeriod = 1000;
        caps->dwFFMinTimeResolution = 1000;
        caps->dwFirmwareRevision = 0x0100;
        caps->dwHardwareRevision = 0x0100;
        caps->dwFFDriverVersion = 0x0100;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE EnumObjects(
        LPDIENUMDEVICEOBJECTSCALLBACKW callback,
        LPVOID ref,
        DWORD flags
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        for (DWORD i = 0; i < 6; ++i) {
            if ((flags & DIDFT_AXIS) != 0) {
                DIDEVICEOBJECTINSTANCEW object{};
                if (!fill_axis_object(&object, i)) {
                    continue;
                }
                if (callback(&object, ref) == DIENUM_STOP) {
                    return DI_OK;
                }
            }
        }
        if ((flags & DIDFT_POV) != 0) {
            DIDEVICEOBJECTINSTANCEW object{};
            fill_pov_object(&object);
            if (callback(&object, ref) == DIENUM_STOP) {
                return DI_OK;
            }
        }
        for (DWORD i = 0; i < 11; ++i) {
            if ((flags & DIDFT_BUTTON) != 0) {
                DIDEVICEOBJECTINSTANCEW object{};
                fill_button_object(&object, i);
                if (callback(&object, ref) == DIENUM_STOP) {
                    return DI_OK;
                }
            }
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetProperty(REFGUID property, LPDIPROPHEADER header) override {
        if (header == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (header->dwSize < sizeof(DIPROPHEADER)) {
            return DIERR_INVALIDPARAM;
        }
        if (header->dwHow == DIPH_DEVICE) {
            return get_device_property(property, header);
        }
        if (header->dwHow == DIPH_BYOFFSET || header->dwHow == DIPH_BYID) {
            return get_object_property(property, header);
        }
        return DIERR_INVALIDPARAM;
    }

    HRESULT STDMETHODCALLTYPE SetProperty(REFGUID property, LPCDIPROPHEADER header) override {
        if (header == nullptr || header->dwSize < sizeof(DIPROPHEADER)) {
            return DIERR_INVALIDPARAM;
        }
        if (IsEqualGUID(property, DIPROP_RANGE)
            || IsEqualGUID(property, DIPROP_DEADZONE)
            || IsEqualGUID(property, DIPROP_SATURATION)
            || IsEqualGUID(property, DIPROP_BUFFERSIZE)
            || IsEqualGUID(property, DIPROP_AXISMODE)
            || IsEqualGUID(property, DIPROP_FFGAIN)) {
            return DI_OK;
        }
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE Acquire() override {
        if (!data_format_set_) {
            return DIERR_NOTINITIALIZED;
        }
        acquired_ = true;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Unacquire() override {
        acquired_ = false;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceState(DWORD size, LPVOID data) override {
        if (data == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (!data_format_set_) {
            return DIERR_NOTINITIALIZED;
        }
        if (!acquired_) {
            return DIERR_NOTACQUIRED;
        }
        if (size < data_size_) {
            return DIERR_INVALIDPARAM;
        }
        DWORD clear = size;
        if (clear > sizeof(DIJOYSTATE2)) {
            clear = sizeof(DIJOYSTATE2);
        }
        memset(data, 0, clear);
        GamepadState raw{};
        const bool connected = read_gamepad(&raw);
        if (data_size_ == sizeof(DIJOYSTATE2)) {
            fill_joy2(static_cast<DIJOYSTATE2 *>(data), raw, connected);
        } else {
            fill_joy(static_cast<DIJOYSTATE *>(data), raw, connected);
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceData(
        DWORD object_size,
        LPDIDEVICEOBJECTDATA data,
        LPDWORD count,
        DWORD
    ) override {
        if (data == nullptr || count == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (object_size != sizeof(DIDEVICEOBJECTDATA)) {
            return DIERR_INVALIDPARAM;
        }
        if (!acquired_) {
            return DIERR_NOTACQUIRED;
        }
        *count = 0;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SetDataFormat(LPCDIDATAFORMAT format) override {
        if (format == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (format->dwDataSize == sizeof(DIJOYSTATE2)) {
            data_size_ = sizeof(DIJOYSTATE2);
        } else if (format->dwDataSize == sizeof(DIJOYSTATE)) {
            data_size_ = sizeof(DIJOYSTATE);
        } else {
            return DIERR_INVALIDPARAM;
        }
        data_format_set_ = true;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SetEventNotification(HANDLE) override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SetCooperativeLevel(HWND, DWORD flags) override {
        cooperative_flags_ = flags;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetObjectInfo(
        LPDIDEVICEOBJECTINSTANCEW object,
        DWORD id,
        DWORD how
    ) override {
        if (object == nullptr || object->dwSize < sizeof(DIDEVICEOBJECTINSTANCEW)) {
            return DIERR_INVALIDPARAM;
        }
        DWORD offset = 0;
        if (how == DIPH_BYOFFSET) {
            offset = id;
        } else if (how == DIPH_BYID) {
            offset = offset_from_id(id);
        } else {
            return DIERR_INVALIDPARAM;
        }
        if (offset == 0xFFFFFFFFu) {
            return DIERR_OBJECTNOTFOUND;
        }
        memset(object, 0, sizeof(*object));
        object->dwSize = sizeof(DIDEVICEOBJECTINSTANCEW);
        if (!fill_object_by_offset(object, offset)) {
            return DIERR_OBJECTNOTFOUND;
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceInfo(LPDIDEVICEINSTANCEW info) override {
        if (info == nullptr || info->dwSize < sizeof(DIDEVICEINSTANCEW)) {
            return DIERR_INVALIDPARAM;
        }
        memset(info, 0, sizeof(*info));
        info->dwSize = sizeof(DIDEVICEINSTANCEW);
        info->guidInstance = kVirtualGuid;
        info->guidProduct = kProductGuid;
        info->dwDevType = DI8DEVTYPE_GAMEPAD
            | (DI8DEVTYPEGAMEPAD_STANDARD << 8);
        copy_wide(info->tszInstanceName, MAX_PATH, kDeviceName);
        copy_wide(info->tszProductName, MAX_PATH, kDeviceName);
        info->guidFFDriver = GUID_NULL;
        info->wUsagePage = 0x01;
        info->wUsage = 0x05;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND, DWORD) override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE, DWORD, REFGUID) override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE CreateEffect(
        REFGUID guid,
        LPCDIEFFECT effect,
        LPDIRECTINPUTEFFECT *out,
        LPUNKNOWN outer
    ) override {
        if (out == nullptr || effect == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        *out = nullptr;
        if (outer != nullptr) {
            return CLASS_E_NOAGGREGATION;
        }
        if (find_effect(guid) == nullptr) {
            return DIERR_UNSUPPORTED;
        }
        auto *created = new (std::nothrow) VirtualEffect(engine_, guid);
        if (created == nullptr) {
            return DIERR_OUTOFMEMORY;
        }
        if (!copy_effect_state(&created->state_for_proxy(), effect)) {
            created->Release();
            return DIERR_INVALIDPARAM;
        }
        const EffectInfoEntry *entry = find_effect(guid);
        created->state_for_proxy().effect_type =
            entry != nullptr ? entry->type : 0;
        if (engine_ == nullptr
            || !engine_->register_effect(&created->state_for_proxy())) {
            created->Release();
            return DIERR_OUTOFMEMORY;
        }
        *out = created;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE EnumEffects(
        LPDIENUMEFFECTSCALLBACKW callback,
        LPVOID ref,
        DWORD type
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        for (const auto &entry : kEffectEntries) {
            if (type != DIEFT_ALL && entry.type != type) {
                continue;
            }
            DIEFFECTINFOW info{};
            fill_effect_info(&info, entry);
            if (callback(&info, ref) == DIENUM_STOP) {
                break;
            }
        }
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEffectInfo(
        LPDIEFFECTINFOW info,
        REFGUID guid
    ) override {
        if (info == nullptr || info->dwSize < sizeof(DIEFFECTINFOW)) {
            return DIERR_INVALIDPARAM;
        }
        const EffectInfoEntry *entry = find_effect(guid);
        if (entry == nullptr) {
            return DIERR_OBJECTNOTFOUND;
        }
        memset(info, 0, sizeof(*info));
        info->dwSize = sizeof(DIEFFECTINFOW);
        fill_effect_info(info, *entry);
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetForceFeedbackState(LPDWORD state) override {
        if (state == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        *state = engine_ != nullptr ? engine_->state() : DIGFFS_ACTUATORSOFF;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SendForceFeedbackCommand(DWORD command) override {
        if (engine_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        switch (command) {
            case DISFFC_RESET:
                engine_->reset();
                return DI_OK;
            case DISFFC_STOPALL:
                engine_->stop_all();
                return DI_OK;
            case DISFFC_PAUSE:
                engine_->set_paused(true);
                return DI_OK;
            case DISFFC_CONTINUE:
                engine_->set_paused(false);
                return DI_OK;
            case DISFFC_SETACTUATORSON:
                engine_->set_actuators(true);
                return DI_OK;
            case DISFFC_SETACTUATORSOFF:
                engine_->set_actuators(false);
                return DI_OK;
            default:
                return DIERR_INVALIDPARAM;
        }
    }

    HRESULT STDMETHODCALLTYPE EnumCreatedEffectObjects(
        LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback,
        LPVOID ref,
        DWORD
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        (void)ref;
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE) override {
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE Poll() override {
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE SendDeviceData(
        DWORD,
        LPCDIDEVICEOBJECTDATA,
        LPDWORD count,
        DWORD
    ) override {
        if (count != nullptr) {
            *count = 0;
        }
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE EnumEffectsInFile(
        LPCWSTR,
        LPDIENUMEFFECTSINFILECALLBACK,
        LPVOID,
        DWORD
    ) override {
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE WriteEffectToFile(
        LPCWSTR,
        DWORD,
        LPDIFILEEFFECT,
        DWORD
    ) override {
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE BuildActionMap(
        LPDIACTIONFORMATW,
        LPCWSTR,
        DWORD
    ) override {
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE SetActionMap(
        LPDIACTIONFORMATW,
        LPCWSTR,
        DWORD
    ) override {
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE GetImageInfo(LPDIDEVICEIMAGEINFOHEADERW) override {
        return DIERR_UNSUPPORTED;
    }

private:
    ~VirtualDevice() noexcept = default;

    static DWORD pov_from_buttons(uint16_t buttons) noexcept {
        const bool up = (buttons & 0x0001u) != 0;
        const bool down = (buttons & 0x0002u) != 0;
        const bool left = (buttons & 0x0004u) != 0;
        const bool right = (buttons & 0x0008u) != 0;
        if (up && right) {
            return 4500;
        }
        if (up && left) {
            return 31500;
        }
        if (down && right) {
            return 13500;
        }
        if (down && left) {
            return 22500;
        }
        if (up) {
            return 0;
        }
        if (right) {
            return 9000;
        }
        if (down) {
            return 18000;
        }
        if (left) {
            return 27000;
        }
        return 0xFFFFFFFFu;
    }

    static void set_button(BYTE *buttons, size_t count, size_t index, bool pressed) noexcept {
        if (buttons != nullptr && index < count && pressed) {
            buttons[index] = 0x80;
        }
    }

    static void fill_buttons(BYTE *buttons, size_t count, uint16_t value) noexcept {
        if (buttons == nullptr) {
            return;
        }
        set_button(buttons, count, 0, (value & 0x1000u) != 0);
        set_button(buttons, count, 1, (value & 0x2000u) != 0);
        set_button(buttons, count, 2, (value & 0x4000u) != 0);
        set_button(buttons, count, 3, (value & 0x8000u) != 0);
        set_button(buttons, count, 4, (value & 0x0100u) != 0);
        set_button(buttons, count, 5, (value & 0x0200u) != 0);
        set_button(buttons, count, 6, (value & 0x0020u) != 0);
        set_button(buttons, count, 7, (value & 0x0010u) != 0);
        set_button(buttons, count, 8, (value & 0x0040u) != 0);
        set_button(buttons, count, 9, (value & 0x0080u) != 0);
        set_button(buttons, count, 10, (value & 0x0400u) != 0);
    }

    static void fill_joy2(DIJOYSTATE2 *state, const GamepadState &raw, bool connected) noexcept {
        if (state == nullptr) {
            return;
        }
        state->rgdwPOV[0] = 0xFFFFFFFFu;
        state->rgdwPOV[1] = 0xFFFFFFFFu;
        state->rgdwPOV[2] = 0xFFFFFFFFu;
        state->rgdwPOV[3] = 0xFFFFFFFFu;
        if (!connected) {
            return;
        }
        state->lX = raw.thumb_lx;
        state->lY = -raw.thumb_ly;
        state->lRx = raw.thumb_rx;
        state->lRy = -raw.thumb_ry;
        state->lZ = static_cast<LONG>(raw.left_trigger) * 257;
        state->lRz = static_cast<LONG>(raw.right_trigger) * 257;
        state->rgdwPOV[0] = pov_from_buttons(raw.buttons);
        fill_buttons(state->rgbButtons, sizeof(state->rgbButtons), raw.buttons);
    }

    static void fill_joy(DIJOYSTATE *state, const GamepadState &raw, bool connected) noexcept {
        if (state == nullptr) {
            return;
        }
        state->rgdwPOV[0] = 0xFFFFFFFFu;
        state->rgdwPOV[1] = 0xFFFFFFFFu;
        state->rgdwPOV[2] = 0xFFFFFFFFu;
        state->rgdwPOV[3] = 0xFFFFFFFFu;
        if (!connected) {
            return;
        }
        state->lX = raw.thumb_lx;
        state->lY = -raw.thumb_ly;
        state->lRx = raw.thumb_rx;
        state->lRy = -raw.thumb_ry;
        state->lZ = static_cast<LONG>(raw.left_trigger) * 257;
        state->lRz = static_cast<LONG>(raw.right_trigger) * 257;
        state->rgdwPOV[0] = pov_from_buttons(raw.buttons);
        fill_buttons(state->rgbButtons, sizeof(state->rgbButtons), raw.buttons);
    }

    static bool fill_axis_object(DIDEVICEOBJECTINSTANCEW *object, DWORD index) noexcept {
        if (object == nullptr || index >= 6) {
            return false;
        }
        static const DWORD offsets[6] = {
            DIJOFS_X, DIJOFS_Y, DIJOFS_Z, DIJOFS_RX, DIJOFS_RY, DIJOFS_RZ};
        static const GUID *guids[6] = {
            &GUID_XAxis, &GUID_YAxis, &GUID_ZAxis,
            &GUID_RxAxis, &GUID_RyAxis, &GUID_RzAxis};
        static const wchar_t *names[6] = {
            L"X Axis", L"Y Axis", L"Z Axis",
            L"X Rotation", L"Y Rotation", L"Z Rotation"};
        memset(object, 0, sizeof(*object));
        object->dwSize = sizeof(*object);
        object->guidType = *guids[index];
        object->dwOfs = offsets[index];
        object->dwType = DIDFT_ABSAXIS | DIDFT_MAKEINSTANCE(index);
        object->dwFlags = DIDOI_ASPECTPOSITION;
        copy_wide(object->tszName, MAX_PATH, names[index]);
        object->wUsagePage = 0x01;
        object->wUsage = 0x30 + static_cast<WORD>(index);
        return true;
    }

    static void fill_pov_object(DIDEVICEOBJECTINSTANCEW *object) noexcept {
        if (object == nullptr) {
            return;
        }
        memset(object, 0, sizeof(*object));
        object->dwSize = sizeof(*object);
        object->guidType = GUID_POV;
        object->dwOfs = DIJOFS_POV(0);
        object->dwType = DIDFT_POV | DIDFT_MAKEINSTANCE(0);
        object->dwFlags = DIDOI_ASPECTPOSITION;
        copy_wide(object->tszName, MAX_PATH, L"Hat Switch");
        object->wUsagePage = 0x01;
        object->wUsage = 0x39;
    }

    static void fill_button_object(DIDEVICEOBJECTINSTANCEW *object, DWORD index) noexcept {
        if (object == nullptr) {
            return;
        }
        static const wchar_t *names[11] = {
            L"Button A", L"Button B", L"Button X", L"Button Y",
            L"Left Shoulder", L"Right Shoulder", L"Back", L"Start",
            L"Left Thumb", L"Right Thumb", L"Guide"};
        memset(object, 0, sizeof(*object));
        object->dwSize = sizeof(*object);
        object->guidType = GUID_Button;
        object->dwOfs = DIJOFS_BUTTON(index);
        object->dwType = DIDFT_BUTTON | DIDFT_MAKEINSTANCE(index);
        copy_wide(object->tszName, MAX_PATH,
                  index < 11 ? names[index] : L"Button");
        object->wUsagePage = 0x09;
        object->wUsage = static_cast<WORD>(index + 1);
    }

    static DWORD offset_from_id(DWORD id) noexcept {
        const DWORD type = DIDFT_GETTYPE(id);
        const DWORD instance = DIDFT_GETINSTANCE(id);
        if ((type & DIDFT_AXIS) != 0 && instance < 6) {
            static const DWORD offsets[6] = {
                DIJOFS_X, DIJOFS_Y, DIJOFS_Z,
                DIJOFS_RX, DIJOFS_RY, DIJOFS_RZ};
            return offsets[instance];
        }
        if ((type & DIDFT_POV) != 0 && instance == 0) {
            return DIJOFS_POV(0);
        }
        if ((type & DIDFT_BUTTON) != 0 && instance < 11) {
            return DIJOFS_BUTTON(instance);
        }
        return 0xFFFFFFFFu;
    }

    static bool fill_object_by_offset(
        DIDEVICEOBJECTINSTANCEW *object,
        DWORD offset
    ) noexcept {
        for (DWORD i = 0; i < 6; ++i) {
            static const DWORD offsets[6] = {
                DIJOFS_X, DIJOFS_Y, DIJOFS_Z,
                DIJOFS_RX, DIJOFS_RY, DIJOFS_RZ};
            if (offset == offsets[i]) {
                return fill_axis_object(object, i);
            }
        }
        if (offset == DIJOFS_POV(0)) {
            fill_pov_object(object);
            return true;
        }
        for (DWORD i = 0; i < 11; ++i) {
            if (offset == DIJOFS_BUTTON(i)) {
                fill_button_object(object, i);
                return true;
            }
        }
        return false;
    }

    static void fill_effect_info(
        DIEFFECTINFOW *info,
        const EffectInfoEntry &entry
    ) noexcept {
        if (info == nullptr) {
            return;
        }
        info->guid = *entry.guid;
        info->dwEffType = entry.type;
        info->dwStaticParams = DIEP_ALLPARAMS;
        info->dwDynamicParams = DIEP_TYPESPECIFICPARAMS;
        copy_wide(info->tszName, MAX_PATH, entry.name);
    }

    HRESULT get_device_property(REFGUID property, DIPROPHEADER *header) noexcept {
        if (IsEqualGUID(property, DIPROP_BUFFERSIZE)) {
            if (header->dwSize < sizeof(DIPROPDWORD)) {
                return DIERR_INVALIDPARAM;
            }
            auto *value = reinterpret_cast<DIPROPDWORD *>(header);
            value->dwData = 0;
            return DI_OK;
        }
        if (IsEqualGUID(property, DIPROP_AXISMODE)) {
            if (header->dwSize < sizeof(DIPROPDWORD)) {
                return DIERR_INVALIDPARAM;
            }
            auto *value = reinterpret_cast<DIPROPDWORD *>(header);
            value->dwData = DIPROPAXISMODE_ABS;
            return DI_OK;
        }
        if (IsEqualGUID(property, DIPROP_FFGAIN)) {
            if (header->dwSize < sizeof(DIPROPDWORD)) {
                return DIERR_INVALIDPARAM;
            }
            auto *value = reinterpret_cast<DIPROPDWORD *>(header);
            value->dwData = kMaxForce;
            return DI_OK;
        }
        if (IsEqualGUID(property, DIPROP_VIDPID)) {
            if (header->dwSize < sizeof(DIPROPDWORD)) {
                return DIERR_INVALIDPARAM;
            }
            auto *value = reinterpret_cast<DIPROPDWORD *>(header);
            value->dwData = 0x045e028eu;
            return DI_OK;
        }
        return DIERR_UNSUPPORTED;
    }

    HRESULT get_object_property(REFGUID property, DIPROPHEADER *header) noexcept {
        if (IsEqualGUID(property, DIPROP_RANGE)) {
            if (header->dwSize < sizeof(DIPROPRANGE)) {
                return DIERR_INVALIDPARAM;
            }
            auto *range = reinterpret_cast<DIPROPRANGE *>(header);
            const DWORD offset = header->dwHow == DIPH_BYOFFSET
                ? header->dwObj
                : offset_from_id(header->dwObj);
            if (offset == 0xFFFFFFFFu) {
                return DIERR_OBJECTNOTFOUND;
            }
            if (offset == DIJOFS_Z || offset == DIJOFS_RZ) {
                range->lMin = 0;
                range->lMax = 65535;
            } else {
                range->lMin = -32768;
                range->lMax = 32767;
            }
            return DI_OK;
        }
        if (IsEqualGUID(property, DIPROP_DEADZONE)
            || IsEqualGUID(property, DIPROP_SATURATION)) {
            if (header->dwSize < sizeof(DIPROPDWORD)) {
                return DIERR_INVALIDPARAM;
            }
            auto *value = reinterpret_cast<DIPROPDWORD *>(header);
            value->dwData = IsEqualGUID(property, DIPROP_SATURATION)
                ? static_cast<DWORD>(kMaxForce)
                : 0;
            return DI_OK;
        }
        return DIERR_UNSUPPORTED;
    }

    RumbleEngine *engine_{nullptr};
    GUID guid_{};
    LONG ref_{1};
    bool acquired_{false};
    bool data_format_set_{false};
    DWORD data_size_{0};
    DWORD cooperative_flags_{0};
};

class DirectInput8 final : public IDirectInput8W {
public:
    explicit DirectInput8(IDirectInput8W *real) noexcept : real_(real) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown)
            || IsEqualIID(riid, IID_IDirectInput8W)) {
            *out = static_cast<IDirectInput8W *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&ref_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG ref = InterlockedDecrement(&ref_);
        if (ref == 0) {
            if (real_ != nullptr) {
                real_->Release();
            }
            delete this;
        }
        return static_cast<ULONG>(ref);
    }

    HRESULT STDMETHODCALLTYPE CreateDevice(
        REFGUID guid,
        LPDIRECTINPUTDEVICE8W *out,
        LPUNKNOWN outer
    ) override {
        if (out == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        *out = nullptr;
        if (outer != nullptr) {
            return CLASS_E_NOAGGREGATION;
        }
        if (IsEqualGUID(guid, kVirtualGuid) || IsEqualGUID(guid, GUID_Joystick)) {
            auto *device = new (std::nothrow) VirtualDevice(&rumble_engine(), guid);
            if (device == nullptr) {
                return DIERR_OUTOFMEMORY;
            }
            *out = device;
            return DI_OK;
        }
        if (real_ != nullptr) {
            return real_->CreateDevice(guid, out, outer);
        }
        return DIERR_DEVICENOTREG;
    }

    HRESULT STDMETHODCALLTYPE EnumDevices(
        DWORD type,
        LPDIENUMDEVICESCALLBACKW callback,
        LPVOID ref,
        DWORD flags
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        EnumContext context{callback, ref, false};
        HRESULT result = DI_OK;
        if (real_ != nullptr) {
            result = real_->EnumDevices(type, forward_enum, &context, flags);
        }
        if (context.stop || !virtual_matches(type, flags)) {
            return result;
        }
        DIDEVICEINSTANCEW info{};
        info.dwSize = sizeof(info);
        info.guidInstance = kVirtualGuid;
        info.guidProduct = kProductGuid;
        info.dwDevType = DI8DEVTYPE_GAMEPAD
            | (DI8DEVTYPEGAMEPAD_STANDARD << 8);
        copy_wide(info.tszInstanceName, MAX_PATH, kDeviceName);
        copy_wide(info.tszProductName, MAX_PATH, kDeviceName);
        info.guidFFDriver = GUID_NULL;
        info.wUsagePage = 0x01;
        info.wUsage = 0x05;
        (void)callback(&info, ref);
        return result;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceStatus(REFGUID guid) override {
        if (IsEqualGUID(guid, kVirtualGuid) || IsEqualGUID(guid, GUID_Joystick)) {
            GamepadState state{};
            return read_gamepad(&state) ? DI_OK : DI_NOTATTACHED;
        }
        return real_ != nullptr ? real_->GetDeviceStatus(guid) : DI_NOTATTACHED;
    }

    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND owner, DWORD flags) override {
        return real_ != nullptr ? real_->RunControlPanel(owner, flags) : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE instance, DWORD version) override {
        return real_ != nullptr ? real_->Initialize(instance, version) : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE FindDevice(
        REFGUID guid,
        LPCWSTR name,
        LPGUID instance
    ) override {
        if (instance == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (IsEqualGUID(guid, GUID_Joystick) || IsEqualGUID(guid, kVirtualGuid)) {
            GamepadState state{};
            if (read_gamepad(&state) && (name == nullptr || wcscmp(name, kDeviceName) == 0)) {
                *instance = kVirtualGuid;
                return DI_OK;
            }
        }
        return real_ != nullptr
            ? real_->FindDevice(guid, name, instance)
            : DIERR_DEVICENOTREG;
    }

    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(
        LPCWSTR user,
        LPDIACTIONFORMATW format,
        LPDIENUMDEVICESBYSEMANTICSCBW callback,
        LPVOID ref,
        DWORD flags
    ) override {
        return real_ != nullptr
            ? real_->EnumDevicesBySemantics(user, format, callback, ref, flags)
            : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE ConfigureDevices(
        LPDICONFIGUREDEVICESCALLBACK callback,
        LPDICONFIGUREDEVICESPARAMSW params,
        DWORD flags,
        LPVOID ref
    ) override {
        return real_ != nullptr
            ? real_->ConfigureDevices(callback, params, flags, ref)
            : DI_OK;
    }

private:
    ~DirectInput8() noexcept = default;

    struct EnumContext {
        LPDIENUMDEVICESCALLBACKW callback;
        LPVOID ref;
        bool stop;
    };

    static BOOL CALLBACK forward_enum(
        LPCDIDEVICEINSTANCEW instance,
        LPVOID ref
    ) noexcept {
        auto *context = static_cast<EnumContext *>(ref);
        if (context == nullptr || context->callback == nullptr || instance == nullptr) {
            return DIENUM_CONTINUE;
        }
        if (context->callback(instance, context->ref) == DIENUM_STOP) {
            context->stop = true;
            return DIENUM_STOP;
        }
        return DIENUM_CONTINUE;
    }

    static bool virtual_matches(DWORD type, DWORD flags) noexcept {
        GamepadState state{};
        if (!read_gamepad(&state)) {
            return false;
        }
        if (type != DI8DEVCLASS_ALL && type != DI8DEVCLASS_GAMECTRL
            && type != DI8DEVTYPE_GAMEPAD && type != DI8DEVTYPE_JOYSTICK) {
            return false;
        }
        (void)flags;
        return true;
    }

    IDirectInput8W *real_{nullptr};
    LONG ref_{1};
};

void convert_device_instance(
    const DIDEVICEINSTANCEW &source,
    DIDEVICEINSTANCEA *target
) noexcept {
    if (target == nullptr) {
        return;
    }
    memset(target, 0, sizeof(*target));
    target->dwSize = sizeof(DIDEVICEINSTANCEA);
    target->guidInstance = source.guidInstance;
    target->guidProduct = source.guidProduct;
    target->dwDevType = source.dwDevType;
    copy_ansi_from_wide(target->tszInstanceName, MAX_PATH, source.tszInstanceName);
    copy_ansi_from_wide(target->tszProductName, MAX_PATH, source.tszProductName);
    target->guidFFDriver = source.guidFFDriver;
    target->wUsagePage = source.wUsagePage;
    target->wUsage = source.wUsage;
}

void convert_object_instance(
    const DIDEVICEOBJECTINSTANCEW &source,
    DIDEVICEOBJECTINSTANCEA *target
) noexcept {
    if (target == nullptr) {
        return;
    }
    memset(target, 0, sizeof(*target));
    target->dwSize = sizeof(DIDEVICEOBJECTINSTANCEA);
    target->guidType = source.guidType;
    target->dwOfs = source.dwOfs;
    target->dwType = source.dwType;
    target->dwFlags = source.dwFlags;
    copy_ansi_from_wide(target->tszName, MAX_PATH, source.tszName);
    target->wUsagePage = source.wUsagePage;
    target->wUsage = source.wUsage;
}

void convert_effect_info(
    const DIEFFECTINFOW &source,
    DIEFFECTINFOA *target
) noexcept {
    if (target == nullptr) {
        return;
    }
    memset(target, 0, sizeof(*target));
    target->dwSize = sizeof(DIEFFECTINFOA);
    target->guid = source.guid;
    target->dwEffType = source.dwEffType;
    target->dwStaticParams = source.dwStaticParams;
    target->dwDynamicParams = source.dwDynamicParams;
    copy_ansi_from_wide(target->tszName, MAX_PATH, source.tszName);
}

class VirtualDeviceA;

IDirectInputDevice8A *make_virtual_device_a(IDirectInputDevice8W *device) noexcept;

class DirectInput8A final : public IDirectInput8A {
public:
    DirectInput8A(IDirectInput8W *wide, IDirectInput8A *real) noexcept
        : wide_(wide), real_(real) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown)
            || IsEqualIID(riid, IID_IDirectInput8A)) {
            *out = static_cast<IDirectInput8A *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&ref_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG ref = InterlockedDecrement(&ref_);
        if (ref == 0) {
            if (wide_ != nullptr) {
                wide_->Release();
            }
            if (real_ != nullptr) {
                real_->Release();
            }
            delete this;
        }
        return static_cast<ULONG>(ref);
    }

    HRESULT STDMETHODCALLTYPE CreateDevice(
        REFGUID guid,
        LPDIRECTINPUTDEVICE8A *out,
        LPUNKNOWN outer
    ) override {
        if (out == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        *out = nullptr;
        if (outer != nullptr) {
            return CLASS_E_NOAGGREGATION;
        }
        if (IsEqualGUID(guid, kVirtualGuid) || IsEqualGUID(guid, GUID_Joystick)) {
            if (wide_ == nullptr) {
                return DIERR_NOTINITIALIZED;
            }
            IDirectInputDevice8W *device = nullptr;
            const HRESULT result = wide_->CreateDevice(guid, &device, nullptr);
            if (FAILED(result) || device == nullptr) {
                return result;
            }
            auto *adapter = make_virtual_device_a(device);
            if (adapter == nullptr) {
                return DIERR_OUTOFMEMORY;
            }
            *out = adapter;
            return DI_OK;
        }
        return real_ != nullptr
            ? real_->CreateDevice(guid, out, outer)
            : DIERR_DEVICENOTREG;
    }

    HRESULT STDMETHODCALLTYPE EnumDevices(
        DWORD type,
        LPDIENUMDEVICESCALLBACKA callback,
        LPVOID ref,
        DWORD flags
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DI_OK;
        }
        DeviceContext context{callback, ref, false};
        return wide_->EnumDevices(type, convert_device, &context, flags);
    }

    HRESULT STDMETHODCALLTYPE GetDeviceStatus(REFGUID guid) override {
        if (IsEqualGUID(guid, kVirtualGuid) || IsEqualGUID(guid, GUID_Joystick)) {
            return wide_ != nullptr ? wide_->GetDeviceStatus(guid) : DI_NOTATTACHED;
        }
        return real_ != nullptr ? real_->GetDeviceStatus(guid) : DI_NOTATTACHED;
    }

    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND owner, DWORD flags) override {
        return real_ != nullptr ? real_->RunControlPanel(owner, flags) : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Initialize(HINSTANCE instance, DWORD version) override {
        return real_ != nullptr ? real_->Initialize(instance, version) : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE FindDevice(
        REFGUID guid,
        LPCSTR name,
        LPGUID instance
    ) override {
        if (instance == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (IsEqualGUID(guid, GUID_Joystick) || IsEqualGUID(guid, kVirtualGuid)) {
            if (wide_ == nullptr) {
                return DIERR_NOTINITIALIZED;
            }
            wchar_t wide_name[260]{};
            const wchar_t *wide_name_ptr = nullptr;
            if (name != nullptr) {
                if (MultiByteToWideChar(CP_ACP, 0, name, -1,
                                        wide_name, 260) <= 0) {
                    return DIERR_INVALIDPARAM;
                }
                wide_name_ptr = wide_name;
            }
            return wide_->FindDevice(guid, wide_name_ptr, instance);
        }
        return real_ != nullptr
            ? real_->FindDevice(guid, name, instance)
            : DIERR_DEVICENOTREG;
    }

    HRESULT STDMETHODCALLTYPE EnumDevicesBySemantics(
        LPCSTR user,
        LPDIACTIONFORMATA format,
        LPDIENUMDEVICESBYSEMANTICSCBA callback,
        LPVOID ref,
        DWORD flags
    ) override {
        return real_ != nullptr
            ? real_->EnumDevicesBySemantics(user, format, callback, ref, flags)
            : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE ConfigureDevices(
        LPDICONFIGUREDEVICESCALLBACK callback,
        LPDICONFIGUREDEVICESPARAMSA params,
        DWORD flags,
        LPVOID ref
    ) override {
        return real_ != nullptr
            ? real_->ConfigureDevices(callback, params, flags, ref)
            : DI_OK;
    }

private:
    ~DirectInput8A() noexcept = default;

    struct DeviceContext {
        LPDIENUMDEVICESCALLBACKA callback;
        LPVOID ref;
        bool stop;
    };

    static BOOL CALLBACK convert_device(
        LPCDIDEVICEINSTANCEW instance,
        LPVOID ref
    ) noexcept {
        auto *context = static_cast<DeviceContext *>(ref);
        if (context == nullptr || context->callback == nullptr || instance == nullptr) {
            return DIENUM_CONTINUE;
        }
        DIDEVICEINSTANCEA converted{};
        convert_device_instance(*instance, &converted);
        if (context->callback(&converted, context->ref) == DIENUM_STOP) {
            context->stop = true;
            return DIENUM_STOP;
        }
        return DIENUM_CONTINUE;
    }

    IDirectInput8W *wide_{nullptr};
    IDirectInput8A *real_{nullptr};
    LONG ref_{1};
};

class VirtualDeviceA final : public IDirectInputDevice8A {
public:
    explicit VirtualDeviceA(IDirectInputDevice8W *wide) noexcept : wide_(wide) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out == nullptr) {
            return E_POINTER;
        }
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown)
            || IsEqualIID(riid, IID_IDirectInputDevice8A)) {
            *out = static_cast<IDirectInputDevice8A *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&ref_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const LONG ref = InterlockedDecrement(&ref_);
        if (ref == 0) {
            if (wide_ != nullptr) {
                wide_->Release();
            }
            delete this;
        }
        return static_cast<ULONG>(ref);
    }

    HRESULT STDMETHODCALLTYPE GetCapabilities(LPDIDEVCAPS caps) override {
        return wide_ != nullptr ? wide_->GetCapabilities(caps) : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE EnumObjects(
        LPDIENUMDEVICEOBJECTSCALLBACKA callback,
        LPVOID ref,
        DWORD flags
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        ObjectContext context{callback, ref, false};
        return wide_->EnumObjects(convert_object, &context, flags);
    }

    HRESULT STDMETHODCALLTYPE GetProperty(REFGUID property, LPDIPROPHEADER header) override {
        return wide_ != nullptr
            ? wide_->GetProperty(property, header)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SetProperty(REFGUID property, LPCDIPROPHEADER header) override {
        return wide_ != nullptr
            ? wide_->SetProperty(property, header)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE Acquire() override {
        return wide_ != nullptr ? wide_->Acquire() : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE Unacquire() override {
        return wide_ != nullptr ? wide_->Unacquire() : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceState(DWORD size, LPVOID data) override {
        return wide_ != nullptr
            ? wide_->GetDeviceState(size, data)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceData(
        DWORD object_size,
        LPDIDEVICEOBJECTDATA data,
        LPDWORD count,
        DWORD flags
    ) override {
        return wide_ != nullptr
            ? wide_->GetDeviceData(object_size, data, count, flags)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SetDataFormat(LPCDIDATAFORMAT format) override {
        return wide_ != nullptr
            ? wide_->SetDataFormat(format)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SetEventNotification(HANDLE event) override {
        return wide_ != nullptr
            ? wide_->SetEventNotification(event)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SetCooperativeLevel(HWND window, DWORD flags) override {
        return wide_ != nullptr
            ? wide_->SetCooperativeLevel(window, flags)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE GetObjectInfo(
        LPDIDEVICEOBJECTINSTANCEA object,
        DWORD id,
        DWORD how
    ) override {
        if (object == nullptr
            || object->dwSize < sizeof(DIDEVICEOBJECTINSTANCEA)) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        DIDEVICEOBJECTINSTANCEW wide{};
        wide.dwSize = sizeof(wide);
        const HRESULT result = wide_->GetObjectInfo(&wide, id, how);
        if (FAILED(result)) {
            return result;
        }
        convert_object_instance(wide, object);
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetDeviceInfo(LPDIDEVICEINSTANCEA info) override {
        if (info == nullptr || info->dwSize < sizeof(DIDEVICEINSTANCEA)) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        DIDEVICEINSTANCEW wide{};
        wide.dwSize = sizeof(wide);
        const HRESULT result = wide_->GetDeviceInfo(&wide);
        if (FAILED(result)) {
            return result;
        }
        convert_device_instance(wide, info);
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE RunControlPanel(HWND owner, DWORD flags) override {
        return wide_ != nullptr ? wide_->RunControlPanel(owner, flags) : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE Initialize(
        HINSTANCE instance,
        DWORD version,
        REFGUID guid
    ) override {
        return wide_ != nullptr
            ? wide_->Initialize(instance, version, guid)
            : DI_OK;
    }

    HRESULT STDMETHODCALLTYPE CreateEffect(
        REFGUID guid,
        LPCDIEFFECT effect,
        LPDIRECTINPUTEFFECT *out,
        LPUNKNOWN outer
    ) override {
        return wide_ != nullptr
            ? wide_->CreateEffect(guid, effect, out, outer)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE EnumEffects(
        LPDIENUMEFFECTSCALLBACKA callback,
        LPVOID ref,
        DWORD type
    ) override {
        if (callback == nullptr) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        EffectContext context{callback, ref, false};
        return wide_->EnumEffects(convert_effect, &context, type);
    }

    HRESULT STDMETHODCALLTYPE GetEffectInfo(
        LPDIEFFECTINFOA info,
        REFGUID guid
    ) override {
        if (info == nullptr || info->dwSize < sizeof(DIEFFECTINFOA)) {
            return DIERR_INVALIDPARAM;
        }
        if (wide_ == nullptr) {
            return DIERR_NOTINITIALIZED;
        }
        DIEFFECTINFOW wide{};
        wide.dwSize = sizeof(wide);
        const HRESULT result = wide_->GetEffectInfo(&wide, guid);
        if (FAILED(result)) {
            return result;
        }
        convert_effect_info(wide, info);
        return DI_OK;
    }

    HRESULT STDMETHODCALLTYPE GetForceFeedbackState(LPDWORD state) override {
        return wide_ != nullptr
            ? wide_->GetForceFeedbackState(state)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SendForceFeedbackCommand(DWORD command) override {
        return wide_ != nullptr
            ? wide_->SendForceFeedbackCommand(command)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE EnumCreatedEffectObjects(
        LPDIENUMCREATEDEFFECTOBJECTSCALLBACK callback,
        LPVOID ref,
        DWORD flags
    ) override {
        return wide_ != nullptr
            ? wide_->EnumCreatedEffectObjects(callback, ref, flags)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE Escape(LPDIEFFESCAPE escape) override {
        return wide_ != nullptr ? wide_->Escape(escape) : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE Poll() override {
        return wide_ != nullptr ? wide_->Poll() : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE SendDeviceData(
        DWORD object_size,
        LPCDIDEVICEOBJECTDATA data,
        LPDWORD count,
        DWORD flags
    ) override {
        return wide_ != nullptr
            ? wide_->SendDeviceData(object_size, data, count, flags)
            : DIERR_NOTINITIALIZED;
    }

    HRESULT STDMETHODCALLTYPE EnumEffectsInFile(
        LPCSTR file,
        LPDIENUMEFFECTSINFILECALLBACK callback,
        LPVOID ref,
        DWORD flags
    ) override {
        (void)file;
        (void)callback;
        (void)ref;
        (void)flags;
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE WriteEffectToFile(
        LPCSTR file,
        DWORD entries,
        LPDIFILEEFFECT effect,
        DWORD flags
    ) override {
        (void)file;
        (void)entries;
        (void)effect;
        (void)flags;
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE BuildActionMap(
        LPDIACTIONFORMATA format,
        LPCSTR user,
        DWORD flags
    ) override {
        (void)format;
        (void)user;
        (void)flags;
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE SetActionMap(
        LPDIACTIONFORMATA format,
        LPCSTR user,
        DWORD flags
    ) override {
        (void)format;
        (void)user;
        (void)flags;
        return DIERR_UNSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE GetImageInfo(LPDIDEVICEIMAGEINFOHEADERA info) override {
        (void)info;
        return DIERR_UNSUPPORTED;
    }

private:
    ~VirtualDeviceA() noexcept = default;

    struct ObjectContext {
        LPDIENUMDEVICEOBJECTSCALLBACKA callback;
        LPVOID ref;
        bool stop;
    };

    struct EffectContext {
        LPDIENUMEFFECTSCALLBACKA callback;
        LPVOID ref;
        bool stop;
    };

    static BOOL CALLBACK convert_object(
        LPCDIDEVICEOBJECTINSTANCEW instance,
        LPVOID ref
    ) noexcept {
        auto *context = static_cast<ObjectContext *>(ref);
        if (context == nullptr || context->callback == nullptr || instance == nullptr) {
            return DIENUM_CONTINUE;
        }
        DIDEVICEOBJECTINSTANCEA converted{};
        convert_object_instance(*instance, &converted);
        if (context->callback(&converted, context->ref) == DIENUM_STOP) {
            context->stop = true;
            return DIENUM_STOP;
        }
        return DIENUM_CONTINUE;
    }

    static BOOL CALLBACK convert_effect(
        LPCDIEFFECTINFOW info,
        LPVOID ref
    ) noexcept {
        auto *context = static_cast<EffectContext *>(ref);
        if (context == nullptr || context->callback == nullptr || info == nullptr) {
            return DIENUM_CONTINUE;
        }
        DIEFFECTINFOA converted{};
        convert_effect_info(*info, &converted);
        if (context->callback(&converted, context->ref) == DIENUM_STOP) {
            context->stop = true;
            return DIENUM_STOP;
        }
        return DIENUM_CONTINUE;
    }

    IDirectInputDevice8W *wide_{nullptr};
    LONG ref_{1};
};

IDirectInputDevice8A *make_virtual_device_a(IDirectInputDevice8W *device) noexcept {
    if (device == nullptr) {
        return nullptr;
    }
    auto *adapter = new (std::nothrow) VirtualDeviceA(device);
    if (adapter == nullptr) {
        device->Release();
        return nullptr;
    }
    return adapter;
}

using DirectInput8CreateFn = HRESULT (WINAPI *)(
    HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
using DllCanUnloadNowFn = HRESULT (WINAPI *)();
using DllGetClassObjectFn = HRESULT (WINAPI *)(REFCLSID, REFIID, LPVOID *);
using DllRegisterServerFn = HRESULT (WINAPI *)();
using DllUnregisterServerFn = HRESULT (WINAPI *)();

HMODULE real_module() noexcept {
    static HMODULE module = LoadLibraryA("dinput8_real.dll");
    return module;
}

template <typename Function>
Function real_symbol(const char *name) noexcept {
    HMODULE module = real_module();
    if (module == nullptr) {
        return nullptr;
    }
    FARPROC proc = GetProcAddress(module, name);
    if (proc == nullptr) {
        return nullptr;
    }
    Function function = nullptr;
    static_assert(sizeof(function) == sizeof(proc), "unexpected function pointer size");
    memcpy(&function, &proc, sizeof(function));
    return function;
}

HRESULT create_real(REFIID riid, LPVOID *out) noexcept {
    const auto create = real_symbol<DirectInput8CreateFn>("DirectInput8Create");
    if (create == nullptr) {
        return DIERR_NOTINITIALIZED;
    }
    return create(GetModuleHandleA(nullptr), DIRECTINPUT_VERSION, riid, out, nullptr);
}

}  // namespace

extern "C" HRESULT WINAPI DirectInput8Create(
    HINSTANCE instance,
    DWORD version,
    REFIID riid,
    LPVOID *out,
    LPUNKNOWN outer
) {
    (void)instance;
    (void)version;
    if (out == nullptr) {
        return E_POINTER;
    }
    *out = nullptr;
    if (outer != nullptr) {
        return CLASS_E_NOAGGREGATION;
    }
    if (IsEqualIID(riid, IID_IDirectInput8W)) {
        IDirectInput8W *real = nullptr;
        const HRESULT real_result = create_real(IID_IDirectInput8W,
                                                reinterpret_cast<LPVOID *>(&real));
        (void)real_result;
        auto *proxy = new (std::nothrow) DirectInput8(real);
        if (proxy == nullptr) {
            if (real != nullptr) {
                real->Release();
            }
            return DIERR_OUTOFMEMORY;
        }
        *out = static_cast<IDirectInput8W *>(proxy);
        return DI_OK;
    }
    if (IsEqualIID(riid, IID_IDirectInput8A)) {
        IDirectInput8W *real_wide = nullptr;
        IDirectInput8A *real_ansi = nullptr;
        create_real(IID_IDirectInput8W, reinterpret_cast<LPVOID *>(&real_wide));
        create_real(IID_IDirectInput8A, reinterpret_cast<LPVOID *>(&real_ansi));
        auto *wide = new (std::nothrow) DirectInput8(real_wide);
        if (wide == nullptr) {
            if (real_wide != nullptr) {
                real_wide->Release();
            }
            if (real_ansi != nullptr) {
                real_ansi->Release();
            }
            return DIERR_OUTOFMEMORY;
        }
        auto *proxy = new (std::nothrow) DirectInput8A(wide, real_ansi);
        if (proxy == nullptr) {
            wide->Release();
            if (real_ansi != nullptr) {
                real_ansi->Release();
            }
            return DIERR_OUTOFMEMORY;
        }
        *out = static_cast<IDirectInput8A *>(proxy);
        return DI_OK;
    }
    return E_NOINTERFACE;
}

extern "C" HRESULT WINAPI DllCanUnloadNow() {
    const auto function = real_symbol<DllCanUnloadNowFn>("DllCanUnloadNow");
    return function != nullptr ? function() : S_FALSE;
}

extern "C" HRESULT WINAPI DllGetClassObject(
    REFCLSID clsid,
    REFIID riid,
    LPVOID *out
) {
    const auto function = real_symbol<DllGetClassObjectFn>("DllGetClassObject");
    return function != nullptr
        ? function(clsid, riid, out)
        : CLASS_E_CLASSNOTAVAILABLE;
}

extern "C" HRESULT WINAPI DllRegisterServer() {
    const auto function = real_symbol<DllRegisterServerFn>("DllRegisterServer");
    return function != nullptr ? function() : S_OK;
}

extern "C" HRESULT WINAPI DllUnregisterServer() {
    const auto function = real_symbol<DllUnregisterServerFn>("DllUnregisterServer");
    return function != nullptr ? function() : S_OK;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
    } else if (reason == DLL_PROCESS_DETACH) {
        rumble_engine().shutdown();
    }
    return TRUE;
}
