mod touch;

use std::ffi::{c_char, c_int, c_void, CString};
use std::io::{self, Read};
use std::os::raw::c_uint;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use vulcan_input_proto::{
    Event, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT, BTN_DPAD_UP, BTN_EAST, BTN_MISC,
    BTN_MODE, BTN_NORTH, BTN_SELECT, BTN_SOUTH, BTN_START, BTN_TASK, BTN_THUMBL, BTN_THUMBR,
    BTN_TL, BTN_TR, BTN_WEST, EV_ABS, EV_KEY, EV_REL, EV_SYN, KIND_GAMEPAD, KIND_KEYBOARD,
    KIND_MOUSE, KIND_MOUSE_ABSOLUTE, KIND_PEN, KIND_TOUCH, REL_HWHEEL, REL_WHEEL, REL_X, REL_Y,
    SYN_REPORT,
};

const EI_EVENT_CONNECT: c_int = 1;
const EI_EVENT_DISCONNECT: c_int = 2;
const EI_EVENT_SEAT_ADDED: c_int = 3;
const EI_EVENT_DEVICE_ADDED: c_int = 5;
const EI_EVENT_DEVICE_REMOVED: c_int = 6;
const EI_EVENT_DEVICE_PAUSED: c_int = 7;
const EI_EVENT_DEVICE_RESUMED: c_int = 8;

const EI_DEVICE_CAP_POINTER: c_uint = 1 << 0;
const EI_DEVICE_CAP_POINTER_ABSOLUTE: c_uint = 1 << 1;
const EI_DEVICE_CAP_KEYBOARD: c_uint = 1 << 2;
const EI_DEVICE_CAP_TOUCH: c_uint = 1 << 3;
const EI_DEVICE_CAP_SCROLL: c_uint = 1 << 4;
const EI_DEVICE_CAP_BUTTON: c_uint = 1 << 5;

const GAMEPAD_MAGIC: u32 = 0x5647_5031;

#[repr(C)]
struct GamepadState {
    magic: u32,
    sequence: u32,
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    thumb_lx: i16,
    thumb_ly: i16,
    thumb_rx: i16,
    thumb_ry: i16,
    connected: u8,
    padding: [u8; 7],
}

#[repr(C)]
struct ei {
    _private: [u8; 0],
}
#[repr(C)]
struct ei_event {
    _private: [u8; 0],
}
#[repr(C)]
struct ei_seat {
    _private: [u8; 0],
}
#[repr(C)]
struct ei_device {
    _private: [u8; 0],
}
#[repr(C)]
struct ei_touch {
    _private: [u8; 0],
}

#[link(name = "ei")]
extern "C" {
    fn ei_new_sender(user_data: *mut c_void) -> *mut ei;
    fn ei_setup_backend_socket(context: *mut ei, socket_path: *const c_char) -> c_int;
    fn ei_get_fd(context: *mut ei) -> c_int;
    fn ei_dispatch(context: *mut ei);
    fn ei_get_event(context: *mut ei) -> *mut ei_event;
    fn ei_event_get_type(event: *mut ei_event) -> c_int;
    fn ei_event_get_seat(event: *mut ei_event) -> *mut ei_seat;
    fn ei_event_get_device(event: *mut ei_event) -> *mut ei_device;
    fn ei_event_unref(event: *mut ei_event);
    fn ei_seat_bind_capabilities(seat: *mut ei_seat, ...);
    fn ei_device_ref(device: *mut ei_device) -> *mut ei_device;
    fn ei_device_unref(device: *mut ei_device);
    fn ei_device_start_emulating(device: *mut ei_device, sequence: u32);
    fn ei_device_frame(device: *mut ei_device, time: u64);
    fn ei_device_pointer_motion(device: *mut ei_device, x: f64, y: f64);
    fn ei_device_pointer_motion_absolute(device: *mut ei_device, x: f64, y: f64);
    fn ei_device_button_button(device: *mut ei_device, button: u32, is_press: bool);
    fn ei_device_scroll_discrete(device: *mut ei_device, x: i32, y: i32);
    fn ei_device_keyboard_key(device: *mut ei_device, key: u32, is_press: bool);
    fn ei_device_has_capability(device: *mut ei_device, capability: c_uint) -> bool;
    fn ei_device_touch_new(device: *mut ei_device) -> *mut ei_touch;
    fn ei_touch_down(touch: *mut ei_touch, x: f64, y: f64);
    fn ei_touch_motion(touch: *mut ei_touch, x: f64, y: f64);
    fn ei_touch_up(touch: *mut ei_touch);
    fn ei_touch_unref(touch: *mut ei_touch);
    fn ei_now(context: *mut ei) -> u64;
    fn ei_unref(context: *mut ei);
}

