#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

mod touch;

use std::ffi::{c_char, c_int, c_void, CString};
use std::io::{self, Read};
use std::os::raw::c_uint;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use vulcan_input_proto::{
    Event, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT, BTN_DPAD_UP, BTN_EAST, BTN_MISC,
    BTN_MODE, BTN_NORTH, BTN_SELECT, BTN_SOUTH, BTN_START, BTN_TASK, BTN_THUMBL, BTN_THUMBR,
    BTN_TL, BTN_TR, BTN_WEST, EV_ABS, EV_KEY, EV_REL, EV_SYN, KIND_GAMEPAD,
    KIND_GAMEPAD_CONNECT, KIND_GAMEPAD_DISCONNECT, KIND_KEYBOARD,
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

/// Byte length of the gamepad record read by the XInput DLL.
const GAMEPAD_STATE_LEN: usize = 28;

#[derive(Debug, Eq, PartialEq)]
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
}

impl GamepadState {
    /// Serializes the record consumed by `native/xinput1_4.c`.
    ///
    /// The field order and the seven trailing zero bytes mirror
    /// `vulcan_gamepad_state_t`; the format is little-endian so it does not
    /// depend on the layout the compiler picks for this struct.
    fn to_bytes(&self) -> [u8; GAMEPAD_STATE_LEN] {
        let mut out = [0u8; GAMEPAD_STATE_LEN];
        out[0..4].copy_from_slice(&self.magic.to_le_bytes());
        out[4..8].copy_from_slice(&self.sequence.to_le_bytes());
        out[8..10].copy_from_slice(&self.buttons.to_le_bytes());
        out[10] = self.left_trigger;
        out[11] = self.right_trigger;
        out[12..14].copy_from_slice(&self.thumb_lx.to_le_bytes());
        out[14..16].copy_from_slice(&self.thumb_ly.to_le_bytes());
        out[16..18].copy_from_slice(&self.thumb_rx.to_le_bytes());
        out[18..20].copy_from_slice(&self.thumb_ry.to_le_bytes());
        out[20] = self.connected;
        out
    }
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

/// libei sender and its state.
///
/// `context`, `device` and `touches` are libei-owned references kept by this
/// struct alone. Every `unsafe` block that touches them relies on the same
/// invariant: a non-null pointer was handed out by libei and is released
/// exactly once through `reset` or `release_touches`.
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
    gamepad_dirty: bool,
    gamepad_path: PathBuf,
    gamepad_enabled: bool,
}

