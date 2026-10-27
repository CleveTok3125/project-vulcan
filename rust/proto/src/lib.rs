use std::io::{self, Read, Write};

pub const KIND_PASSTHROUGH: u8 = 0;
pub const KIND_KEYBOARD: u8 = 1;
pub const KIND_MOUSE: u8 = 2;
pub const KIND_MOUSE_ABSOLUTE: u8 = 3;
pub const KIND_TOUCH: u8 = 4;
pub const KIND_PEN: u8 = 5;
pub const KIND_GAMEPAD: u8 = 6;

pub const EV_SYN: u16 = 0;
pub const EV_KEY: u16 = 1;
pub const EV_REL: u16 = 2;
pub const EV_ABS: u16 = 3;
pub const SYN_REPORT: u16 = 0;
pub const REL_X: u16 = 0;
pub const REL_Y: u16 = 1;
pub const REL_HWHEEL: u16 = 6;
pub const REL_WHEEL: u16 = 8;
pub const ABS_X: u16 = 0;
pub const ABS_Y: u16 = 1;
pub const ABS_Z: u16 = 2;
pub const ABS_RX: u16 = 3;
pub const ABS_RY: u16 = 4;
pub const ABS_RZ: u16 = 5;
pub const ABS_HAT0X: u16 = 0x10;
pub const ABS_HAT0Y: u16 = 0x11;
pub const BTN_MISC: u16 = 0x100;
pub const BTN_TASK: u16 = 0x117;
pub const BTN_SOUTH: u16 = 0x130;
pub const BTN_EAST: u16 = 0x131;
pub const BTN_NORTH: u16 = 0x133;
pub const BTN_WEST: u16 = 0x134;
pub const BTN_TL: u16 = 0x136;
pub const BTN_TR: u16 = 0x137;
pub const BTN_SELECT: u16 = 0x13a;
pub const BTN_START: u16 = 0x13b;
pub const BTN_MODE: u16 = 0x13c;
pub const BTN_THUMBL: u16 = 0x13d;
pub const BTN_THUMBR: u16 = 0x13e;
pub const BTN_DPAD_UP: u16 = 0x220;
pub const BTN_DPAD_DOWN: u16 = 0x221;
pub const BTN_DPAD_LEFT: u16 = 0x222;
pub const BTN_DPAD_RIGHT: u16 = 0x223;
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_LEFTALT: u16 = 56;
pub const KEY_LEFTMETA: u16 = 125;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_RIGHTSHIFT: u16 = 54;
pub const KEY_RIGHTALT: u16 = 100;
pub const KEY_RIGHTMETA: u16 = 126;
pub const KEY_CAPSLOCK: u16 = 58;
pub const KEY_NUMLOCK: u16 = 69;

pub const WIRE_LEN: usize = 9;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Event {
    pub kind: u8,
    pub event_type: u16,
    pub code: u16,
    pub value: i32,
}

impl Event {
    pub fn to_bytes(self) -> [u8; WIRE_LEN] {
        let mut out = [0u8; WIRE_LEN];
        out[0] = self.kind;
        out[1..3].copy_from_slice(&self.event_type.to_le_bytes());
        out[3..5].copy_from_slice(&self.code.to_le_bytes());
        out[5..9].copy_from_slice(&self.value.to_le_bytes());
        out
    }

    pub fn from_bytes(bytes: &[u8; WIRE_LEN]) -> Self {
        Self {
            kind: bytes[0],
            event_type: u16::from_le_bytes([bytes[1], bytes[2]]),
            code: u16::from_le_bytes([bytes[3], bytes[4]]),
            value: i32::from_le_bytes([bytes[5], bytes[6], bytes[7], bytes[8]]),
        }
    }

    pub fn write_to<W: Write>(self, writer: &mut W) -> io::Result<()> {
        writer.write_all(&self.to_bytes())
    }

    pub fn read_from<R: Read>(reader: &mut R) -> io::Result<Self> {
        let mut bytes = [0u8; WIRE_LEN];
        reader.read_exact(&mut bytes)?;
        Ok(Self::from_bytes(&bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_roundtrip_preserves_fields() {
        let event = Event {
            kind: KIND_MOUSE_ABSOLUTE,
            event_type: EV_ABS,
            code: ABS_X,
            value: 1234,
        };
        assert_eq!(Event::from_bytes(&event.to_bytes()), event);
    }
}
