//! Cemuhook UDP (DSU) server for the Vulcan gamepad state file.
//!
//! Eden and Cemu read controller input over this protocol, so the pad stays out
//! of the kernel: `vulcan-inputd` keeps writing the state file that the XInput
//! proxy already reads, and this module serves the same bytes over UDP.
//!
//! The wire format mirrors the client in
//! `src/input_common/helpers/udp_protocol.h` of the yuzu lineage: a 20-byte
//! header, a CRC-32 over the whole message, and one payload per message type.

/// Protocol version the clients send and expect.
pub const PROTOCOL_VERSION: u16 = 1001;

use std::net::SocketAddr;
use std::time::{Duration, Instant};

const MAGIC_CLIENT: u32 = 0x4355_5344; // "DSUC"
const MAGIC_SERVER: u32 = 0x5355_5344; // "DSUS"

/// Message types the server answers.
pub const TYPE_VERSION: u32 = 0x0010_0000;
pub const TYPE_PORT_INFO: u32 = 0x0010_0001;
pub const TYPE_PAD_DATA: u32 = 0x0010_0002;

/// Length of the message header.
pub const HEADER_LEN: usize = 20;

/// Ports reported in a `PortInfo` response.
///
/// The protocol reserves four ports, but both Eden and Cemu accept exactly one
/// 12-byte entry and reject a longer payload.
pub const PORT_COUNT: usize = 1;

/// CRC-32 of the message with the checksum field left at zero.
const CRC_OFFSET: usize = 8;

/// Interval between pushed pad data responses.
///
/// The protocol is server driven: a client sends one request, then expects
/// samples at this rate until it asks again. A request-response server updates
/// the client only once per request, which is three seconds here.
pub const PUSH_INTERVAL: Duration = Duration::from_millis(4);

/// How long a client stays subscribed without sending a new request.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Magic of the record `vulcan-inputd` writes.
pub const PAD_STATE_MAGIC: u32 = 0x5647_5031;

/// Byte length of the record `vulcan-inputd` writes.
pub const PAD_STATE_LEN: usize = 28;

/// XInput button bits the record stores.
const XINPUT_DPAD_UP: u16 = 0x0001;
const XINPUT_DPAD_DOWN: u16 = 0x0002;
const XINPUT_DPAD_LEFT: u16 = 0x0004;
const XINPUT_DPAD_RIGHT: u16 = 0x0008;
const XINPUT_START: u16 = 0x0010;
const XINPUT_BACK: u16 = 0x0020;
const XINPUT_LEFT_THUMB: u16 = 0x0040;
const XINPUT_RIGHT_THUMB: u16 = 0x0080;
const XINPUT_LEFT_SHOULDER: u16 = 0x0100;
const XINPUT_RIGHT_SHOULDER: u16 = 0x0200;
const XINPUT_GUIDE: u16 = 0x0400;
const XINPUT_A: u16 = 0x1000;
const XINPUT_B: u16 = 0x2000;
const XINPUT_X: u16 = 0x4000;
const XINPUT_Y: u16 = 0x8000;

/// Axis byte the protocol carries for a centered stick.
const STICK_CENTER: u8 = 128;

/// Trigger value that counts as a press, matching `XINPUT_GAMEPAD_TRIGGER_THRESHOLD`.
///
/// The protocol carries the trigger both as this bit and as an analog byte, and
/// the client reads the bit, so a resting trigger above zero must not report a
/// press.
const TRIGGER_PRESS_THRESHOLD: u8 = 30;

/// DSU digital button bits, in the order the protocol assigns them.
const DSU_SHARE: u16 = 1 << 0;
const DSU_LEFT_THUMB: u16 = 1 << 1;
const DSU_RIGHT_THUMB: u16 = 1 << 2;
const DSU_OPTIONS: u16 = 1 << 3;
const DSU_DPAD_UP: u16 = 1 << 4;
const DSU_DPAD_RIGHT: u16 = 1 << 5;
const DSU_DPAD_DOWN: u16 = 1 << 6;
const DSU_DPAD_LEFT: u16 = 1 << 7;
const DSU_LEFT_TRIGGER: u16 = 1 << 8;
const DSU_RIGHT_TRIGGER: u16 = 1 << 9;
const DSU_LEFT_SHOULDER: u16 = 1 << 10;
const DSU_RIGHT_SHOULDER: u16 = 1 << 11;
const DSU_TRIANGLE: u16 = 1 << 12;
const DSU_CIRCLE: u16 = 1 << 13;
const DSU_CROSS: u16 = 1 << 14;
const DSU_SQUARE: u16 = 1 << 15;

