#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

//! `LD_PRELOAD` shim that replaces the virtual input devices Apollo creates.
//!
//! Only the small `libevdev_uinput` surface Apollo uses is interposed: the
//! create and destroy calls, the accessors, and the event writer. Every other
//! symbol from libevdev is resolved from the real library at first use.

use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::io::{self, Write};
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::os::unix::net::UnixStream;
use std::sync::{Mutex, OnceLock};

use vulcan_input_proto::{
    Event, EV_ABS, EV_KEY, EV_REL, EV_SYN, KIND_GAMEPAD, KIND_GAMEPAD_CONNECT,
    KIND_GAMEPAD_DISCONNECT, KIND_KEYBOARD, KIND_MOUSE, KIND_MOUSE_ABSOLUTE, KIND_PASSTHROUGH,
    KIND_PEN, KIND_TOUCH, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y, TOUCH_RANGE,
};

#[repr(C)]
pub struct libevdev {
    _private: [u8; 0],
}

#[repr(C)]
pub struct libevdev_uinput {
    _private: [u8; 0],
}

#[repr(C)]
struct InputAbsInfo {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
}

type CreateFn = unsafe extern "C" fn(*const libevdev, c_int, *mut *mut libevdev_uinput) -> c_int;
type DestroyFn = unsafe extern "C" fn(*mut libevdev_uinput);
type GetFdFn = unsafe extern "C" fn(*const libevdev_uinput) -> c_int;
type GetPathFn = unsafe extern "C" fn(*mut libevdev_uinput) -> *const c_char;
type WriteFn =
    unsafe extern "C" fn(*const libevdev_uinput, c_uint, c_uint, c_int) -> c_int;
type GetNameFn = unsafe extern "C" fn(*const libevdev) -> *const c_char;
type GetAbsFn = unsafe extern "C" fn(*const libevdev, c_uint) -> *const InputAbsInfo;

struct Real {
    create: CreateFn,
    destroy: DestroyFn,
    get_fd: GetFdFn,
    get_devnode: GetPathFn,
    get_syspath: GetPathFn,
    write: WriteFn,
    get_name: GetNameFn,
    get_abs_info: GetAbsFn,
}

struct Fake {
    kind: u8,
    real: *mut libevdev_uinput,
    devnode: CString,
    abs_max_x: i32,
    abs_max_y: i32,
}

static REAL: OnceLock<Option<Real>> = OnceLock::new();
static SOCKET: Mutex<Option<UnixStream>> = Mutex::new(None);
static FAKES: OnceLock<Mutex<HashSet<usize>>> = OnceLock::new();
static SHIM_SYSPATH: &[u8] = b"/sys/class/input/event-vulcan\0";

/// Clears `LD_PRELOAD` before Apollo spawns its helpers.
///
/// Apollo runs the game and its wine processes as children; leaving the
/// variable set would load the shim into every one of them. Constructors run
/// before `main` and while the process is still single threaded, so touching
/// the environment here is safe even though `unsetenv` is not async-signal
/// safe.
unsafe extern "C" fn unset_preload() {
    // SAFETY: the pointer comes from a static NUL terminated literal.
    unsafe { libc::unsetenv(c"LD_PRELOAD".as_ptr()) };
}

#[used]
#[link_section = ".init_array"]
static UNSET_PRELOAD: unsafe extern "C" fn() = unset_preload;

/// Resolves one symbol and casts it to the expected C function pointer.
///
/// `dlsym` returns a data pointer; the cast is sound only while function
/// pointers and data pointers share a size, which holds on the supported
/// Linux targets and is checked at runtime here.
unsafe fn symbol_fn<T: Copy>(handle: *mut c_void, name: &str) -> Option<T> {
    if std::mem::size_of::<T>() != std::mem::size_of::<*mut c_void>() {
        return None;
    }
    let name = CString::new(name).ok()?;
    // SAFETY: `handle` comes from a successful `dlopen` and `name` is a live
    // CString for the duration of the call.
    let pointer = unsafe { libc::dlsym(handle, name.as_ptr()) };
    if pointer.is_null() {
        return None;
    }
    // SAFETY: `pointer` is non-null and the size check above guarantees `T`
    // has the same representation as the pointer it is read from.
    Some(unsafe { std::mem::transmute_copy(&pointer) })
}

fn fakes() -> &'static Mutex<HashSet<usize>> {
    FAKES.get_or_init(|| Mutex::new(HashSet::new()))
}

