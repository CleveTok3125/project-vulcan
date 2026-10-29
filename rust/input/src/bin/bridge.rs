//! Forwards session input to the Xwayland display with XTest.
//!
//! Fallback for `INPUT_BACKEND=xtest`. Sway normally runs with a libinput seat
//! and routes devices itself. This bridge is only for setups where libinput
//! cannot open the container input nodes: Sway then runs headless without a
//! seat, and the bridge injects core events into Xwayland.

use std::collections::HashMap;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::thread::sleep;
use std::time::Duration;

use vulcan_input::evdev::{
    self, wheel_button, AbsInfo, InputEvent, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y,
    EV_ABS, EV_KEY, EV_REL, REL_X, REL_Y,
};
use vulcan_input::sysfs;
use vulcan_input::x11::Display;

const INPUT_DIR: &str = "/dev/input";
const POLL_INTERVAL: Duration = Duration::from_millis(250);
const READ_CHUNK: usize = evdev::EVENT_SIZE * 64;

/// Device names the bridge takes over, as reported by inputtino.
const DEVICE_NAMES: [(&str, &str); 4] = [
    ("Keyboard passthrough", "keyboard"),
    ("Mouse passthrough", "mouse"),
    ("Mouse passthrough (absolute)", "mouse_absolute"),
    ("Touch passthrough", "touch"),
];

struct Device {
    file: File,
    buffer: Vec<u8>,
    maximum_x: i32,
    maximum_y: i32,
    x: i32,
    y: i32,
}

fn env_i32(name: &str, default: i32) -> i32 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(default)
}

/// Maps absolute axis values onto screen pixels.
pub fn scale_axis(value: i32, maximum: i32, size: i32) -> i32 {
    let maximum = if maximum <= 0 { 65535 } else { maximum };
    let scaled = (f64::from(value) * f64::from(size - 1) / f64::from(maximum)).round() as i64;
    scaled.clamp(0, i64::from(size - 1)) as i32
}

fn axis_maximum(fd: RawFd, axes: [u16; 2], fallback: i32) -> i32 {
    for axis in axes {
        let mut info = AbsInfo::default();
        let result = unsafe { libc::ioctl(fd, evdev::eviocgabs(axis), &mut info) };
        if result == 0 {
            return if info.maximum > 0 {
                info.maximum
            } else {
                fallback
            };
        }
    }
    fallback
}

/// Collects the nodes the bridge owns, keyed by path.
fn device_nodes() -> HashMap<String, &'static str> {
    let mut nodes = HashMap::new();
    for device in sysfs::event_devices() {
        if let Some((_, kind)) = DEVICE_NAMES
            .iter()
            .find(|(name, _)| *name == device.name.as_str())
        {
            nodes.insert(format!("{INPUT_DIR}/{}", device.event), *kind);
        }
    }
    nodes
}

fn open_device(path: &str) -> Option<Device> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let fd = file.as_raw_fd();

    let grab: libc::c_int = 1;
    let result = unsafe { libc::ioctl(fd, evdev::eviocgrab(), &grab) };
    if result == 0 {
        println!("grabbed {path}");
    } else {
        eprintln!("could not grab {path}: {}", io::Error::last_os_error());
    }

    Some(Device {
        maximum_x: axis_maximum(fd, [ABS_X, ABS_MT_POSITION_X], 65535),
        maximum_y: axis_maximum(fd, [ABS_Y, ABS_MT_POSITION_Y], 65535),
        file,
        buffer: Vec::with_capacity(READ_CHUNK),
        x: 0,
        y: 0,
    })
}

fn handle_event(
    display: &Display,
    event: InputEvent,
    device: &mut Device,
    width: i32,
    height: i32,
) -> bool {
    match event.kind {
        EV_KEY => {
            if let Some(button) = evdev::mouse_button(event.code) {
                display.button(button, event.value != 0);
                return true;
            }
            if event.code < 0x100 {
                display.key(event.code, event.value != 0);
                return true;
            }
            false
        }
        EV_ABS => {
            if event.code == ABS_X || event.code == ABS_MT_POSITION_X {
                device.x = scale_axis(event.value, device.maximum_x, width);
                display.absolute_motion(device.x, device.y);
                return true;
            }
            if event.code == ABS_Y || event.code == ABS_MT_POSITION_Y {
                device.y = scale_axis(event.value, device.maximum_y, height);
                display.absolute_motion(device.x, device.y);
                return true;
            }
            false
        }
        EV_REL => {
            if event.code == REL_X {
                display.relative_motion(event.value, 0);
                return true;
            }
            if event.code == REL_Y {
                display.relative_motion(0, event.value);
                return true;
            }
            if let Some(button) = wheel_button(event.code, event.value) {
                for _ in 0..event.value.unsigned_abs() {
                    display.button(button, true);
                    display.button(button, false);
                }
                return true;
            }
            false
        }
        _ => false,
    }
}