/// Request messages the server understands.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Request {
    pub id: u32,
    pub message_type: u32,
}

/// Controller state as `vulcan-inputd` writes it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PadState {
    pub buttons: u16,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub thumb_lx: i16,
    pub thumb_ly: i16,
    pub thumb_rx: i16,
    pub thumb_ry: i16,
    pub connected: bool,
}

/// Parses a client request header.
///
/// Unknown and malformed messages return `None`; a client sends Version,
/// PortInfo, and PadData requests only.
pub fn parse_request(message: &[u8]) -> Option<Request> {
    if message.len() < HEADER_LEN {
        return None;
    }
    let magic = u32::from_le_bytes(message[0..4].try_into().ok()?);
    let version = u16::from_le_bytes(message[4..6].try_into().ok()?);
    let declared_len = u16::from_le_bytes(message[6..8].try_into().ok()?);
    if magic != MAGIC_CLIENT || version != PROTOCOL_VERSION {
        return None;
    }
    // The declared length counts the message type as well as the payload.
    let payload_len = usize::from(declared_len).saturating_sub(4);
    if HEADER_LEN + payload_len > message.len() {
        return None;
    }
    let id = u32::from_le_bytes(message[12..16].try_into().ok()?);
    let message_type = u32::from_le_bytes(message[16..20].try_into().ok()?);
    match message_type {
        TYPE_VERSION | TYPE_PORT_INFO | TYPE_PAD_DATA => Some(Request { id, message_type }),
        _ => None,
    }
}

/// Parses the state record, returning `None` when it is missing or stale.
pub fn parse_pad_state(record: &[u8]) -> Option<PadState> {
    if record.len() < PAD_STATE_LEN {
        return None;
    }
    let magic = u32::from_le_bytes(record[0..4].try_into().ok()?);
    if magic != PAD_STATE_MAGIC {
        return None;
    }
    Some(PadState {
        buttons: u16::from_le_bytes(record[8..10].try_into().ok()?),
        left_trigger: record[10],
        right_trigger: record[11],
        thumb_lx: i16::from_le_bytes(record[12..14].try_into().ok()?),
        thumb_ly: i16::from_le_bytes(record[14..16].try_into().ok()?),
        thumb_rx: i16::from_le_bytes(record[16..18].try_into().ok()?),
        thumb_ry: i16::from_le_bytes(record[18..20].try_into().ok()?),
        connected: record[20] != 0,
    })
}

/// Builds the response for a request.
///
/// `pad` is `None` while the record is unreadable; the server then reports a
/// disconnected pad instead of failing the request. `counter` advances with
/// every pad data response, which the client uses to detect new samples.
pub fn build_response(
    request: Request,
    pad: Option<&PadState>,
    counter: &mut u32,
) -> Option<Vec<u8>> {
    let payload = match request.message_type {
        TYPE_VERSION => version_payload().to_vec(),
        TYPE_PORT_INFO => port_info_payload(pad).to_vec(),
        TYPE_PAD_DATA => {
            *counter = counter.wrapping_add(1);
            pad_data_payload(pad, *counter).to_vec()
        }
        _ => return None,
    };
    let mut message = vec![0u8; HEADER_LEN + payload.len()];
    message[0..4].copy_from_slice(&MAGIC_SERVER.to_le_bytes());
    message[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    let declared_len = u32::try_from(payload.len() + 4).ok()?;
    message[6..8].copy_from_slice(&u16::try_from(declared_len).ok()?.to_le_bytes());
    message[12..16].copy_from_slice(&request.id.to_le_bytes());
    message[16..20].copy_from_slice(&request.message_type.to_le_bytes());
    message[HEADER_LEN..].copy_from_slice(&payload);
    let crc = crc32(&message);
    message[CRC_OFFSET..CRC_OFFSET + 4].copy_from_slice(&crc.to_le_bytes());
    Some(message)
}

/// CRC-32 (IEEE 802.3) as the protocol's `boost::crc_32_type` computes it.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn version_payload() -> [u8; 2] {
    PROTOCOL_VERSION.to_le_bytes()
}