/// Emulation state the EIS server allows for the device.
///
/// libei discards every event while the device is paused, so events are only
/// sent after the server confirms the resume. libei expects the client to
/// answer `EI_EVENT_DEVICE_RESUMED` with `ei_device_start_emulating`, which is
/// why a request sent before the resume does not count as the answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Emulation {
    active: bool,
    requested: bool,
    answered: bool,
}

/// Follow-up work required by an emulation state change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EmulationAction {
    None,
    StartEmulating,
}

impl Emulation {
    fn paused() -> Self {
        Self {
            active: false,
            requested: false,
            answered: false,
        }
    }

    fn active(self) -> bool {
        self.active
    }

    /// Applies one EIS device event.
    ///
    /// Every resume gets exactly one answer even when the client already asked
    /// for it, because the server only accepts events after the answer.
    fn on_event(&mut self, event_type: c_int) -> EmulationAction {
        match event_type {
            EI_EVENT_DEVICE_RESUMED => {
                self.active = true;
                self.requested = false;
                if self.answered {
                    EmulationAction::None
                } else {
                    self.answered = true;
                    EmulationAction::StartEmulating
                }
            }
            EI_EVENT_DEVICE_PAUSED => {
                self.active = false;
                self.requested = false;
                self.answered = false;
                EmulationAction::None
            }
            EI_EVENT_DEVICE_REMOVED | EI_EVENT_DISCONNECT => {
                self.active = false;
                self.requested = false;
                self.answered = false;
                EmulationAction::None
            }
            _ => EmulationAction::None,
        }
    }

    /// Requests emulation unless a request is pending or already answered.
    fn request(&mut self) -> EmulationAction {
        if self.active || self.requested || self.answered {
            return EmulationAction::None;
        }
        self.requested = true;
        EmulationAction::StartEmulating
    }
}

struct Backend {
    context: *mut ei,
    device: *mut ei_device,
    sequence: u32,
    emulation: Emulation,
    last_attempt: Option<Instant>,
    last_wait_log: Option<Instant>,
    absolute_x: i32,
    absolute_y: i32,
    touch_capable: bool,
    touches: [*mut ei_touch; touch::MAX_SLOTS],
    tracker: touch::Tracker,
    gamepad: GamepadState,
    gamepad_path: PathBuf,
    gamepad_enabled: bool,
}