/// Drains the buffered events of one device into the display.
fn drain_device(display: &Display, device: &mut Device, width: i32, height: i32) -> bool {
    let mut emitted = false;
    while device.buffer.len() >= evdev::EVENT_SIZE {
        let mut raw = [0u8; evdev::EVENT_SIZE];
        raw.copy_from_slice(&device.buffer[..evdev::EVENT_SIZE]);
        device.buffer.drain(..evdev::EVENT_SIZE);
        let Some(event) = evdev::parse_event(&raw) else {
            continue;
        };
        if handle_event(display, event, device, width, height) {
            emitted = true;
        }
    }
    emitted
}

fn main() -> io::Result<()> {
    let display_name = env::var("DISPLAY").unwrap_or_else(|_| ":2".to_string());
    let width = env_i32("GAME_WIDTH", 1920);
    let height = env_i32("GAME_HEIGHT", 1080);

    let mut display: Option<Display> = None;
    let mut devices: HashMap<String, Device> = HashMap::new();

    println!("watching input devices for display {display_name}");

    loop {
        if display.is_none() {
            match Display::open(&display_name) {
                Some(opened) => {
                    println!("connected to X display {display_name}");
                    display = Some(opened);
                }
                None => {
                    println!("waiting for X display {display_name}");
                    sleep(Duration::from_secs(1));
                    continue;
                }
            }
        }

        let wanted = device_nodes();
        devices.retain(|path, _| wanted.contains_key(path));
        for (path, kind) in &wanted {
            if devices.contains_key(path) {
                continue;
            }
            if let Some(device) = open_device(path) {
                println!("opened {path} as {kind}");
                devices.insert(path.clone(), device);
            }
        }

        if devices.is_empty() {
            sleep(POLL_INTERVAL);
            continue;
        }

        let mut paths: Vec<String> = Vec::with_capacity(devices.len());
        let mut poll_fds: Vec<libc::pollfd> = Vec::with_capacity(devices.len());
        for (path, device) in &devices {
            paths.push(path.clone());
            poll_fds.push(libc::pollfd {
                fd: device.file.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
        }

        let ready = unsafe {
            libc::poll(
                poll_fds.as_mut_ptr(),
                poll_fds.len() as libc::nfds_t,
                POLL_INTERVAL.as_millis() as libc::c_int,
            )
        };
        if ready < 0 {
            eprintln!("poll failed: {}", io::Error::last_os_error());
            sleep(POLL_INTERVAL);
            continue;
        }
        if ready == 0 {
            continue;
        }

        let mut emitted = false;
        let mut gone: Vec<String> = Vec::new();
        for (index, path) in paths.iter().enumerate() {
            if poll_fds[index].revents == 0 {
                continue;
            }
            let Some(device) = devices.get_mut(path) else {
                continue;
            };
            let mut chunk = [0u8; READ_CHUNK];
            match device.file.read(&mut chunk) {
                Ok(0) => {
                    gone.push(path.clone());
                    continue;
                }
                Ok(count) => device.buffer.extend_from_slice(&chunk[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                Err(error) => {
                    eprintln!("read {path} failed: {error}");
                    gone.push(path.clone());
                    continue;
                }
            }

            let Some(display) = display.as_ref() else {
                break;
            };
            if drain_device(display, device, width, height) {
                emitted = true;
            }
        }

        for path in gone {
            devices.remove(&path);
        }
        if emitted {
            if let Some(display) = display.as_ref() {
                display.flush();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_absolute_axes() {
        assert_eq!(scale_axis(0, 65535, 1920), 0);
        assert_eq!(scale_axis(65535, 65535, 1920), 1919);
        assert_eq!(scale_axis(32767, 65535, 1920), 959);
    }

    #[test]
    fn clamps_out_of_range_values() {
        assert_eq!(scale_axis(-100, 65535, 1920), 0);
        assert_eq!(scale_axis(90000, 65535, 1920), 1919);
    }

    #[test]
    fn falls_back_to_the_full_range() {
        assert_eq!(scale_axis(65535, 0, 1920), 1919);
    }
}
