//! Capability drop for the broker process.

use std::io;

pub const CAP_NET_ADMIN: u32 = 12;
pub const CAP_MKNOD: u32 = 27;

const LINUX_CAPABILITY_VERSION_3: u32 = 0x2008_0522;

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

/// Drops every capability the process does not list in `keep`.
///
/// The broker keeps only `MKNOD` for the event nodes and `NET_ADMIN` for the
/// synthetic uevent, which it sends inside its own network namespace.
pub fn restrict_to(keep: &[u32]) -> io::Result<()> {
    let mut mask: u64 = 0;
    for capability in keep {
        if *capability < 64 {
            mask |= 1 << capability;
        }
    }

    let mut header = CapHeader {
        version: LINUX_CAPABILITY_VERSION_3,
        pid: 0,
    };
    let mut data = [CapData::default(); 2];
    for (index, entry) in data.iter_mut().enumerate() {
        let word = (mask >> (index * 32)) as u32;
        entry.effective = word;
        entry.permitted = word;
        entry.inheritable = 0;
    }

    let result = unsafe {
        libc::syscall(
            libc::SYS_capset,
            &mut header as *mut CapHeader,
            data.as_mut_ptr(),
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem;

    fn mask_of(keep: &[u32]) -> u64 {
        keep.iter()
            .filter(|capability| **capability < 64)
            .fold(0, |mask, capability| mask | (1 << capability))
    }

    #[test]
    fn keeps_only_the_requested_capabilities() {
        assert_eq!(mask_of(&[CAP_MKNOD, CAP_NET_ADMIN]), (1 << 27) | (1 << 12));
    }

    #[test]
    fn ignores_capabilities_above_the_first_word() {
        assert_eq!(mask_of(&[40, 64, 63]), (1 << 63) | (1 << 40));
    }

    #[test]
    fn cap_data_is_two_words() {
        assert_eq!(mem::size_of::<CapData>(), 12);
        assert_eq!(mem::size_of::<[CapData; 2]>(), 24);
    }
}