impl Backend {
    fn new() -> Self {
        let gamepad_path = std::env::var("VULCAN_GAMEPAD_STATE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from("/data/prefix/drive_c/vulcan-gamepad.bin")
            });
        let gamepad_enabled = gamepad_enabled(std::env::var("INPUT_GAMEPAD").ok().as_deref());
        let backend = Self {
            context: std::ptr::null_mut(),
            device: std::ptr::null_mut(),
            sequence: 0,
            emulation: Emulation::paused(),
            last_attempt: None,
            last_wait_log: None,
            absolute_x: 0,
            absolute_y: 0,
            touch_capable: false,
            touches: [std::ptr::null_mut(); touch::MAX_SLOTS],
            tracker: touch::Tracker::new(),
            gamepad: GamepadState {
                magic: GAMEPAD_MAGIC,
                sequence: 0,
                buttons: 0,
                left_trigger: 0,
                right_trigger: 0,
                thumb_lx: 0,
                thumb_ly: 0,
                thumb_rx: 0,
                thumb_ry: 0,
                connected: 1,
                padding: [0; 7],
            },
            gamepad_path,
            gamepad_enabled,
        };
        if gamepad_enabled {
            backend.write_gamepad();
        }
        backend
    }

    fn write_gamepad(&self) {
        if let Some(parent) = self.gamepad_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let tmp = self.gamepad_path.with_extension("tmp");
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&self.gamepad as *const GamepadState).cast::<u8>(),
                std::mem::size_of::<GamepadState>(),
            )
        };
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &self.gamepad_path);
        }
    }

    fn handle_gamepad(&mut self, event: Event) {
        if apply_gamepad_event(&mut self.gamepad, event) {
            self.write_gamepad();
        }
    }

    fn reset(&mut self) {
        self.release_touches();
        if !self.device.is_null() {
            unsafe { ei_device_unref(self.device) };
            self.device = std::ptr::null_mut();
        }
        if !self.context.is_null() {
            unsafe { ei_unref(self.context) };
            self.context = std::ptr::null_mut();
        }
        self.emulation = Emulation::paused();
        self.tracker = touch::Tracker::new();
    }

    /// Drops the touch objects owned by the current EIS device.
    fn release_touches(&mut self) {
        for touch in &mut self.touches {
            if !touch.is_null() {
                unsafe { ei_touch_unref(*touch) };
                *touch = std::ptr::null_mut();
            }
        }
        self.touch_capable = false;
    }

    fn ready(&self) -> bool {
        !self.device.is_null()
    }

    fn log_wait(&mut self, message: &str) {
        if let Some(last) = self.last_wait_log {
            if last.elapsed() < Duration::from_secs(5) {
                return;
            }
        }
        self.last_wait_log = Some(Instant::now());
        eprintln!("[vulcan-inputd] {message}");
    }

    fn ensure_connected(&mut self) -> bool {
        if self.ready() {
            self.pump();
            if !self.emulation.active() {
                self.request_emulation();
            }
            return self.emulation.active();
        }
        if let Some(last) = self.last_attempt {
            if last.elapsed() < Duration::from_millis(250) {
                return false;
            }
        }
        self.last_attempt = Some(Instant::now());

        let Some(socket) = find_eis_socket() else {
            self.log_wait("waiting for gamescope EIS socket");
            return false;
        };
        let Ok(socket) = CString::new(socket.to_string_lossy().as_bytes()) else {
            return false;
        };

        if self.context.is_null() {
            self.context = unsafe { ei_new_sender(std::ptr::null_mut()) };
            if self.context.is_null() {
                return false;
            }
            if unsafe { ei_setup_backend_socket(self.context, socket.as_ptr()) } != 0 {
                self.log_wait("cannot open gamescope EIS socket");
                self.reset();
                return false;
            }
        }

        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline && !self.emulation.active() {
            self.request_emulation();
            if !self.poll_eis(Duration::from_millis(20)) {
                self.reset();
                return false;
            }
        }

        if self.emulation.active() {
            eprintln!("[vulcan-inputd] connected to gamescope EIS");
        }
        self.emulation.active()
    }

    /// Read and dispatch whatever libei has queued.
    fn poll_eis(&mut self, timeout: Duration) -> bool {
        let fd = unsafe { ei_get_fd(self.context) };
        if fd < 0 {
            return false;
        }

        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut poll_fd, 1, timeout.as_millis() as c_int) };
        if result < 0 {
            return io::Error::last_os_error().kind() == io::ErrorKind::Interrupted;
        }
        if result == 0 {
            return true;
        }

        unsafe { ei_dispatch(self.context) };
        self.dispatch_events();
        true
    }

    /// Drain events queued by the server before the next input is sent.
    ///
    /// A pause and the following resume both arrive as events, so they have to
    /// be read outside the connection attempt as well.
    fn pump(&mut self) {
        if !self.poll_eis(Duration::from_millis(0)) {
            self.reset();
        }
    }

    fn dispatch_events(&mut self) {
        // A disconnect or device removal resets the context mid-loop; reading
        // further events then would pass a null pointer to libei.
        while !self.context.is_null() {
            let event = unsafe { ei_get_event(self.context) };
            if event.is_null() {
                break;
            }
            let event_type = unsafe { ei_event_get_type(event) };
            match event_type {
                EI_EVENT_CONNECT => {}
                EI_EVENT_SEAT_ADDED => {
                    let seat = unsafe { ei_event_get_seat(event) };
                    if !seat.is_null() {
                        unsafe {
                            ei_seat_bind_capabilities(
                                seat,
                                EI_DEVICE_CAP_POINTER,
                                EI_DEVICE_CAP_POINTER_ABSOLUTE,
                                EI_DEVICE_CAP_TOUCH,
                                EI_DEVICE_CAP_BUTTON,
                                EI_DEVICE_CAP_SCROLL,
                                EI_DEVICE_CAP_KEYBOARD,
                                std::ptr::null::<c_void>(),
                            );
                        }
                    }
                }
                EI_EVENT_DEVICE_ADDED => {
                    if self.device.is_null() {
                        let device = unsafe { ei_event_get_device(event) };
                        if !device.is_null() {
                            self.device = unsafe { ei_device_ref(device) };
                            self.touch_capable =
                                unsafe { ei_device_has_capability(device, EI_DEVICE_CAP_TOUCH) };
                            eprintln!("[vulcan-inputd] EIS device added {device:p}");
                        }
                    } else {
                        let device = unsafe { ei_event_get_device(event) };
                        eprintln!("[vulcan-inputd] EIS extra device ignored {device:p}");
                    }
                }
                EI_EVENT_DEVICE_RESUMED => {
                    let device = unsafe { ei_event_get_device(event) };
                    if !device.is_null() && device != self.device {
                        eprintln!("[vulcan-inputd] EIS resume for untracked device {device:p}");
                    }
                    let was_active = self.emulation.active();
                    if self.emulation.on_event(event_type) == EmulationAction::StartEmulating {
                        self.start_emulating();
                    }
                    if !was_active {
                        eprintln!("[vulcan-inputd] EIS device emulating {device:p}");
                    }
                }
                EI_EVENT_DEVICE_PAUSED => {
                    let device = unsafe { ei_event_get_device(event) };
                    let was_active = self.emulation.active();
                    self.emulation.on_event(event_type);
                    if was_active {
                        eprintln!("[vulcan-inputd] EIS device paused {device:p}");
                    }
                }
                EI_EVENT_DEVICE_REMOVED | EI_EVENT_DISCONNECT => self.reset(),
                _ => {}
            }
            unsafe { ei_event_unref(event) };
        }
    }

    /// Requests emulation when the device has no pending request.
    fn request_emulation(&mut self) -> bool {
        if self.device.is_null() {
            return false;
        }
        if self.emulation.request() == EmulationAction::StartEmulating {
            self.start_emulating();
            return true;
        }
        false
    }

    fn start_emulating(&mut self) {
        if self.device.is_null() {
            return;
        }
        self.sequence = self.sequence.wrapping_add(1);
        eprintln!(
            "[vulcan-inputd] EIS start emulating seq {} device {:p}",
            self.sequence, self.device
        );
        unsafe { ei_device_start_emulating(self.device, self.sequence) };
    }

    fn frame(&self) {
        if self.ready() {
            unsafe { ei_device_frame(self.device, ei_now(self.context)) };
        }
    }

    fn handle(&mut self, event: Event) {
        if event.kind == KIND_PEN {
            return;
        }
        if event.kind == KIND_TOUCH {
            self.handle_touch(event);
            return;
        }
        if event.kind == KIND_GAMEPAD {
            if self.gamepad_enabled {
                self.handle_gamepad(event);
            }
            return;
        }
        if !self.ensure_connected() {
            return;
        }
        let device = self.device;
        if device.is_null() {
            return;
        }

        match event.kind {
            KIND_KEYBOARD => match event.event_type {
                EV_KEY => unsafe {
                    ei_device_keyboard_key(device, event.code as u32, event.value != 0)
                },
                EV_SYN if event.code == SYN_REPORT => self.frame(),
                _ => {}
            },
            KIND_MOUSE => match event.event_type {
                EV_REL if event.code == REL_X => unsafe {
                    ei_device_pointer_motion(device, f64::from(event.value), 0.0)
                },
                EV_REL if event.code == REL_Y => unsafe {
                    ei_device_pointer_motion(device, 0.0, f64::from(event.value))
                },
                EV_REL if event.code == REL_WHEEL => unsafe {
                    ei_device_scroll_discrete(device, 0, event.value.saturating_mul(120))
                },
                EV_REL if event.code == REL_HWHEEL => unsafe {
                    ei_device_scroll_discrete(device, event.value.saturating_mul(120), 0)
                },
                EV_KEY if (BTN_MISC..=BTN_TASK).contains(&event.code) => unsafe {
                    ei_device_button_button(device, event.code as u32, event.value != 0)
                },
                EV_SYN if event.code == SYN_REPORT => self.frame(),
                _ => {}
            },
            KIND_MOUSE_ABSOLUTE => match event.event_type {
                EV_ABS => {
                    if event.code == vulcan_input_proto::ABS_X {
                        self.absolute_x = event.value;
                    } else if event.code == vulcan_input_proto::ABS_Y {
                        self.absolute_y = event.value;
                    }
                }
                EV_KEY if (BTN_MISC..=BTN_TASK).contains(&event.code) => unsafe {
                    ei_device_button_button(device, event.code as u32, event.value != 0)
                },
                EV_SYN if event.code == SYN_REPORT => {
                    unsafe {
                        ei_device_pointer_motion_absolute(
                            device,
                            f64::from(self.absolute_x),
                            f64::from(self.absolute_y),
                        )
                    };
                    self.frame();
                }
                _ => {}
            },
            _ => {}
        }
    }

    /// Applies one touch event and sends the completed libei frame.
    fn handle_touch(&mut self, event: Event) {
        if !self.touch_capable || !self.ensure_connected() {
            return;
        }
        let device = self.device;
        if device.is_null() {
            return;
        }

        let mut actions = Vec::new();
        self.tracker.feed(event, &mut actions);
        for action in actions {
            match action {
                touch::TouchAction::Down { slot, x, y } => {
                    let new_touch = unsafe { ei_device_touch_new(device) };
                    if !new_touch.is_null() {
                        unsafe { ei_touch_down(new_touch, x, y) };
                        self.touches[slot] = new_touch;
                    }
                }
                touch::TouchAction::Motion { slot, x, y } => {
                    let active = self.touches[slot];
                    if !active.is_null() {
                        unsafe { ei_touch_motion(active, x, y) };
                    }
                }
                touch::TouchAction::Up { slot } => {
                    let finished =
                        std::mem::replace(&mut self.touches[slot], std::ptr::null_mut());
                    if !finished.is_null() {
                        unsafe {
                            ei_touch_up(finished);
                            ei_touch_unref(finished);
                        }
                    }
                }
            }
        }

        if event.event_type == EV_SYN && event.code == SYN_REPORT {
            self.frame();
        }
    }
}

