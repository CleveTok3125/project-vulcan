//! Checks that the server pushes pad samples instead of answering requests.

use std::net::UdpSocket;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const MAGIC_CLIENT: u32 = 0x4355_5344;
const PROTOCOL_VERSION: u16 = 1001;
const TYPE_PAD_DATA: u32 = 0x0010_0002;
const HEADER_LEN: usize = 20;
const PAYLOAD_LEN: usize = 80;

fn pad_request() -> [u8; HEADER_LEN + 8] {
    let mut message = [0u8; HEADER_LEN + 8];
    message[0..4].copy_from_slice(&MAGIC_CLIENT.to_le_bytes());
    message[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    message[6..8].copy_from_slice(&12u16.to_le_bytes());
    message[12..16].copy_from_slice(&7u32.to_le_bytes());
    message[16..20].copy_from_slice(&TYPE_PAD_DATA.to_le_bytes());
    message
}

fn pad_record() -> [u8; 28] {
    let mut record = [0u8; 28];
    record[0..4].copy_from_slice(&0x5647_5031u32.to_le_bytes());
    record[8..10].copy_from_slice(&0x1000u16.to_le_bytes());
    record[20] = 1;
    record
}

struct Server {
    child: Child,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn pushes_samples_after_one_request() {
    let workdir = std::env::temp_dir().join(format!("vulcan-dsud-push-{}", std::process::id()));
    std::fs::create_dir_all(&workdir).expect("workdir");
    let pad_file = workdir.join("gamepad.bin");
    std::fs::write(&pad_file, pad_record()).expect("pad file");

    let probe = UdpSocket::bind("127.0.0.1:0").expect("probe socket");
    let port = probe.local_addr().expect("probe address").port();
    drop(probe);

    let child = Command::new(env!("CARGO_BIN_EXE_vulcan-dsud"))
        .arg("--pad-file")
        .arg(&pad_file)
        .arg("--port")
        .arg(port.to_string())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn server");
    let _server = Server { child };

    let client = UdpSocket::bind("127.0.0.1:0").expect("client socket");
    client
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("timeout");
    let server_address = format!("127.0.0.1:{port}");

    // A cold server may not be listening yet; keep one request outstanding.
    let deadline = Instant::now() + Duration::from_secs(2);
    client
        .send_to(&pad_request(), &server_address)
        .expect("send request");
    let mut received = 0usize;
    let mut first_counter = None;
    let mut last_counter = None;
    let started = Instant::now();
    while Instant::now() < deadline && received < 5 {
        let mut buffer = [0u8; 256];
        let Ok((length, _)) = client.recv_from(&mut buffer) else {
            if Instant::now() > started + Duration::from_secs(1) {
                client
                    .send_to(&pad_request(), &server_address)
                    .expect("resend request");
            }
            continue;
        };
        if length < HEADER_LEN + PAYLOAD_LEN {
            continue;
        }
        let counter = u32::from_le_bytes(
            buffer[HEADER_LEN + 12..HEADER_LEN + 16]
                .try_into()
                .expect("counter"),
        );
        if first_counter.is_none() {
            first_counter = Some(counter);
        }
        assert!(
            last_counter.is_none_or(|previous| counter != previous),
            "samples advance the counter"
        );
        last_counter = Some(counter);
        received += 1;
    }

    assert!(
        received >= 5,
        "expected a stream of pushed samples, received {received}"
    );
    assert!(
        last_counter.unwrap() > first_counter.unwrap(),
        "counter must advance between samples"
    );
}
