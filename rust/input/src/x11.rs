//! Minimal X11 and XTest bindings for the xtest input backend.

use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void, CString};

#[link(name = "X11")]
extern "C" {
    fn XOpenDisplay(name: *const c_char) -> *mut c_void;
    fn XFlush(display: *mut c_void) -> c_int;
    fn XCloseDisplay(display: *mut c_void) -> c_int;
}

#[link(name = "Xtst")]
extern "C" {
    fn XTestFakeKeyEvent(
        display: *mut c_void,
        keycode: c_uint,
        pressed: c_int,
        delay: c_ulong,
    ) -> c_int;
    fn XTestFakeButtonEvent(
        display: *mut c_void,
        button: c_uint,
        pressed: c_int,
        delay: c_ulong,
    ) -> c_int;
    fn XTestFakeRelativeMotionEvent(
        display: *mut c_void,
        dx: c_int,
        dy: c_int,
        delay: c_ulong,
    ) -> c_int;
    fn XTestFakeMotionEvent(
        display: *mut c_void,
        screen: c_int,
        x: c_int,
        y: c_int,
        delay: c_ulong,
    ) -> c_int;
}

/// Open connection to an X server.
pub struct Display {
    raw: *mut c_void,
}

impl Display {
    pub fn open(name: &str) -> Option<Display> {
        let name = CString::new(name).ok()?;
        let raw = unsafe { XOpenDisplay(name.as_ptr()) };
        (!raw.is_null()).then_some(Display { raw })
    }

    /// Sends a key press or release; evdev codes map to X codes with +8.
    pub fn key(&self, keycode: u16, pressed: bool) {
        if keycode > 0 && keycode < 248 {
            unsafe {
                XTestFakeKeyEvent(self.raw, keycode as c_uint + 8, c_int::from(pressed), 0);
            }
        }
    }

    pub fn button(&self, button: u16, pressed: bool) {
        unsafe {
            XTestFakeButtonEvent(self.raw, button as c_uint, c_int::from(pressed), 0);
        }
    }

    pub fn relative_motion(&self, dx: i32, dy: i32) {
        if dx != 0 || dy != 0 {
            unsafe {
                XTestFakeRelativeMotionEvent(self.raw, dx, dy, 0);
            }
        }
    }

    pub fn absolute_motion(&self, x: i32, y: i32) {
        unsafe {
            XTestFakeMotionEvent(self.raw, 0, x, y, 0);
        }
    }

    pub fn flush(&self) {
        unsafe {
            XFlush(self.raw);
        }
    }
}

impl Drop for Display {
    fn drop(&mut self) {
        unsafe {
            XCloseDisplay(self.raw);
        }
    }
}