fn apply_gamepad_event(state: &mut GamepadState, event: Event) -> bool {
    match event.event_type {
        EV_KEY => {
            if let Some(button) = gamepad_button(event.code) {
                if event.value != 0 {
                    state.buttons |= button;
                } else {
                    state.buttons &= !button;
                }
            }
        }
        EV_ABS => match event.code {
            vulcan_input_proto::ABS_X => state.thumb_lx = stick(event.value),
            // evdev Y grows downward; XInput thumbs grow upward.
            vulcan_input_proto::ABS_Y => state.thumb_ly = stick(event.value).saturating_neg(),
            vulcan_input_proto::ABS_RX => state.thumb_rx = stick(event.value),
            vulcan_input_proto::ABS_RY => state.thumb_ry = stick(event.value).saturating_neg(),
            vulcan_input_proto::ABS_Z => {
                state.left_trigger = event.value.clamp(0, 255) as u8
            }
            vulcan_input_proto::ABS_RZ => {
                state.right_trigger = event.value.clamp(0, 255) as u8
            }
            vulcan_input_proto::ABS_HAT0X => {
                state.buttons &= !(0x0004 | 0x0008);
                if event.value < 0 {
                    state.buttons |= 0x0004;
                } else if event.value > 0 {
                    state.buttons |= 0x0008;
                }
            }
            vulcan_input_proto::ABS_HAT0Y => {
                state.buttons &= !(0x0001 | 0x0002);
                if event.value < 0 {
                    state.buttons |= 0x0001;
                } else if event.value > 0 {
                    state.buttons |= 0x0002;
                }
            }
            _ => {}
        },
        EV_SYN if event.code == SYN_REPORT => {
            state.sequence = state.sequence.wrapping_add(1);
            state.connected = 1;
            return true;
        }
        _ => {}
    }
    false
}

