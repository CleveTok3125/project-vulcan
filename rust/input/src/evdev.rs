//! evdev constants and wire formats used by the XTest bridge.

use std::mem::size_of;

pub const EV_KEY: u16 = 1;
pub const EV_REL: u16 = 2;
pub const EV_ABS: u16 = 3;

pub const REL_X: u16 = 0;
pub const REL_Y: u16 = 1;
pub const REL_HWHEEL: u16 = 6;
pub const REL_WHEEL: u16 = 8;

pub const ABS_X: u16 = 0;
pub const ABS_Y: u16 = 1;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;
pub const BTN_TOUCH: u16 = 0x14a;

/// Size of `struct input_event` on 64-bit Linux.
pub const EVENT_SIZE: usize = 24;

const IOC_READ: u32 = 2;
const IOC_WRITE: u32 = 1;

/// One decoded `struct input_event`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InputEvent {
    pub kind: u16,
    pub code: u16,
    pub value: i32,
}

/// Layout of `struct input_absinfo`, returned by `EVIOCGABS`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct AbsInfo {
    pub value: i32,
    pub minimum: i32,
    pub maximum: i32,
    pub fuzz: i32,
    pub flat: i32,
    pub resolution: i32,
}

/// Decodes one `struct input_event`; the timestamp is not used.
pub fn parse_event(bytes: &[u8]) -> Option<InputEvent> {
    let bytes: &[u8; EVENT_SIZE] = bytes.get(..EVENT_SIZE)?.try_into().ok()?;
    Some(InputEvent {
        kind: u16::from_ne_bytes([bytes[16], bytes[17]]),
        code: u16::from_ne_bytes([bytes[18], bytes[19]]),
        value: i32::from_ne_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]),
    })
}

/// Maps an evdev button code to the X pointer button number.
pub fn mouse_button(code: u16) -> Option<u16> {
    match code {
        BTN_LEFT | BTN_TOUCH => Some(1),
        BTN_MIDDLE => Some(2),
        BTN_RIGHT => Some(3),
        BTN_SIDE => Some(8),
        BTN_EXTRA => Some(9),
        _ => None,
    }
}

/// Maps a wheel axis to the X button pair used for scroll steps.
pub fn wheel_button(code: u16, value: i32) -> Option<u16> {
    match code {
        REL_WHEEL => Some(if value > 0 { 4 } else { 5 }),
        REL_HWHEEL => Some(if value > 0 { 6 } else { 7 }),
        _ => None,
    }
}

const fn ioc(direction: u32, kind: u8, number: u32, size: u32) -> libc::c_ulong {
    ((direction << 30) | (size << 16) | ((kind as u32) << 8) | number) as libc::c_ulong
}

/// `EVIOCGABS(axis)`: reads the range of an absolute axis.
pub const fn eviocgabs(axis: u16) -> libc::c_ulong {
    ioc(
        IOC_READ,
        b'E',
        0x40 + axis as u32,
        size_of::<AbsInfo>() as u32,
    )
}

/// `EVIOCGRAB`: takes the device away from every other reader.
pub const fn eviocgrab() -> libc::c_ulong {
    ioc(IOC_WRITE, b'E', 0x90, size_of::<libc::c_int>() as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event_bytes(kind: u16, code: u16, value: i32) -> Vec<u8> {
        let mut bytes = vec![0u8; EVENT_SIZE];
        bytes[16..18].copy_from_slice(&kind.to_ne_bytes());
        bytes[18..20].copy_from_slice(&code.to_ne_bytes());
        bytes[20..24].copy_from_slice(&value.to_ne_bytes());
        bytes
    }

    #[test]
    fn decodes_an_event() {
        let bytes = event_bytes(EV_REL, REL_X, -3);
        assert_eq!(
            parse_event(&bytes),
            Some(InputEvent {
                kind: EV_REL,
                code: REL_X,
                value: -3
            })
        );
    }

    #[test]
    fn rejects_short_buffers() {
        assert_eq!(parse_event(&[0u8; 4]), None);
    }

    #[test]
    fn keeps_the_python_ioctl_values() {
        assert_eq!(eviocgabs(ABS_X), 0x8018_4540);
        assert_eq!(eviocgabs(ABS_Y), 0x8018_4541);
        assert_eq!(eviocgrab(), 0x4004_4590);
    }

    #[test]
    fn maps_buttons() {
        assert_eq!(mouse_button(BTN_LEFT), Some(1));
        assert_eq!(mouse_button(BTN_RIGHT), Some(3));
        assert_eq!(mouse_button(BTN_SIDE), Some(8));
        assert_eq!(mouse_button(BTN_TOUCH), Some(1));
        assert_eq!(mouse_button(0x150), None);
    }

    #[test]
    fn maps_wheel_direction() {
        assert_eq!(wheel_button(REL_WHEEL, 2), Some(4));
        assert_eq!(wheel_button(REL_WHEEL, -1), Some(5));
        assert_eq!(wheel_button(REL_HWHEEL, 1), Some(6));
        assert_eq!(wheel_button(REL_HWHEEL, -4), Some(7));
        assert_eq!(wheel_button(REL_X, 1), None);
    }
}