fn register_fake(pointer: *mut libevdev_uinput) {
    let mut set = fakes()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set.insert(pointer as usize);
}

/// Reports whether the pointer was handed out by this shim.
///
/// The registry is checked instead of a tag stored in the allocation because
/// the pointer may belong to the real libevdev, and reading a foreign
/// allocation to discover that would be undefined behavior. The trade-off is
/// that an address reused after `libevdev_uinput_destroy` cannot be told apart
/// from a live fake; the destroy path removes the entry, so a reused address is
/// never treated as a fake.
fn is_fake(pointer: *const libevdev_uinput) -> bool {
    let set = fakes()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set.contains(&(pointer as usize))
}

fn take_fake(pointer: *mut libevdev_uinput) -> bool {
    let mut set = fakes()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set.remove(&(pointer as usize))
}

fn real() -> Option<&'static Real> {
    REAL.get_or_init(|| {
        // SAFETY: `dlopen` only reads the static name and returns either a
        // handle or null, which is checked immediately.
        let handle = unsafe {
            libc::dlopen(
                c"libevdev.so.2".as_ptr(),
                libc::RTLD_LAZY | libc::RTLD_LOCAL,
            )
        };
        if handle.is_null() {
            return None;
        }
        // SAFETY: `handle` is a live library handle and every name is a static
        // literal; `symbol_fn` keeps the cast sound on the supported targets.
        unsafe {
            Some(Real {
                create: symbol_fn(handle, "libevdev_uinput_create_from_device")?,
                destroy: symbol_fn(handle, "libevdev_uinput_destroy")?,
                get_fd: symbol_fn(handle, "libevdev_uinput_get_fd")?,
                get_devnode: symbol_fn(handle, "libevdev_uinput_get_devnode")?,
                get_syspath: symbol_fn(handle, "libevdev_uinput_get_syspath")?,
                write: symbol_fn(handle, "libevdev_uinput_write_event")?,
                get_name: symbol_fn(handle, "libevdev_get_name")?,
                get_abs_info: symbol_fn(handle, "libevdev_get_abs_info")?,
            })
        }
    })
    .as_ref()
}

fn is_apollo() -> bool {
    std::env::args_os()
        .next()
        .and_then(|arg| {
            std::path::Path::new(&arg)
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name == "apollo")
        })
        .unwrap_or(false)
}

fn device_name(dev: *const libevdev) -> String {
    let Some(real) = real() else {
        return String::new();
    };
    // SAFETY: `dev` is the libevdev device Apollo passed to the create call and
    // stays owned by Apollo for the duration of the call.
    unsafe {
        let name = (real.get_name)(dev);
        if name.is_null() {
            return String::new();
        }
        CStr::from_ptr(name).to_string_lossy().into_owned()
    }
}

fn abs_max(dev: *const libevdev, code: c_uint) -> i32 {
    let Some(real) = real() else {
        return 0;
    };
    // SAFETY: `dev` is the libevdev device Apollo passed to the create call; the
    // returned info pointer belongs to that device and is checked for null.
    unsafe {
        let info = (real.get_abs_info)(dev, code);
        if info.is_null() || (*info).maximum <= 0 {
            0
        } else {
            (*info).maximum
        }
    }
}

fn classify(name: &str) -> u8 {
    if !name.contains("passthrough") {
        if name.contains("X-Box") || name.contains("Nintendo") || name.contains("PS5")
            || name.contains("pad")
        {
            return KIND_GAMEPAD;
        }
        return KIND_PASSTHROUGH;
    }
    if name.contains("Keyboard") {
        return KIND_KEYBOARD;
    }
    if name.contains("Touch") {
        return KIND_TOUCH;
    }
    if name.contains("Pen") {
        return KIND_PEN;
    }
    if name.contains("Mouse") && name.contains("absolute") {
        return KIND_MOUSE_ABSOLUTE;
    }
    if name.contains("Mouse") {
        return KIND_MOUSE;
    }
    KIND_PASSTHROUGH
}

fn socket_path_from(explicit: Option<&str>, runtime: Option<&str>) -> Option<String> {
    if let Some(path) = explicit.filter(|path| !path.is_empty()) {
        return Some(path.to_string());
    }
    runtime.map(|runtime| format!("{runtime}/vulcan-input.sock"))
}