/// The proxy is enabled unless explicitly disabled.
fn gamepad_enabled(value: Option<&str>) -> bool {
    value.map(|value| value != "0").unwrap_or(true)
}

fn stick(value: i32) -> i16 {
    value.clamp(i16::MIN as i32, i16::MAX as i32) as i16
}

fn gamepad_button(code: u16) -> Option<u16> {
    Some(match code {
        BTN_SOUTH => 0x1000,
        BTN_EAST => 0x2000,
        BTN_NORTH => 0x4000,
        BTN_WEST => 0x8000,
        BTN_TL => 0x0100,
        BTN_TR => 0x0200,
        BTN_SELECT => 0x0020,
        BTN_START => 0x0010,
        BTN_MODE => 0x0400,
        BTN_THUMBL => 0x0040,
        BTN_THUMBR => 0x0080,
        BTN_DPAD_UP => 0x0001,
        BTN_DPAD_DOWN => 0x0002,
        BTN_DPAD_LEFT => 0x0004,
        BTN_DPAD_RIGHT => 0x0008,
        _ => return None,
    })
}

fn socket_is_live(path: &Path) -> bool {
    path.symlink_metadata()
        .map(|meta| meta.file_type().is_socket())
        .unwrap_or(false)
}

fn find_eis_socket() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("VULCAN_EIS_SOCKET") {
        let path = PathBuf::from(path);
        if socket_is_live(&path) {
            return Some(path);
        }
    }

    if let Ok(entries) = std::fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(pid) = name.to_str() else { continue };
            if !pid.bytes().all(|byte| byte.is_ascii_digit()) {
                continue;
            }
            let environ = entry.path().join("environ");
            let Ok(bytes) = std::fs::read(&environ) else {
                continue;
            };
            for variable in bytes.split(|byte| *byte == 0) {
                let Some(value) = variable.strip_prefix(b"LIBEI_SOCKET=") else {
                    continue;
                };
                let value = String::from_utf8_lossy(value);
                let path = PathBuf::from(value.as_ref());
                if path.is_absolute() && socket_is_live(&path) {
                    return Some(path);
                }
                let Ok(cwd) = std::fs::read_link(entry.path().join("cwd")) else {
                    continue;
                };
                let path = cwd.join(path);
                if socket_is_live(&path) {
                    return Some(path);
                }
            }
        }
    }

    let mut candidates = Vec::new();
    if let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") {
        candidates.push(PathBuf::from(runtime));
    }
    candidates.push(PathBuf::from("/run/user/1000"));
    candidates.push(PathBuf::from("/games/zzz"));
    candidates.push(PathBuf::from("/tmp"));

    for directory in candidates {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with("-ei"))
                && socket_is_live(&path)
            {
                return Some(path);
            }
        }
    }

    None
}

