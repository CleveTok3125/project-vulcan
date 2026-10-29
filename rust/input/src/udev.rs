//! Udev database records and synthetic kernel events for input nodes.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::mem;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

pub const MAJOR_INPUT: u32 = 13;

const NETLINK_KOBJECT_UEVENT: i32 = 15;
const UDEV_GROUP: u32 = 2;
const UDEV_DATA: &str = "/run/udev/data";
const UDEV_CONTROL: &str = "/run/udev/control";

/// Device classes the broker and the bridge can expose.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceType {
    Mouse,
    Keyboard,
    Touchscreen,
    Tablet,
    Joystick,
}

impl DeviceType {
    /// Udev property that marks the device class.
    pub fn property(self) -> &'static str {
        match self {
            DeviceType::Mouse => "ID_INPUT_MOUSE",
            DeviceType::Keyboard => "ID_INPUT_KEYBOARD",
            DeviceType::Touchscreen => "ID_INPUT_TOUCHSCREEN",
            DeviceType::Tablet => "ID_INPUT_TABLET",
            DeviceType::Joystick => "ID_INPUT_JOYSTICK",
        }
    }

    /// Lowercase name used in log lines.
    pub fn label(self) -> &'static str {
        match self {
            DeviceType::Mouse => "mouse",
            DeviceType::Keyboard => "keyboard",
            DeviceType::Touchscreen => "touchscreen",
            DeviceType::Tablet => "tablet",
            DeviceType::Joystick => "joystick",
        }
    }
}

pub fn ensure_runtime_dirs() -> io::Result<()> {
    fs::create_dir_all("/dev/input")?;
    fs::create_dir_all(UDEV_DATA)?;
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(UDEV_CONTROL)?;
    Ok(())
}

/// Builds the record udev stores below `/run/udev/data`.
pub fn database_record(devname: &str, minor: u32, device_type: DeviceType) -> String {
    let entries = [
        format!("E:DEVNAME=/dev/{devname}"),
        format!("E:MAJOR={MAJOR_INPUT}"),
        format!("E:MINOR={minor}"),
        "E:SUBSYSTEM=input".to_string(),
        "E:ID_INPUT=1".to_string(),
        format!("E:{}=1", device_type.property()),
        "E:ID_SEAT=seat0".to_string(),
    ];
    let mut record = entries.join("\n");
    record.push('\n');
    record
}

pub fn write_database(devname: &str, minor: u32, device_type: DeviceType) -> io::Result<()> {
    let path = format!("{UDEV_DATA}/c{MAJOR_INPUT}:{minor}");
    let mut file = File::create(path)?;
    file.write_all(database_record(devname, minor, device_type).as_bytes())
}

/// Builds the payload libinput reads from the kernel uevent socket.
pub fn uevent_payload(
    devpath: &str,
    devname: &str,
    minor: u32,
    device_type: DeviceType,
    seqnum: u32,
) -> Vec<u8> {
    let properties = [
        "ACTION=add".to_string(),
        format!("DEVPATH={devpath}"),
        "SUBSYSTEM=input".to_string(),
        format!("DEVNAME={devname}"),
        format!("MAJOR={MAJOR_INPUT}"),
        format!("MINOR={minor}"),
        "ID_INPUT=1".to_string(),
        format!("{}=1", device_type.property()),
        "ID_SEAT=seat0".to_string(),
        format!("SEQNUM={seqnum}"),
    ];
    format!("add@{devpath}\0{}\0", properties.join("\0")).into_bytes()
}

/// Sends one `add` event to the kernel uevent socket.
pub fn send_uevent(
    devpath: &str,
    devname: &str,
    minor: u32,
    device_type: DeviceType,
    seqnum: u32,
) -> io::Result<()> {
    let payload = uevent_payload(devpath, devname, minor, device_type, seqnum);

    // NETLINK_KOBJECT_UEVENT carries the uevent only when the socket is bound,
    // and only root with CAP_NET_ADMIN may send to the kernel group.
    let raw = unsafe {
        libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_RAW | libc::SOCK_CLOEXEC,
            NETLINK_KOBJECT_UEVENT,
        )
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let socket = unsafe { OwnedFd::from_raw_fd(raw) };

    let local: libc::sockaddr_nl = unsafe { mem::zeroed() };
    let bound = unsafe {
        libc::bind(
            socket.as_raw_fd(),
            &local as *const libc::sockaddr_nl as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        )
    };
    if bound < 0 {
        return Err(io::Error::last_os_error());
    }

    let mut kernel: libc::sockaddr_nl = unsafe { mem::zeroed() };
    kernel.nl_family = libc::AF_NETLINK as libc::sa_family_t;
    kernel.nl_groups = UDEV_GROUP;
    let sent = unsafe {
        libc::sendto(
            socket.as_raw_fd(),
            payload.as_ptr() as *const libc::c_void,
            payload.len(),
            0,
            &kernel as *const libc::sockaddr_nl as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
        )
    };
    if sent < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_lists_the_device_class() {
        let record = database_record("input/event24", 66, DeviceType::Mouse);
        assert_eq!(
            record,
            "E:DEVNAME=/dev/input/event24\n\
             E:MAJOR=13\n\
             E:MINOR=66\n\
             E:SUBSYSTEM=input\n\
             E:ID_INPUT=1\n\
             E:ID_INPUT_MOUSE=1\n\
             E:ID_SEAT=seat0\n"
        );
    }

    #[test]
    fn payload_starts_with_the_action_and_devpath() {
        let payload = uevent_payload(
            "/devices/virtual/input/input7/event7",
            "input/event7",
            66,
            DeviceType::Joystick,
            3,
        );
        assert_eq!(
            payload,
            b"add@/devices/virtual/input/input7/event7\0\
              ACTION=add\0\
              DEVPATH=/devices/virtual/input/input7/event7\0\
              SUBSYSTEM=input\0\
              DEVNAME=input/event7\0\
              MAJOR=13\0\
              MINOR=66\0\
              ID_INPUT=1\0\
              ID_INPUT_JOYSTICK=1\0\
              ID_SEAT=seat0\0\
              SEQNUM=3\0"
                .to_vec()
        );
    }
}