/// Returns the session input socket.
///
/// `VULCAN_INPUT_SOCKET` names the socket explicitly; the runtime directory is
/// only a fallback for a process started outside `session-start.sh`.
fn socket_path() -> Option<String> {
    let explicit = std::env::var("VULCAN_INPUT_SOCKET").ok();
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok();
    let path = socket_path_from(explicit.as_deref(), runtime.as_deref());
    if path.is_none() {
        static LOGGED: OnceLock<()> = OnceLock::new();
        LOGGED.get_or_init(|| {
            eprintln!("[vulcan-shim] no input socket configured; dropping input");
        });
    }
    path
}

/// Sends one event to the session socket.
///
/// The socket is non-blocking so a stalled consumer cannot stall the game. A
/// short write would desynchronize the 9-byte framing, so the connection is
/// dropped instead of retried; the next event reconnects with a clean stream.
fn send_event(event: Event) {
    let mut guard = match SOCKET.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    if guard.is_none() {
        let Some(path) = socket_path() else {
            return;
        };
        match UnixStream::connect(path) {
            Ok(stream) => {
                if stream.set_nonblocking(true).is_err() {
                    return;
                }
                *guard = Some(stream);
            }
            Err(_) => return,
        }
    }

    if let Some(stream) = guard.as_mut() {
        let bytes = event.to_bytes();
        let mut drop_stream = false;
        loop {
            match stream.write(&bytes) {
                Ok(written) if written == vulcan_input_proto::WIRE_LEN => break,
                // The buffer is full; the event is dropped on purpose.
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                // No bytes were written, so the frame can be retried.
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                // A short or failed write leaves unusable framing behind.
                _ => {
                    drop_stream = true;
                    break;
                }
            }
        }
        if drop_stream {
            *guard = None;
        }
    }
}

/// Creates the device Apollo asked for, or forwards the call unchanged.
///
/// # Safety
///
/// `dev` must be a live libevdev device and `uidev` a valid pointer to write
/// the resulting handle to. The shim is called this way through `LD_PRELOAD`.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_create_from_device(
    dev: *const libevdev,
    fd: c_int,
    uidev: *mut *mut libevdev_uinput,
) -> c_int {
    if uidev.is_null() {
        return -libc::EINVAL;
    }
    let Some(real) = real() else {
        return -libc::EIO;
    };

    if !is_apollo() {
        // SAFETY: the arguments are the ones Apollo passed through; this is a
        // pure forward of the call to the real implementation.
        return unsafe { (real.create)(dev, fd, uidev) };
    }

    let kind = classify(&device_name(dev));
    if kind == KIND_PASSTHROUGH {
        let mut real_device: *mut libevdev_uinput = std::ptr::null_mut();
        // SAFETY: `dev` and `fd` come from Apollo and `real_device` points to a
        // local that outlives the call.
        let result = unsafe { (real.create)(dev, fd, &mut real_device) };
        if result != 0 || real_device.is_null() {
            return result;
        }
        let fake = Box::new(Fake {
            kind,
            real: real_device,
            devnode: CString::new("/dev/input/event-vulcan-gamepad").unwrap_or_default(),
            abs_max_x: 0,
            abs_max_y: 0,
        });
        // SAFETY: `uidev` was checked non-null above.
        unsafe {
            let raw = Box::into_raw(fake) as *mut libevdev_uinput;
            register_fake(raw);
            *uidev = raw;
        }
        return 0;
    }

    let fake = Box::new(Fake {
        kind,
        real: std::ptr::null_mut(),
        devnode: CString::new(format!("/dev/input/event-vulcan-{kind}")).unwrap_or_default(),
        abs_max_x: abs_max(dev, ABS_X as c_uint),
        abs_max_y: abs_max(dev, ABS_Y as c_uint),
    });

    // SAFETY: `uidev` was checked non-null above; the box is intentionally
    // leaked into the handle Apollo owns and is freed by the destroy call.
    unsafe {
        let raw = Box::into_raw(fake) as *mut libevdev_uinput;
        register_fake(raw);
        *uidev = raw;
    }
    if kind == KIND_GAMEPAD {
        send_event(Event {
            kind: KIND_GAMEPAD_CONNECT,
            event_type: 0,
            code: 0,
            value: 0,
        });
    }
    0
}

