//! Exposes the input devices Apollo created for this session.
//!
//! Apollo creates uinput devices in the shared kernel. The container has its
//! own `/dev` tmpfs, so the event nodes the host udev instance creates are not
//! visible inside the container. This helper copies the expected nodes into
//! `/dev/input` and publishes matching udev records and netlink events so
//! libinput can hotplug them.
//!
//! Two sessions on one host share the kernel input tree, so the broker only
//! takes devices that appeared after it started. Devices another session
//! created earlier are part of the baseline and stay invisible.

use std::collections::HashSet;
use std::env;
use std::ffi::CString;
use std::fs;
use std::io;
use std::thread::sleep;
use std::time::Duration;

use vulcan_input::caps::{self, CAP_MKNOD, CAP_NET_ADMIN};
use vulcan_input::sysfs::{self, EventDevice};
use vulcan_input::udev::{self, DeviceType, MAJOR_INPUT};

const INPUT_DIR: &str = "/dev/input";
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Fixed names inputtino gives the devices Apollo injects input through.
pub fn classify(name: &str, extra_names: &[String]) -> Option<DeviceType> {
    match name {
        "Mouse passthrough" | "Mouse passthrough (absolute)" => Some(DeviceType::Mouse),
        "Keyboard passthrough" => Some(DeviceType::Keyboard),
        "Touch passthrough" => Some(DeviceType::Touchscreen),
        "Pen passthrough" => Some(DeviceType::Tablet),
        other if extra_names.iter().any(|extra| extra == other) => Some(DeviceType::Joystick),
        _ => None,
    }
}

fn env_u32(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(default)
}

fn extra_names() -> Vec<String> {
    env::var("INPUT_EXTRA_NAMES")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .collect()
}

fn expose(
    device: &EventDevice,
    device_type: DeviceType,
    input_gid: u32,
    seqnum: &mut u32,
) -> io::Result<()> {
    let devname = format!("input/{}", device.event);
    let node = format!("{INPUT_DIR}/{}", device.event);

    let _ = fs::remove_file(&node);
    let node_path = CString::new(node.clone())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let mode = libc::S_IFCHR | 0o666;
    let dev = libc::makedev(device.major, device.minor);
    if unsafe { libc::mknod(node_path.as_ptr(), mode, dev) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::chown(node_path.as_ptr(), 0, input_gid) } != 0 {
        eprintln!(
            "[vulcan-input-broker] chown {node} failed: {}",
            io::Error::last_os_error()
        );
    }
    if unsafe { libc::chmod(node_path.as_ptr(), 0o666) } != 0 {
        eprintln!(
            "[vulcan-input-broker] chmod {node} failed: {}",
            io::Error::last_os_error()
        );
    }

    udev::write_database(&devname, device.minor, device_type)?;
    *seqnum += 1;
    udev::send_uevent(
        &device.devpath,
        &devname,
        device.minor,
        device_type,
        *seqnum,
    )?;
    println!("exposed {node} as {}", device_type.label());
    Ok(())
}

fn main() -> io::Result<()> {
    if let Err(error) = caps::restrict_to(&[CAP_NET_ADMIN, CAP_MKNOD]) {
        eprintln!("[vulcan-input-broker] failed to restrict capabilities: {error}");
        return Err(error);
    }
    println!("capabilities restricted to mknod, net_admin");

    udev::ensure_runtime_dirs()?;
    let input_gid = env_u32("INPUT_GID", 0);
    let extra_names = extra_names();

    let mut seen: HashSet<(String, String)> = sysfs::event_devices()
        .into_iter()
        .map(|device| (device.event, device.name))
        .collect();
    let mut seqnum = 0;

    println!(
        "watching for session input devices; baseline={} input_gid={input_gid}",
        seen.len()
    );

    loop {
        let devices = sysfs::event_devices();
        let live: HashSet<&str> = devices.iter().map(|device| device.event.as_str()).collect();
        seen.retain(|(event, _)| live.contains(event.as_str()));

        for device in &devices {
            if seen.contains(&(device.event.clone(), device.name.clone())) {
                continue;
            }
            if device.major != MAJOR_INPUT {
                println!("skip {}: unexpected major {}", device.event, device.major);
                seen.insert((device.event.clone(), device.name.clone()));
                continue;
            }
            let Some(device_type) = classify(&device.name, &extra_names) else {
                continue;
            };
            if let Err(error) = expose(device, device_type, input_gid, &mut seqnum) {
                eprintln!(
                    "[vulcan-input-broker] failed to expose {} ({}): {error}",
                    device.event, device.name
                );
            }
            seen.insert((device.event.clone(), device.name.clone()));
        }

        sleep(POLL_INTERVAL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extra() -> Vec<String> {
        vec!["Sunshine X-Box One (virtual) pad".to_string()]
    }

    #[test]
    fn classifies_the_passthrough_devices() {
        assert_eq!(classify("Mouse passthrough", &[]), Some(DeviceType::Mouse));
        assert_eq!(
            classify("Mouse passthrough (absolute)", &[]),
            Some(DeviceType::Mouse)
        );
        assert_eq!(
            classify("Keyboard passthrough", &[]),
            Some(DeviceType::Keyboard)
        );
        assert_eq!(
            classify("Touch passthrough", &[]),
            Some(DeviceType::Touchscreen)
        );
        assert_eq!(classify("Pen passthrough", &[]), Some(DeviceType::Tablet));
        assert_eq!(
            classify("Sunshine X-Box One (virtual) pad", &extra()),
            Some(DeviceType::Joystick)
        );
        assert_eq!(classify("AT Translated Set 2 keyboard", &extra()), None);
    }
}