fn serve(mut stream: UnixStream, backend: &mut Backend) {
    let mut bytes = [0u8; vulcan_input_proto::WIRE_LEN];
    loop {
        match stream.read_exact(&mut bytes) {
            Ok(()) => backend.handle(Event::from_bytes(&bytes)),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gamepad_state_layout_matches_proxy() {
        assert_eq!(std::mem::size_of::<GamepadState>(), 28);
        assert_eq!(GAMEPAD_MAGIC, 0x5647_5031);
    }

    fn test_state() -> GamepadState {
        GamepadState {
            magic: GAMEPAD_MAGIC,
            sequence: 0,
            buttons: 0,
            left_trigger: 0,
            right_trigger: 0,
            thumb_lx: 0,
            thumb_ly: 0,
            thumb_rx: 0,
            thumb_ry: 0,
            connected: 1,
            padding: [0; 7],
        }
    }

    #[test]
    fn gamepad_buttons_map_to_xinput() {
        assert_eq!(gamepad_button(BTN_SOUTH), Some(0x1000));
        assert_eq!(gamepad_button(BTN_EAST), Some(0x2000));
        assert_eq!(gamepad_button(BTN_NORTH), Some(0x4000));
        assert_eq!(gamepad_button(BTN_WEST), Some(0x8000));
        assert_eq!(gamepad_button(BTN_DPAD_UP), Some(0x0001));
        assert_eq!(gamepad_button(0x999), None);
    }

    #[test]
    fn eis_request_is_answered_once_after_the_resume() {
        let mut emulation = Emulation::paused();
        assert_eq!(emulation.request(), EmulationAction::StartEmulating);
        assert_eq!(emulation.request(), EmulationAction::None);
        assert!(!emulation.active());
        assert_eq!(
            emulation.on_event(EI_EVENT_DEVICE_RESUMED),
            EmulationAction::StartEmulating
        );
        assert!(emulation.active());
        assert_eq!(
            emulation.on_event(EI_EVENT_DEVICE_RESUMED),
            EmulationAction::None
        );
    }

    #[test]
    fn eis_pause_blocks_events_until_the_next_resume() {
        let mut emulation = Emulation::paused();
        emulation.request();
        emulation.on_event(EI_EVENT_DEVICE_RESUMED);
        assert_eq!(
            emulation.on_event(EI_EVENT_DEVICE_PAUSED),
            EmulationAction::None
        );
        assert!(!emulation.active());
        assert_eq!(emulation.request(), EmulationAction::StartEmulating);
        assert_eq!(
            emulation.on_event(EI_EVENT_DEVICE_RESUMED),
            EmulationAction::StartEmulating
        );
        assert!(emulation.active());
    }

    #[test]
    fn eis_resume_without_request_starts_emulation() {
        let mut emulation = Emulation::paused();
        assert_eq!(
            emulation.on_event(EI_EVENT_DEVICE_RESUMED),
            EmulationAction::StartEmulating
        );
        assert!(emulation.active());
    }

    #[test]
    fn eis_disconnect_pauses_emulation() {
        let mut emulation = Emulation::paused();
        emulation.request();
        emulation.on_event(EI_EVENT_DEVICE_RESUMED);
        assert_eq!(
            emulation.on_event(EI_EVENT_DISCONNECT),
            EmulationAction::None
        );
        assert!(!emulation.active());
        assert_eq!(emulation.request(), EmulationAction::StartEmulating);
    }

    #[test]
    fn gamepad_is_enabled_unless_explicitly_disabled() {
        assert!(gamepad_enabled(None));
        assert!(gamepad_enabled(Some("1")));
        assert!(!gamepad_enabled(Some("0")));
    }

    #[test]
    fn stick_y_is_inverted_for_xinput() {
        let mut state = test_state();
        assert!(!apply_gamepad_event(
            &mut state,
            Event {
                kind: KIND_GAMEPAD,
                event_type: EV_ABS,
                code: vulcan_input_proto::ABS_Y,
                value: 1000,
            }
        ));
        assert_eq!(state.thumb_ly, -1000);
        apply_gamepad_event(
            &mut state,
            Event {
                kind: KIND_GAMEPAD,
                event_type: EV_ABS,
                code: vulcan_input_proto::ABS_RY,
                value: -500,
            },
        );
        assert_eq!(state.thumb_ry, 500);
    }

    #[test]
    fn hat_axes_map_to_dpad_buttons() {
        let mut state = test_state();
        apply_gamepad_event(
            &mut state,
            Event {
                kind: KIND_GAMEPAD,
                event_type: EV_ABS,
                code: vulcan_input_proto::ABS_HAT0X,
                value: -1,
            },
        );
        assert_eq!(state.buttons & 0x0004, 0x0004);
        apply_gamepad_event(
            &mut state,
            Event {
                kind: KIND_GAMEPAD,
                event_type: EV_ABS,
                code: vulcan_input_proto::ABS_HAT0X,
                value: 1,
            },
        );
        assert_eq!(state.buttons & 0x0004, 0);
        assert_eq!(state.buttons & 0x0008, 0x0008);
        apply_gamepad_event(
            &mut state,
            Event {
                kind: KIND_GAMEPAD,
                event_type: EV_ABS,
                code: vulcan_input_proto::ABS_HAT0Y,
                value: -1,
            },
        );
        assert_eq!(state.buttons & 0x0001, 0x0001);
    }
}

fn main() -> io::Result<()> {
    let socket_path = std::env::var("VULCAN_INPUT_SOCKET").unwrap_or_else(|_| {
        let runtime = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| "/run/user/1000".to_string());
        format!("{runtime}/vulcan-input.sock")
    });
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))?;

    eprintln!("[vulcan-inputd] listening on {socket_path}");
    let mut backend = Backend::new();
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => serve(stream, &mut backend),
            Err(error) => eprintln!("[vulcan-inputd] accept: {error}"),
        }
    }
    Ok(())
}
