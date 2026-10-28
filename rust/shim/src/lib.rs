use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::os::unix::net::UnixStream;
use std::sync::{Mutex, OnceLock};

use vulcan_input_proto::{
    Event, BTN_MISC, BTN_TASK, EV_ABS, EV_KEY, EV_REL, EV_SYN, KIND_GAMEPAD, KIND_KEYBOARD,
    KIND_MOUSE, KIND_MOUSE_ABSOLUTE, KIND_PASSTHROUGH, KIND_PEN, KIND_TOUCH, ABS_MT_POSITION_X,
    ABS_MT_POSITION_Y, ABS_X, ABS_Y, REL_HWHEEL, REL_WHEEL, REL_X, REL_Y, SYN_REPORT, TOUCH_RANGE,
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

unsafe extern "C" fn unset_preload() {
    libc::unsetenv(c"LD_PRELOAD".as_ptr());
}

#[used]
#[link_section = ".init_array"]
static UNSET_PRELOAD: unsafe extern "C" fn() = unset_preload;

unsafe fn symbol(handle: *mut c_void, name: &str) -> *mut c_void {
    let name = CString::new(name).unwrap_or_default();
    libc::dlsym(handle, name.as_ptr())
}

fn fakes() -> &'static Mutex<HashSet<usize>> {
    FAKES.get_or_init(|| Mutex::new(HashSet::new()))
}

fn register_fake(pointer: *mut libevdev_uinput) {
    if let Ok(mut set) = fakes().lock() {
        set.insert(pointer as usize);
    }
}

fn is_fake(pointer: *const libevdev_uinput) -> bool {
    fakes()
        .lock()
        .map(|set| set.contains(&(pointer as usize)))
        .unwrap_or(false)
}

fn take_fake(pointer: *mut libevdev_uinput) -> bool {
    fakes()
        .lock()
        .map(|mut set| set.remove(&(pointer as usize)))
        .unwrap_or(false)
}