impl Backend {
    fn new() -> Self {
        let gamepad_path = std::env::var("VULCAN_GAMEPAD_STATE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from("/data/vulcan-gamepad.bin")
            });
        let gamepad_enabled = gamepad_enabled(std::env::var("INPUT_GAMEPAD").ok().as_deref());
        Self::with_path(gamepad_path, gamepad_enabled)
    }

    fn with_path(gamepad_path: PathBuf, gamepad_enabled: bool) -> Self {
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
                // The proxy stays attached; connected marks client pad data.
                connected: 0,
            },
            gamepad_dirty: false,
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
        if std::fs::write(&tmp, self.gamepad.to_bytes()).is_ok() {
            let _ = std::fs::rename(&tmp, &self.gamepad_path);
        }
    }

    fn handle_gamepad(&mut self, event: Event) {
        if event.event_type == EV_SYN && event.code == SYN_REPORT {
            if self.gamepad_dirty {
                self.gamepad.connected = 1;
                self.gamepad.sequence = self.gamepad.sequence.wrapping_add(1);
                self.gamepad_dirty = false;
                self.write_gamepad();
            } else if self.gamepad.connected == 0 {
                // A lost connect message must not hide the pad forever: the
                // first report after it reconnects the proxy.
                self.gamepad.connected = 1;
                self.gamepad.sequence = self.gamepad.sequence.wrapping_add(1);
                self.write_gamepad();
            }
            return;
        }
        if apply_gamepad_event(&mut self.gamepad, event) {
            self.gamepad_dirty = true;
        }
    }

    fn set_gamepad_connected(&mut self, connected: bool) {
        if connected {
            if self.gamepad.connected != 0 {
                return;
            }
            self.gamepad.connected = 1;
        } else {
            if self.gamepad.connected == 0 {
                return;
            }
            self.gamepad.buttons = 0;
            self.gamepad.left_trigger = 0;
            self.gamepad.right_trigger = 0;
            self.gamepad.thumb_lx = 0;
            self.gamepad.thumb_ly = 0;
            self.gamepad.thumb_rx = 0;
            self.gamepad.thumb_ry = 0;
            self.gamepad.connected = 0;
            self.gamepad_dirty = false;
        }
        self.gamepad.sequence = self.gamepad.sequence.wrapping_add(1);
        self.write_gamepad();
    }

    fn reset(&mut self) {
        self.release_touches();
        if !self.device.is_null() {
            // SAFETY: `device` holds a reference obtained from
            // `ei_device_ref`, released here exactly once.
            unsafe { ei_device_unref(self.device) };
            self.device = std::ptr::null_mut();
        }
        if !self.context.is_null() {
            // SAFETY: `context` was returned by `ei_new_sender` and is
            // released here exactly once.
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
                // SAFETY: every slot holds a reference from
                // `ei_device_touch_new`, released here exactly once.
                unsafe { ei_touch_unref(*touch) };
                *touch = std::ptr::null_mut();
            }
        }
        self.touch_capable = false;
    }

    /// Reports whether libei is usable for emulation.
    ///
    /// `ei_device_frame` and `ei_now` also need the context, so both pointers
    /// are part of the condition.
    fn ready(&self) -> bool {
        !self.context.is_null() && !self.device.is_null()
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

        let Some(socket_path) = find_eis_socket() else {
            self.log_wait("waiting for gamescope EIS socket");
            return false;
        };
        let Ok(socket) = CString::new(socket_path.to_string_lossy().as_bytes()) else {
            return false;
        };

        if self.context.is_null() {
            // SAFETY: `ei_new_sender` returns a new sender with no input
            // requirements; a null result is handled below.
            self.context = unsafe { ei_new_sender(std::ptr::null_mut()) };
            if self.context.is_null() {
                return false;
            }
            // SAFETY: `context` is non-null and `socket` is a live CString for
            // the duration of the call.
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
            eprintln!(
                "[vulcan-inputd] connected to gamescope EIS on {}",
                socket_path.display()
            );
        }
        self.emulation.active()
    }

    /// Read and dispatch whatever libei has queued.
    fn poll_eis(&mut self, timeout: Duration) -> bool {
        if self.context.is_null() {
            return false;
        }
        let timeout_ms = c_int::try_from(timeout.as_millis()).unwrap_or(c_int::MAX);
        // SAFETY: `context` is a live sender checked above.
        let fd = unsafe { ei_get_fd(self.context) };
        if fd < 0 {
            return false;
        }

        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: `poll_fd` points to one initialized entry and the count
        // matches, so poll only writes into that entry.
        let result = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if result < 0 {
            return io::Error::last_os_error().kind() == io::ErrorKind::Interrupted;
        }
        if result == 0 {
            return true;
        }

        // SAFETY: `context` is still non-null and owned here; `dispatch_events`
        // releases it before returning on disconnect.
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
            // SAFETY: the loop condition guarantees a live sender context.
            let event = unsafe { ei_get_event(self.context) };
            if event.is_null() {
                break;
            }
            // SAFETY: `event` was returned by `ei_get_event` and is still
            // referenced below, so it is valid.
            let event_type = unsafe { ei_event_get_type(event) };
            match event_type {
                EI_EVENT_CONNECT => {}
                EI_EVENT_SEAT_ADDED => {
                    // SAFETY: `event` is valid, so the seat accessor is too.
                    let seat = unsafe { ei_event_get_seat(event) };
                    if !seat.is_null() {
                        // SAFETY: varargs are read until the null sentinel; the
                        // capability values are plain `c_uint` and the sentinel
                        // is a null pointer constant.
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
                        // SAFETY: `event` is valid and belongs to this dispatch.
                        let device = unsafe { ei_event_get_device(event) };
                        if !device.is_null() {
                            // SAFETY: `device` is non-null; the reference keeps
                            // it alive after the event is released.
                            self.device = unsafe { ei_device_ref(device) };
                            // SAFETY: same live device as above.
                            self.touch_capable =
                                unsafe { ei_device_has_capability(device, EI_DEVICE_CAP_TOUCH) };
                            eprintln!("[vulcan-inputd] EIS device added {device:p}");
                        }
                    } else {
                        // SAFETY: `event` is valid; the device is only logged.
                        let device = unsafe { ei_event_get_device(event) };
                        eprintln!("[vulcan-inputd] EIS extra device ignored {device:p}");
                    }
                }
                EI_EVENT_DEVICE_RESUMED => {
                    // SAFETY: `event` is valid; the pointer is only compared and
                    // logged, never dereferenced.
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
                    // SAFETY: `event` is valid; the pointer is only logged.
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
            // SAFETY: `event` came from `ei_get_event` and is released once
            // here; the loop re-reads the context each iteration.
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
        // SAFETY: `device` was checked non-null above.
        unsafe { ei_device_start_emulating(self.device, self.sequence) };
    }

    fn frame(&self) {
        if self.ready() {
            // SAFETY: `ready` guarantees both the context and the device are
            // live, and neither is released by these calls.
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
        if event.kind == KIND_GAMEPAD_CONNECT {
            if self.gamepad_enabled {
                self.set_gamepad_connected(true);
            }
            return;
        }
        if event.kind == KIND_GAMEPAD_DISCONNECT {
            if self.gamepad_enabled {
                self.set_gamepad_connected(false);
            }
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
                EV_KEY => {
                    // SAFETY: `device` is live and owned by `self`; the call
                    // only uses the device and scalar arguments.
                    unsafe { ei_device_keyboard_key(device, event.code as u32, event.value != 0) }
                }
                EV_SYN if event.code == SYN_REPORT => self.frame(),
                _ => {}
            },
            KIND_MOUSE => match event.event_type {
                EV_REL if event.code == REL_X => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_pointer_motion(device, f64::from(event.value), 0.0) }
                }
                EV_REL if event.code == REL_Y => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_pointer_motion(device, 0.0, f64::from(event.value)) }
                }
                EV_REL if event.code == REL_WHEEL => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_scroll_discrete(device, 0, event.value.saturating_mul(120)) }
                }
                EV_REL if event.code == REL_HWHEEL => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_scroll_discrete(device, event.value.saturating_mul(120), 0) }
                }
                EV_KEY if (BTN_MISC..=BTN_TASK).contains(&event.code) => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_button_button(device, event.code as u32, event.value != 0) }
                }
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
                EV_KEY if (BTN_MISC..=BTN_TASK).contains(&event.code) => {
                    // SAFETY: live device, scalar arguments only.
                    unsafe { ei_device_button_button(device, event.code as u32, event.value != 0) }
                }
                EV_SYN if event.code == SYN_REPORT => {
                    // The shim sends absolute pointer axes in screen pixels;
                    // gamescope resolves them in that space.
                    // SAFETY: live device, scalar arguments only.
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
                    // SAFETY: `device` is live and owned by `self`.
                    let new_touch = unsafe { ei_device_touch_new(device) };
                    if !new_touch.is_null() {
                        // The tracker releases a slot before reusing it, but a
                        // stale object here would leak, so drop it defensively.
                        let stale = std::mem::replace(&mut self.touches[slot], new_touch);
                        if !stale.is_null() {
                            // SAFETY: `stale` came from `ei_device_touch_new`.
                            unsafe { ei_touch_unref(stale) };
                        }
                        // SAFETY: `new_touch` is non-null and owned by the slot.
                        unsafe { ei_touch_down(new_touch, x, y) };
                    }
                }
                touch::TouchAction::Motion { slot, x, y } => {
                    let active = self.touches[slot];
                    if !active.is_null() {
                        // SAFETY: the slot only holds live touch objects.
                        unsafe { ei_touch_motion(active, x, y) };
                    }
                }
                touch::TouchAction::Up { slot } => {
                    let finished =
                        std::mem::replace(&mut self.touches[slot], std::ptr::null_mut());
                    if !finished.is_null() {
                        // SAFETY: `finished` was live and is now owned here; up
                        // is sent once before the reference is released.
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

fn gamepad_values(state: &GamepadState) -> (u16, u8, u8, i16, i16, i16, i16) {
    (
        state.buttons,
        state.left_trigger,
        state.right_trigger,
        state.thumb_lx,
        state.thumb_ly,
        state.thumb_rx,
        state.thumb_ry,
    )
}

/// Applies one event and reports whether it changed the published state.
fn apply_gamepad_event(state: &mut GamepadState, event: Event) -> bool {
    let before = gamepad_values(state);
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
        _ => {}
    }
    gamepad_values(state) != before
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

/// Returns the effective user id of this process.
fn current_uid() -> u32 {
    // SAFETY: `geteuid` has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

/// Reports whether `path` is a socket owned by this user.
///
/// The owner check keeps an ambient path from another user out of the backend
/// selection, which would otherwise let that user redirect input.
fn socket_is_live(path: &Path) -> bool {
    path.symlink_metadata()
        .map(|meta| meta.file_type().is_socket() && meta.uid() == current_uid())
        .unwrap_or(false)
}

/// Returns the live `*-ei` socket in `directory`, the naming gamescope uses.
fn socket_in(directory: &Path) -> Option<PathBuf> {
    for entry in std::fs::read_dir(directory).ok()?.flatten() {
        let path = entry.path();
        let named = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with("-ei"));
        if named && socket_is_live(&path) {
            return Some(path);
        }
    }
    None
}

/// Resolves the EIS socket of this container's gamescope.
///
/// Only paths that belong to the container are inspected: the explicit
/// override, the environment of the processes in this PID namespace, and the
/// session runtime directory. Ambient directories shared with the host or with
/// another session are not searched, and every candidate must be a socket owned
/// by the current user.
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

    if let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") {
        return socket_in(Path::new(&runtime));
    }

    None
}

