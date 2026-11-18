//! Checks that the server pushes pad samples instead of answering requests.

use std::io::Read;
use std::net::UdpSocket;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
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

/// Removes the temporary directory when the test ends, including on a panic.
struct Workdir(PathBuf);

impl Workdir {
    fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!("vulcan-dsud-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&path).expect("workdir");
        Self(path)
    }

    fn pad_file(&self) -> PathBuf {
        let path = self.0.join("gamepad.bin");
        std::fs::write(&path, pad_record()).expect("pad file");
        path
    }

    fn ready_file(&self) -> PathBuf {
        self.0.join("ready")
    }
}

impl Drop for Workdir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Server {
    child: Child,
}

impl Server {
    fn spawn(pad_file: &Path, port: u16, ready_file: Option<&Path>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vulcan-dsud"));
        command
            .arg("--pad-file")
            .arg(pad_file)
            .arg("--port")
            .arg(port.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        if let Some(path) = ready_file {
            command.arg("--ready-file").arg(path);
        }
        Self {
            child: command.spawn().expect("spawn server"),
        }
    }

    fn wait(&mut self, timeout: Duration) -> ExitStatus {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self.child.try_wait().expect("wait for the server") {
                return status;
            }
            assert!(Instant::now() < deadline, "server did not exit in time");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn stderr(&mut self) -> String {
        let mut text = String::new();
        self.child
            .stderr
            .take()
            .expect("captured stderr")
            .read_to_string(&mut text)
            .expect("read stderr");
        text
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn free_port() -> u16 {
    let probe = UdpSocket::bind("127.0.0.1:0").expect("probe socket");
    probe.local_addr().expect("probe address").port()
}

#[test]
fn pushes_samples_after_one_request() {
    let workdir = Workdir::new("push");
    let pad_file = workdir.pad_file();
    let port = free_port();
    let _server = Server::spawn(&pad_file, port, None);

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

#[test]
fn fails_when_the_endpoint_is_taken() {
    let workdir = Workdir::new("taken");
    let pad_file = workdir.pad_file();
    let ready_file = workdir.ready_file();
    // Holding the socket keeps the endpoint away from the server.
    let _owner = UdpSocket::bind("127.0.0.1:0").expect("occupy the endpoint");
    let port = _owner.local_addr().expect("occupied address").port();

    let mut server = Server::spawn(&pad_file, port, Some(&ready_file));
    let status = server.wait(Duration::from_secs(5));

    assert!(!status.success(), "server must fail when the port is taken");
    assert!(!ready_file.exists(), "server must not signal readiness");
    let stderr = server.stderr();
    assert!(
        stderr.contains("cannot bind") && stderr.contains(&port.to_string()),
        "reports the endpoint: {stderr}"
    );
}