fn real() -> Option<&'static Real> {
    REAL.get_or_init(|| unsafe {
        let handle = libc::dlopen(
            c"libevdev.so.2".as_ptr(),
            libc::RTLD_LAZY | libc::RTLD_LOCAL,
        );
        if handle.is_null() {
            return None;
        }
        let create = symbol(handle, "libevdev_uinput_create_from_device");
        let destroy = symbol(handle, "libevdev_uinput_destroy");
        let get_fd = symbol(handle, "libevdev_uinput_get_fd");
        let get_devnode = symbol(handle, "libevdev_uinput_get_devnode");
        let get_syspath = symbol(handle, "libevdev_uinput_get_syspath");
        let write = symbol(handle, "libevdev_uinput_write_event");
        let get_name = symbol(handle, "libevdev_get_name");
        let get_abs_info = symbol(handle, "libevdev_get_abs_info");
        if create.is_null() || destroy.is_null() || get_fd.is_null() || get_devnode.is_null()
            || get_syspath.is_null() || write.is_null() || get_name.is_null()
            || get_abs_info.is_null()
        {
            return None;
        }
        Some(Real {
            create: std::mem::transmute(create),
            destroy: std::mem::transmute(destroy),
            get_fd: std::mem::transmute(get_fd),
            get_devnode: std::mem::transmute(get_devnode),
            get_syspath: std::mem::transmute(get_syspath),
            write: std::mem::transmute(write),
            get_name: std::mem::transmute(get_name),
            get_abs_info: std::mem::transmute(get_abs_info),
        })
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
    unsafe {
        let Some(real) = real() else {
            return String::new();
        };
        let name = (real.get_name)(dev);
        if name.is_null() {
            return String::new();
        }
        CStr::from_ptr(name).to_string_lossy().into_owned()
    }
}

fn abs_max(dev: *const libevdev, code: c_uint) -> i32 {
    unsafe {
        let Some(real) = real() else {
            return 0;
        };
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

fn send_event(event: Event) {
    let mut guard = match SOCKET.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    if guard.is_none() {
        let path = std::env::var("VULCAN_INPUT_SOCKET").unwrap_or_else(|_| {
            let runtime = std::env::var("XDG_RUNTIME_DIR")
                .unwrap_or_else(|_| "/run/user/1000".to_string());
            format!("{runtime}/vulcan-input.sock")
        });
        match UnixStream::connect(path) {
            Ok(stream) => {
                *guard = Some(stream);
            }
            Err(_) => return,
        }
    }

    if let Some(stream) = guard.as_mut() {
        if let Err(error) = event.write_to(stream) {
            if error.kind() != std::io::ErrorKind::WouldBlock {
                *guard = None;
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_create_from_device(
    dev: *const libevdev,
    fd: c_int,
    uidev: *mut *mut libevdev_uinput,
) -> c_int {
    let Some(real) = real() else {
        return -libc::EIO;
    };

    if !is_apollo() {
        return (real.create)(dev, fd, uidev);
    }

    let kind = classify(&device_name(dev));
    if kind == KIND_PASSTHROUGH {
        let mut real_device: *mut libevdev_uinput = std::ptr::null_mut();
        let result = (real.create)(dev, fd, &mut real_device);
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
        if !uidev.is_null() {
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

    if !uidev.is_null() {
        let raw = Box::into_raw(fake) as *mut libevdev_uinput;
        register_fake(raw);
        *uidev = raw;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_destroy(uidev: *mut libevdev_uinput) {
    if uidev.is_null() {
        return;
    }

    if !take_fake(uidev) {
        /* libevdev's own create error path calls destroy on a real handle. */
        if let Some(real) = real() {
            (real.destroy)(uidev);
        }
        return;
    }

    let fake = Box::from_raw(uidev as *mut Fake);
    if !fake.real.is_null() {
        if let Some(real) = real() {
            (real.destroy)(fake.real);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_fd(uidev: *const libevdev_uinput) -> c_int {
    if !is_fake(uidev) {
        return match real() {
            Some(real) => (real.get_fd)(uidev),
            None => -1,
        };
    }
    let fake = &*(uidev as *const Fake);
    if fake.real.is_null() {
        return -1;
    }
    match real() {
        Some(real) => (real.get_fd)(fake.real),
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_devnode(
    uidev: *mut libevdev_uinput,
) -> *const c_char {
    if !is_fake(uidev) {
        return match real() {
            Some(real) => (real.get_devnode)(uidev),
            None => std::ptr::null(),
        };
    }
    let fake = &*(uidev as *const Fake);
    if fake.real.is_null() {
        return fake.devnode.as_ptr();
    }
    match real() {
        Some(real) => (real.get_devnode)(fake.real),
        None => std::ptr::null(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_get_syspath(
    uidev: *mut libevdev_uinput,
) -> *const c_char {
    if !is_fake(uidev) {
        return match real() {
            Some(real) => (real.get_syspath)(uidev),
            None => std::ptr::null(),
        };
    }
    let fake = &*(uidev as *const Fake);
    if fake.real.is_null() {
        return SHIM_SYSPATH.as_ptr() as *const c_char;
    }
    match real() {
        Some(real) => (real.get_syspath)(fake.real),
        None => std::ptr::null(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn libevdev_uinput_write_event(
    uidev: *const libevdev_uinput,
    event_type: c_uint,
    code: c_uint,
    value: c_int,
) -> c_int {
    if !is_fake(uidev) {
        return match real() {
            Some(real) => (real.write)(uidev, event_type, code, value),
            None => -libc::EIO,
        };
    }
    let fake = &*(uidev as *const Fake);
    if !fake.real.is_null() {
        return match real() {
            Some(real) => (real.write)(fake.real, event_type, code, value),
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

/// Converts a touch axis value to the wire range.
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

/* Keep the constants referenced so the protocol header stays authoritative
 * even if the compiler would otherwise trim unused items. */
#[used]
static _TYPE_CHECKS: [u16; 10] = [
    EV_SYN, EV_KEY, EV_REL, EV_ABS, SYN_REPORT, REL_X, REL_Y, REL_WHEEL, ABS_X, ABS_Y,
];
#[used]
static _BUTTONS: [u16; 2] = [BTN_MISC, BTN_TASK];
#[used]
static _EXTRA: [u16; 1] = [REL_HWHEEL];

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
    fn touch_axes_clamp_and_pass_through() {
        assert_eq!(scale_touch(-5, 19200), 0);
        assert_eq!(scale_touch(20000, 19200), TOUCH_RANGE);
        assert_eq!(scale_touch(2, 0), 2);
        assert_eq!(scale_touch(-1, 0), -1);
    }
}