fn port_info_payload(pad: Option<&PadState>) -> [u8; PORT_COUNT * 12] {
    let mut out = [0u8; PORT_COUNT * 12];
    if let Some(pad) = pad {
        if pad.connected {
            out[0..12].copy_from_slice(&port_entry(0, true));
        }
    }
    out
}

fn pad_data_payload(pad: Option<&PadState>, counter: u32) -> [u8; 80] {
    let mut out = [0u8; 80];
    let connected = pad.is_some_and(|pad| pad.connected);
    out[0..12].copy_from_slice(&port_entry(0, connected));
    out[12..16].copy_from_slice(&counter.to_le_bytes());
    // The client marks the pad connected from the packet itself and applies the
    // axes without reading the state byte, so a disconnected pad still has to
    // report centered sticks instead of the zero bytes that mean full deflection.
    out[20..24].fill(STICK_CENTER);
    let Some(pad) = pad.filter(|pad| pad.connected) else {
        return out;
    };

    out[16..18].copy_from_slice(&digital_buttons(pad).to_le_bytes());
    out[18] = u8::from(pad.buttons & XINPUT_GUIDE != 0);
    out[20] = stick_byte(pad.thumb_lx);
    out[21] = stick_byte(pad.thumb_ly);
    out[22] = stick_byte(pad.thumb_rx);
    out[23] = stick_byte(pad.thumb_ry);

    // Analog buttons follow the digital ones so clients that read either path
    // see the same press.
    out[24] = analog(pad, XINPUT_DPAD_LEFT);
    out[25] = analog(pad, XINPUT_DPAD_DOWN);
    out[26] = analog(pad, XINPUT_DPAD_RIGHT);
    out[27] = analog(pad, XINPUT_DPAD_UP);
    out[28] = analog(pad, XINPUT_X);
    out[29] = analog(pad, XINPUT_A);
    out[30] = analog(pad, XINPUT_B);
    out[31] = analog(pad, XINPUT_Y);
    out[32] = analog(pad, XINPUT_RIGHT_SHOULDER);
    out[33] = analog(pad, XINPUT_LEFT_SHOULDER);
    out[34] = pad.right_trigger;
    out[35] = pad.left_trigger;
    out
}

/// Reports a pressed button as the fully pressed analog value.
fn analog(pad: &PadState, button: u16) -> u8 {
    if pad.buttons & button != 0 {
        255
    } else {
        0
    }
}

/// A connected pad entry: id, state, model, connection, MAC, battery, active.
fn port_entry(id: u8, connected: bool) -> [u8; 12] {
    let mut out = [0u8; 12];
    out[0] = id;
    if connected {
        out[1] = 2; // Connected
        out[2] = 2; // Full gyro
        out[3] = 1; // USB
        out[4..10].copy_from_slice(&[0x02, 0, 0, 0, 0, 0x01]);
        out[10] = 5; // Full battery
        out[11] = 1; // Active
    }
    out
}

fn digital_buttons(pad: &PadState) -> u16 {
    let mut bits = 0u16;
    let pairs = [
        (XINPUT_BACK, DSU_SHARE),
        (XINPUT_LEFT_THUMB, DSU_LEFT_THUMB),
        (XINPUT_RIGHT_THUMB, DSU_RIGHT_THUMB),
        (XINPUT_START, DSU_OPTIONS),
        (XINPUT_DPAD_UP, DSU_DPAD_UP),
        (XINPUT_DPAD_RIGHT, DSU_DPAD_RIGHT),
        (XINPUT_DPAD_DOWN, DSU_DPAD_DOWN),
        (XINPUT_DPAD_LEFT, DSU_DPAD_LEFT),
        (XINPUT_LEFT_SHOULDER, DSU_LEFT_SHOULDER),
        (XINPUT_RIGHT_SHOULDER, DSU_RIGHT_SHOULDER),
        (XINPUT_Y, DSU_TRIANGLE),
        (XINPUT_B, DSU_CIRCLE),
        (XINPUT_A, DSU_CROSS),
        (XINPUT_X, DSU_SQUARE),
    ];
    for (source, target) in pairs {
        if pad.buttons & source != 0 {
            bits |= target;
        }
    }
    // The protocol carries triggers both as a bit and as an analog value.
    if pad.left_trigger >= TRIGGER_PRESS_THRESHOLD {
        bits |= DSU_LEFT_TRIGGER;
    }
    if pad.right_trigger >= TRIGGER_PRESS_THRESHOLD {
        bits |= DSU_RIGHT_TRIGGER;
    }
    bits
}