/// Serves the single input producer of this session.
///
/// One shim owns the socket, so one connection is handled at a time and a
/// second client waits in the socket backlog. The blocking read keeps the
/// daemon simple; revisit it if multiple producers need the socket.
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

/// Removes the socket left by a previous run.
///
/// Only a socket owned by the current user is unlinked; anything else at that
/// path is reported instead of deleted.
fn clear_stale_socket(path: &Path) -> io::Result<()> {
    match path.symlink_metadata() {
        Ok(metadata) if metadata.file_type().is_socket() && metadata.uid() == current_uid() => {
            std::fs::remove_file(path)
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{} is not a socket owned by this user", path.display()),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn main() -> io::Result<()> {
    let socket_path = std::env::var("VULCAN_INPUT_SOCKET")
        .ok()
        .filter(|path| !path.is_empty())
        .or_else(|| {
            std::env::var("XDG_RUNTIME_DIR")
                .ok()
                .map(|runtime| format!("{runtime}/vulcan-input.sock"))
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "VULCAN_INPUT_SOCKET or XDG_RUNTIME_DIR is required",
            )
        })?;
    clear_stale_socket(Path::new(&socket_path))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gamepad_record_matches_the_xinput_dll() {
        let bytes = test_state().to_bytes();
        assert_eq!(bytes.len(), 28);
        assert_eq!(&bytes[0..4], &GAMEPAD_MAGIC.to_le_bytes());
        assert_eq!(&bytes[4..8], &0u32.to_le_bytes());
        assert_eq!(&bytes[8..10], &0u16.to_le_bytes());
        assert_eq!(bytes[10], 0);
        assert_eq!(bytes[11], 0);
        assert_eq!(&bytes[12..14], &0i16.to_le_bytes());
        assert_eq!(bytes[20], 1);
        assert_eq!(&bytes[21..28], &[0u8; 7]);
    }

    #[test]
    fn gamepad_record_roundtrips_every_field() {
        let state = GamepadState {
            magic: GAMEPAD_MAGIC,
            sequence: 0x1122_3344,
            buttons: 0xA55A,
            left_trigger: 17,
            right_trigger: 231,
            thumb_lx: -1234,
            thumb_ly: 2345,
            thumb_rx: -3456,
            thumb_ry: 4567,
            connected: 1,
        };
        assert_eq!(decode_gamepad(&state.to_bytes()), state);
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
        }
    }

    /// Decodes the record the way the XInput DLL does.
    fn decode_gamepad(bytes: &[u8]) -> GamepadState {
        assert_eq!(bytes.len(), GAMEPAD_STATE_LEN);
        GamepadState {
            magic: u32::from_le_bytes(bytes[0..4].try_into().unwrap()),
            sequence: u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
            buttons: u16::from_le_bytes(bytes[8..10].try_into().unwrap()),
            left_trigger: bytes[10],
            right_trigger: bytes[11],
            thumb_lx: i16::from_le_bytes(bytes[12..14].try_into().unwrap()),
            thumb_ly: i16::from_le_bytes(bytes[14..16].try_into().unwrap()),
            thumb_rx: i16::from_le_bytes(bytes[16..18].try_into().unwrap()),
            thumb_ry: i16::from_le_bytes(bytes[18..20].try_into().unwrap()),
            connected: bytes[20],
        }
    }

    #[test]
    fn stale_socket_of_this_user_is_removed() {
        let path = temp_path("stale");
        let listener = UnixListener::bind(&path).unwrap();
        drop(listener);
        clear_stale_socket(&path).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn stale_socket_removal_refuses_other_files() {
        let path = temp_path("regular");
        std::fs::write(&path, b"keep").unwrap();
        let error = clear_stale_socket(&path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&path).unwrap(), b"keep");
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn stale_socket_removal_accepts_a_missing_path() {
        let path = temp_path("missing");
        clear_stale_socket(&path).unwrap();
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        let directory =
            std::env::temp_dir().join(format!("vulcan-socket-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory.join("input.sock")
    }

    #[test]
    fn finds_only_live_ei_sockets() {
        let directory = std::env::temp_dir().join(format!("vulcan-eis-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();

        std::fs::write(directory.join("stale-ei"), b"").unwrap();
        assert_eq!(socket_in(&directory), None);

        let listener = UnixListener::bind(directory.join("live-ei")).unwrap();
        assert_eq!(socket_in(&directory), Some(directory.join("live-ei")));

        drop(listener);
        std::fs::remove_dir_all(&directory).unwrap();
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
        assert!(apply_gamepad_event(
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
    fn repeated_gamepad_values_do_not_count_as_changes() {
        let mut state = test_state();
        let axis = Event {
            kind: KIND_GAMEPAD,
            event_type: EV_ABS,
            code: vulcan_input_proto::ABS_X,
            value: 1000,
        };
        assert!(apply_gamepad_event(&mut state, axis));
        assert!(!apply_gamepad_event(&mut state, axis));
        assert!(!apply_gamepad_event(&mut state, axis));
    }

    #[test]
    fn gamepad_buttons_report_press_and_release() {
        let mut state = test_state();
        let press = Event {
            kind: KIND_GAMEPAD,
            event_type: EV_KEY,
            code: BTN_SOUTH,
            value: 1,
        };
        let release = Event { value: 0, ..press };
        assert!(apply_gamepad_event(&mut state, press));
        assert!(!apply_gamepad_event(&mut state, press));
        assert_eq!(state.buttons, 0x1000);
        assert!(apply_gamepad_event(&mut state, release));
        assert_eq!(state.buttons, 0);
    }

    fn gamepad_event(kind: u8, event_type: u16, code: u16, value: i32) -> Event {
        Event {
            kind,
            event_type,
            code,
            value,
        }
    }

    fn read_gamepad(path: &std::path::Path) -> GamepadState {
        decode_gamepad(&std::fs::read(path).unwrap())
    }

    fn test_backend(name: &str) -> (Backend, std::path::PathBuf) {
        let directory =
            std::env::temp_dir().join(format!("vulcan-gamepad-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("pad.bin");
        (Backend::with_path(path.clone(), true), path)
    }

    #[test]
    fn gamepad_file_is_rewritten_only_when_the_state_changes() {
        use std::os::unix::fs::MetadataExt;

        let (mut backend, path) = test_backend("writes");
        let axis = gamepad_event(KIND_GAMEPAD, EV_ABS, vulcan_input_proto::ABS_X, 1000);
        backend.handle(axis);
        backend.handle(gamepad_event(KIND_GAMEPAD, EV_SYN, SYN_REPORT, 0));
        let first = std::fs::metadata(&path).unwrap().ino();
        assert_eq!(read_gamepad(&path).thumb_lx, 1000);

        backend.handle(axis);
        backend.handle(gamepad_event(KIND_GAMEPAD, EV_SYN, SYN_REPORT, 0));
        assert_eq!(std::fs::metadata(&path).unwrap().ino(), first);

        backend.handle(gamepad_event(
            KIND_GAMEPAD,
            EV_ABS,
            vulcan_input_proto::ABS_X,
            2000,
        ));
        backend.handle(gamepad_event(KIND_GAMEPAD, EV_SYN, SYN_REPORT, 0));
        let second = std::fs::metadata(&path).unwrap().ino();
        assert_ne!(second, first);
        assert_eq!(read_gamepad(&path).thumb_lx, 2000);

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn gamepad_connection_events_toggle_the_proxy() {
        let (mut backend, path) = test_backend("connect");
        assert_eq!(read_gamepad(&path).connected, 0);

        backend.handle(gamepad_event(KIND_GAMEPAD_CONNECT, 0, 0, 0));
        let connected = read_gamepad(&path);
        assert_eq!(connected.connected, 1);

        backend.handle(gamepad_event(
            KIND_GAMEPAD,
            EV_ABS,
            vulcan_input_proto::ABS_X,
            500,
        ));
        backend.handle(gamepad_event(KIND_GAMEPAD, EV_SYN, SYN_REPORT, 0));
        assert_eq!(read_gamepad(&path).thumb_lx, 500);

        backend.handle(gamepad_event(KIND_GAMEPAD_DISCONNECT, 0, 0, 0));
        let disconnected = read_gamepad(&path);
        assert_eq!(disconnected.connected, 0);
        assert_eq!(disconnected.thumb_lx, 0);
        assert_eq!(disconnected.buttons, 0);

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
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

