//! Reader for the input device tree in sysfs.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub const SYSFS_INPUT: &str = "/sys/class/input";

/// One input event device, as reported by sysfs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventDevice {
    /// Kernel name, for example `event24`.
    pub event: String,
    /// Name the driver assigned to the device.
    pub name: String,
    /// Character device numbers from `dev`.
    pub major: u32,
    pub minor: u32,
    /// Path below `/sys`, used as `DEVPATH` in the synthetic uevent.
    pub devpath: String,
    /// Creation time in nanoseconds; sysfs stamps it when the device appears.
    pub created_ns: i64,
}

pub fn read_trimmed(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
}

/// Splits the `major:minor` text from the sysfs `dev` attribute.
pub fn parse_dev(text: &str) -> Option<(u32, u32)> {
    let (major, minor) = text.split_once(':')?;
    Some((major.trim().parse().ok()?, minor.trim().parse().ok()?))
}

/// Lists every `event*` device below [`SYSFS_INPUT`].
pub fn event_devices() -> Vec<EventDevice> {
    let Ok(entries) = fs::read_dir(SYSFS_INPUT) else {
        return Vec::new();
    };

    let mut devices = Vec::new();
    for entry in entries.flatten() {
        let event = entry.file_name().to_string_lossy().into_owned();
        if !event.starts_with("event") {
            continue;
        }

        let base = entry.path();
        let Some(name) = read_trimmed(&base.join("device/name")) else {
            continue;
        };
        let Some(dev) = read_trimmed(&base.join("dev")) else {
            continue;
        };
        let Some((major, minor)) = parse_dev(&dev) else {
            continue;
        };

        let devpath = fs::canonicalize(&base)
            .ok()
            .and_then(|path| {
                path.strip_prefix("/sys")
                    .ok()
                    .map(|path| format!("/{}", path.display()))
            })
            .unwrap_or_default();
        let created_ns = fs::metadata(&base)
            .map(|meta| meta.ctime() * 1_000_000_000 + meta.ctime_nsec())
            .unwrap_or(0);

        devices.push(EventDevice {
            event,
            name,
            major,
            minor,
            devpath,
            created_ns,
        });
    }
    devices.sort_by_key(|device| device.created_ns);
    devices
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_numbers() {
        assert_eq!(parse_dev("13:66"), Some((13, 66)));
        assert_eq!(parse_dev(" 13 : 5 "), Some((13, 5)));
        assert_eq!(parse_dev("13"), None);
        assert_eq!(parse_dev("13:x"), None);
    }

    #[test]
    fn reads_trimmed_text() {
        let path = Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/src/sysfs.rs"));
        let text = read_trimmed(path).unwrap();
        assert!(text.starts_with("//! Reader"));
        assert!(!text.ends_with('\n'));
    }
}