/// Converts a signed stick axis to the unsigned byte the protocol carries.
fn stick_byte(value: i16) -> u8 {
    ((i32::from(value) + 32768) >> 8).clamp(0, 255) as u8
}

/// Tracks the client that receives pushed pad data.
///
/// One emulator talks to one server, so the most recent requester owns the
/// stream. A request renews the subscription; `poll` reports when the next
/// sample is due.
#[derive(Debug, Default)]
pub struct Pusher {
    peer: Option<SocketAddr>,
    last_request: Option<Instant>,
    next_send: Option<Instant>,
}

impl Pusher {
    /// Subscribes a peer and sends the first sample immediately.
    pub fn subscribe(&mut self, peer: SocketAddr, now: Instant) {
        self.peer = Some(peer);
        self.last_request = Some(now);
        self.next_send = Some(now);
    }

    /// Returns the peer when a sample is due and the subscription is alive.
    pub fn poll(&mut self, now: Instant) -> Option<SocketAddr> {
        let (peer, last_request) = match (self.peer, self.last_request) {
            (Some(peer), Some(last_request)) => (peer, last_request),
            _ => return None,
        };
        if now.duration_since(last_request) > REQUEST_TIMEOUT {
            self.peer = None;
            self.last_request = None;
            self.next_send = None;
            return None;
        }
        let next_send = self.next_send?;
        if now < next_send {
            return None;
        }
        self.next_send = Some(now + PUSH_INTERVAL);
        Some(peer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_pad() -> PadState {
        PadState {
            buttons: XINPUT_A | XINPUT_START | XINPUT_DPAD_LEFT,
            left_trigger: 200,
            right_trigger: 0,
            thumb_lx: -32768,
            thumb_ly: 0,
            thumb_rx: 32767,
            thumb_ry: 16384,
            connected: true,
        }
    }

    fn record(pad: &PadState) -> [u8; PAD_STATE_LEN] {
        let mut record = [0u8; PAD_STATE_LEN];
        record[0..4].copy_from_slice(&PAD_STATE_MAGIC.to_le_bytes());
        record[4..8].copy_from_slice(&7u32.to_le_bytes());
        record[8..10].copy_from_slice(&pad.buttons.to_le_bytes());
        record[10] = pad.left_trigger;
        record[11] = pad.right_trigger;
        record[12..14].copy_from_slice(&pad.thumb_lx.to_le_bytes());
        record[14..16].copy_from_slice(&pad.thumb_ly.to_le_bytes());
        record[16..18].copy_from_slice(&pad.thumb_rx.to_le_bytes());
        record[18..20].copy_from_slice(&pad.thumb_ry.to_le_bytes());
        record[20] = u8::from(pad.connected);
        record
    }

    #[test]
    fn crc32_matches_the_reference_vector() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn parses_a_client_request() {
        let mut message = [0u8; HEADER_LEN];
        message[0..4].copy_from_slice(&MAGIC_CLIENT.to_le_bytes());
        message[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
        message[6..8].copy_from_slice(&4u16.to_le_bytes());
        message[12..16].copy_from_slice(&42u32.to_le_bytes());
        message[16..20].copy_from_slice(&TYPE_PAD_DATA.to_le_bytes());
        assert_eq!(
            parse_request(&message),
            Some(Request {
                id: 42,
                message_type: TYPE_PAD_DATA
            })
        );
    }

    #[test]
    fn rejects_foreign_and_unknown_requests() {
        let mut message = [0u8; HEADER_LEN];
        message[0..4].copy_from_slice(&MAGIC_SERVER.to_le_bytes());
        message[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
        message[16..20].copy_from_slice(&TYPE_VERSION.to_le_bytes());
        assert_eq!(parse_request(&message), None);

        message[0..4].copy_from_slice(&MAGIC_CLIENT.to_le_bytes());
        message[16..20].copy_from_slice(&0x0099_9999u32.to_le_bytes());
        assert_eq!(parse_request(&message), None);

        assert_eq!(parse_request(&message[..HEADER_LEN - 1]), None);
    }

    #[test]
    fn parses_the_state_record() {
        let pad = sample_pad();
        assert_eq!(parse_pad_state(&record(&pad)), Some(pad));
    }

    #[test]
    fn rejects_a_stale_state_record() {
        let mut bytes = record(&sample_pad());
        bytes[0..4].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(parse_pad_state(&bytes), None);
        assert_eq!(parse_pad_state(&bytes[..PAD_STATE_LEN - 1]), None);
    }

    #[test]
    fn response_header_carries_a_valid_checksum() {
        let pad = sample_pad();
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 9,
                message_type: TYPE_PAD_DATA,
            },
            Some(&pad),
            &mut counter,
        )
        .expect("pad response");

        assert_eq!(response.len(), HEADER_LEN + 80);
        assert_eq!(&response[0..4], &MAGIC_SERVER.to_le_bytes());
        assert_eq!(
            u16::from_le_bytes(response[4..6].try_into().unwrap()),
            PROTOCOL_VERSION
        );
        assert_eq!(
            u16::from_le_bytes(response[6..8].try_into().unwrap()),
            80 + 4
        );
        assert_eq!(u32::from_le_bytes(response[12..16].try_into().unwrap()), 9);

        let stored = u32::from_le_bytes(response[8..12].try_into().unwrap());
        let mut zeroed = response.clone();
        zeroed[CRC_OFFSET..CRC_OFFSET + 4].fill(0);
        assert_eq!(crc32(&zeroed), stored);
        assert_eq!(counter, 1);
    }

    #[test]
    fn pad_payload_maps_buttons_and_axes() {
        let pad = sample_pad();
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 1,
                message_type: TYPE_PAD_DATA,
            },
            Some(&pad),
            &mut counter,
        )
        .expect("pad response");
        let payload = &response[HEADER_LEN..];

        assert_eq!(payload[1], 2, "state is connected");
        assert_eq!(payload[11], 1, "pad is active");
        let buttons = u16::from_le_bytes(payload[16..18].try_into().unwrap());
        assert_ne!(buttons & DSU_CROSS, 0, "A maps to cross");
        assert_ne!(buttons & DSU_OPTIONS, 0, "start maps to options");
        assert_ne!(buttons & DSU_DPAD_LEFT, 0, "dpad left maps");
        assert_ne!(buttons & DSU_LEFT_TRIGGER, 0, "left trigger is pressed");
        assert_eq!(buttons & DSU_RIGHT_TRIGGER, 0, "right trigger is idle");
        assert_eq!(payload[19], 0, "touch press is idle");
        assert_eq!(payload[20], 0, "left stick X is at the low end");
        assert_eq!(payload[21], 128, "left stick Y is centered");
        assert_eq!(payload[22], 255, "right stick X is at the high end");
        assert_eq!(payload[23], 192, "right stick Y is above center");
        assert_eq!(payload[34], 0, "right trigger is idle");
        assert_eq!(payload[35], 200, "left trigger is analog");
    }