/// Releases a handle created by this shim or by the real libevdev.
///
/// # Safety
///
/// `uidev` must be a handle returned by `libevdev_uinput_create_from_device`
/// and must not be used afterwards. A null pointer is ignored.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_destroy(uidev: *mut libevdev_uinput) {
    if uidev.is_null() {
        return;
    }

    if !take_fake(uidev) {
        // libevdev's own create error path calls destroy on a real handle.
        if let Some(real) = real() {
            // SAFETY: the pointer was not created by this shim, so it belongs
            // to the real libevdev.
            unsafe { (real.destroy)(uidev) };
        }
        return;
    }

    // SAFETY: the registry only holds pointers produced by `Box::into_raw` in
    // the create call, which are removed by `take_fake` exactly once.
    let fake = unsafe { Box::from_raw(uidev as *mut Fake) };
    if fake.kind == KIND_GAMEPAD && fake.real.is_null() {
        send_event(Event {
            kind: KIND_GAMEPAD_DISCONNECT,
            event_type: 0,
            code: 0,
            value: 0,
        });
    }
    if !fake.real.is_null() {
        if let Some(real) = real() {
            // SAFETY: `fake.real` is the handle the real create call returned.
            unsafe { (real.destroy)(fake.real) };
        }
    }
}

/// Returns the event file descriptor behind a handle.
///
/// # Safety
///
/// `uidev` must be a live handle returned by the create call.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_fd(uidev: *const libevdev_uinput) -> c_int {
    if !is_fake(uidev) {
        return match real() {
            // SAFETY: the pointer is not a shim handle, so it belongs to the
            // real libevdev.
            Some(real) => unsafe { (real.get_fd)(uidev) },
            None => -1,
        };
    }
    // SAFETY: `is_fake` matched, so the pointer is a live `Fake`.
    let fake = unsafe { &*(uidev as *const Fake) };
    if fake.real.is_null() {
        return -1;
    }
    match real() {
        // SAFETY: `fake.real` is a live libevdev handle.
        Some(real) => unsafe { (real.get_fd)(fake.real) },
        None => -1,
    }
}

/// Returns the device node path of a handle.
///
/// # Safety
///
/// `uidev` must be a live handle. The returned pointer is borrowed from the
/// handle and stays valid only until the handle is destroyed.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_devnode(
    uidev: *mut libevdev_uinput,
) -> *const c_char {
    if !is_fake(uidev) {
        return match real() {
            // SAFETY: foreign handle, resolved from the real libevdev.
            Some(real) => unsafe { (real.get_devnode)(uidev) },
            None => std::ptr::null(),
        };
    }
    // SAFETY: `is_fake` matched, so the pointer is a live `Fake`.
    let fake = unsafe { &*(uidev as *const Fake) };
    if fake.real.is_null() {
        return fake.devnode.as_ptr();
    }
    match real() {
        // SAFETY: `fake.real` is a live libevdev handle.
        Some(real) => unsafe { (real.get_devnode)(fake.real) },
        None => std::ptr::null(),
    }
}

/// Returns the sysfs path of a handle.
///
/// # Safety
///
/// `uidev` must be a live handle. The returned pointer is borrowed from the
/// handle and stays valid only until the handle is destroyed.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_syspath(
    uidev: *mut libevdev_uinput,
) -> *const c_char {
    if !is_fake(uidev) {
        return match real() {
            // SAFETY: foreign handle, resolved from the real libevdev.
            Some(real) => unsafe { (real.get_syspath)(uidev) },
            None => std::ptr::null(),
        };
    }
    // SAFETY: `is_fake` matched, so the pointer is a live `Fake`.
    let fake = unsafe { &*(uidev as *const Fake) };
    if fake.real.is_null() {
        return SHIM_SYSPATH.as_ptr() as *const c_char;
    }
    match real() {
        // SAFETY: `fake.real` is a live libevdev handle.
        Some(real) => unsafe { (real.get_syspath)(fake.real) },
        None => std::ptr::null(),
    }
}