    #[test]
    fn a_missing_pad_reports_disconnected() {
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 1,
                message_type: TYPE_PAD_DATA,
            },
            None,
            &mut counter,
        )
        .expect("pad response");
        let payload = &response[HEADER_LEN..];
        assert_eq!(payload[1], 0, "state is disconnected");
        assert_eq!(payload[11], 0, "pad is inactive");
        assert_eq!(u16::from_le_bytes(payload[16..18].try_into().unwrap()), 0);
        assert_eq!(&payload[20..24], &[STICK_CENTER; 4], "sticks stay centered");
    }

    #[test]
    fn a_disconnected_record_reports_centered_sticks() {
        let pad = PadState {
            buttons: XINPUT_A,
            left_trigger: 200,
            thumb_lx: -32768,
            thumb_ry: 32767,
            ..PadState::default()
        };
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 1,
                message_type: TYPE_PAD_DATA,
            },
            Some(&pad),
            &mut counter,
        )
        .expect("pad response");
        let payload = &response[HEADER_LEN..];
        assert_eq!(payload[1], 0, "state is disconnected");
        assert_eq!(u16::from_le_bytes(payload[16..18].try_into().unwrap()), 0);
        assert_eq!(&payload[20..24], &[STICK_CENTER; 4], "sticks stay centered");
        assert_eq!(&payload[34..36], &[0, 0], "triggers stay released");
    }

    #[test]
    fn a_light_trigger_touch_is_not_a_press() {
        let mut pad = sample_pad();
        pad.left_trigger = TRIGGER_PRESS_THRESHOLD - 1;
        pad.right_trigger = TRIGGER_PRESS_THRESHOLD;
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 1,
                message_type: TYPE_PAD_DATA,
            },
            Some(&pad),
            &mut counter,
        )
        .expect("pad response");
        let payload = &response[HEADER_LEN..];
        let buttons = u16::from_le_bytes(payload[16..18].try_into().unwrap());
        assert_eq!(buttons & DSU_LEFT_TRIGGER, 0, "below the threshold");
        assert_ne!(buttons & DSU_RIGHT_TRIGGER, 0, "at the threshold");
    }

    #[test]
    fn port_info_reports_only_the_first_pad() {
        let pad = sample_pad();
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 1,
                message_type: TYPE_PORT_INFO,
            },
            Some(&pad),
            &mut counter,
        )
        .expect("port info response");
        let payload = &response[HEADER_LEN..];
        assert_eq!(payload.len(), 12);
        assert_eq!(payload[1], 2);
        assert_eq!(payload[11], 1);
        assert_eq!(counter, 0, "port info does not advance the counter");
    }

    /// Mirrors the client validation: the declared length must equal the
    /// payload size plus the message type, and the CRC covers the message.
    fn validate_as_client(response: &[u8]) {
        let magic = u32::from_le_bytes(response[0..4].try_into().unwrap());
        let version = u16::from_le_bytes(response[4..6].try_into().unwrap());
        let declared = usize::from(u16::from_le_bytes(response[6..8].try_into().unwrap()));
        let message_type = u32::from_le_bytes(response[16..20].try_into().unwrap());
        let expected_payload = match message_type {
            TYPE_VERSION => 2,
            TYPE_PORT_INFO => 12,
            TYPE_PAD_DATA => 80,
            other => panic!("unexpected type {other:#x}"),
        };
        assert_eq!(magic, MAGIC_SERVER);
        assert_eq!(version, PROTOCOL_VERSION);
        assert_eq!(declared, expected_payload + 4);
        assert_eq!(response.len(), HEADER_LEN + expected_payload);
        let stored = u32::from_le_bytes(response[8..12].try_into().unwrap());
        let mut zeroed = response.to_vec();
        zeroed[CRC_OFFSET..CRC_OFFSET + 4].fill(0);
        assert_eq!(crc32(&zeroed), stored);
    }

    #[test]
    fn responses_pass_the_client_validation() {
        let pad = sample_pad();
        let mut counter = 0;
        for message_type in [TYPE_VERSION, TYPE_PORT_INFO, TYPE_PAD_DATA] {
            let response = build_response(
                Request {
                    id: 5,
                    message_type,
                },
                Some(&pad),
                &mut counter,
            )
            .expect("response");
            validate_as_client(&response);
        }
    }

    #[test]
    fn version_response_reports_the_protocol_version() {
        let mut counter = 0;
        let response = build_response(
            Request {
                id: 0,
                message_type: TYPE_VERSION,
            },
            None,
            &mut counter,
        )
        .expect("version response");
        assert_eq!(&response[HEADER_LEN..], &PROTOCOL_VERSION.to_le_bytes());
        assert_eq!(&response[0..4], &MAGIC_SERVER.to_le_bytes());
    }

    #[test]
    fn pusher_streams_until_the_request_times_out() {
        let peer: SocketAddr = "127.0.0.1:1234".parse().unwrap();
        let start = Instant::now();
        let mut pusher = Pusher::default();

        pusher.subscribe(peer, start);
        assert_eq!(pusher.poll(start), Some(peer), "first sample is immediate");
        assert_eq!(pusher.poll(start), None, "one sample per interval");
        assert_eq!(pusher.poll(start + PUSH_INTERVAL), Some(peer));

        let expired = start + REQUEST_TIMEOUT + Duration::from_millis(1);
        assert_eq!(pusher.poll(expired), None, "an idle client is dropped");

        let renewed = start + Duration::from_secs(10);
        pusher.subscribe(peer, renewed);
        assert_eq!(pusher.poll(renewed), Some(peer), "a request renews it");
    }
}