/// Writes one event to the device, translating it for the proxy.
///
/// # Safety
///
/// `uidev` must be a live handle returned by the create call.
#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_write_event(
    uidev: *const libevdev_uinput,
    event_type: c_uint,
    code: c_uint,
    value: c_int,
) -> c_int {
    if !is_fake(uidev) {
        return match real() {
            // SAFETY: foreign handle, resolved from the real libevdev.
            Some(real) => unsafe { (real.write)(uidev, event_type, code, value) },
            None => -libc::EIO,
        };
    }
    // SAFETY: `is_fake` matched, so the pointer is a live `Fake`.
    let fake = unsafe { &*(uidev as *const Fake) };
    if !fake.real.is_null() {
        return match real() {
            // SAFETY: `fake.real` is a live libevdev handle.
            Some(real) => unsafe { (real.write)(fake.real, event_type, code, value) },
            None => -libc::EIO,
        };
    }

    if fake.kind == KIND_TOUCH {
        let event = touch_event(fake, event_type, code, value);
        if matches!(event.event_type, EV_SYN | EV_KEY | EV_ABS) {
            send_event(event);
        }
        return 0;
    }

    if fake.kind == KIND_PEN {
        return 0;
    }

    let mut value = value;
    if fake.kind == KIND_MOUSE_ABSOLUTE && event_type as u16 == EV_ABS {
        // Gamescope resolves absolute pointer coordinates in screen pixels,
        // while touch uses the wire range. Keep the two conversions separate.
        let (width, height) = screen_size();
        let (maximum, size) = if code as u16 == ABS_X {
            (fake.abs_max_x, width)
        } else if code as u16 == ABS_Y {
            (fake.abs_max_y, height)
        } else {
            (0, 0)
        };
        if maximum > 0 && size > 0 {
            value = value.saturating_mul(size - 1) / maximum;
        }
    }

    let event = Event {
        kind: fake.kind,
        event_type: event_type as u16,
        code: code as u16,
        value,
    };
    if event.event_type == EV_SYN || event.event_type == EV_KEY || event.event_type == EV_REL
        || event.event_type == EV_ABS
    {
        send_event(event);
    }
    0
}

/// Converts an evdev axis value to the wire range.
///
/// The protocol is resolution independent, so slot, tracking id, pressure and
/// orientation values pass through unchanged with `maximum` of zero.
fn scale_touch(value: i32, maximum: i32) -> i32 {
    if maximum <= 0 {
        return value;
    }
    let value = i64::from(value).clamp(0, i64::from(maximum));
    (value * i64::from(TOUCH_RANGE) / i64::from(maximum)) as i32
}

fn screen_size() -> (i32, i32) {
    let width = std::env::var("GAME_WIDTH")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(1920);
    let height = std::env::var("GAME_HEIGHT")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(1080);
    (width, height)
}

fn touch_event(fake: &Fake, event_type: c_uint, code: c_uint, value: c_int) -> Event {
    let mut value = value;
    if event_type as u16 == EV_ABS {
        let maximum = match code as u16 {
            ABS_X | ABS_MT_POSITION_X => fake.abs_max_x,
            ABS_Y | ABS_MT_POSITION_Y => fake.abs_max_y,
            _ => 0,
        };
        value = scale_touch(value, maximum);
    }
    Event {
        kind: fake.kind,
        event_type: event_type as u16,
        code: code as u16,
        value,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn touch_axes_scale_to_wire_range() {
        assert_eq!(scale_touch(0, 19200), 0);
        assert_eq!(scale_touch(19200, 19200), TOUCH_RANGE);
        assert_eq!(scale_touch(9600, 19200), TOUCH_RANGE / 2);
        assert_eq!(scale_touch(10800, 10800), TOUCH_RANGE);
    }

    #[test]
    fn socket_path_prefers_the_explicit_variable() {
        assert_eq!(
            socket_path_from(Some("/run/user/1000/custom.sock"), Some("/run/user/1000")),
            Some("/run/user/1000/custom.sock".to_string())
        );
    }

    #[test]
    fn socket_path_falls_back_to_the_runtime_directory() {
        assert_eq!(
            socket_path_from(None, Some("/run/user/1000")),
            Some("/run/user/1000/vulcan-input.sock".to_string())
        );
        assert_eq!(
            socket_path_from(Some(""), Some("/run/user/1000")),
            Some("/run/user/1000/vulcan-input.sock".to_string())
        );
    }

    #[test]
    fn socket_path_requires_configuration() {
        assert_eq!(socket_path_from(None, None), None);
    }

    #[test]
    fn touch_axes_clamp_and_pass_through() {
        assert_eq!(scale_touch(-5, 19200), 0);
        assert_eq!(scale_touch(20000, 19200), TOUCH_RANGE);
        assert_eq!(scale_touch(2, 0), 2);
        assert_eq!(scale_touch(-1, 0), -1);
    }
}
