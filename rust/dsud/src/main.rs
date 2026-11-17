//! Serves the Vulcan gamepad state over Cemuhook UDP.
//!
//! Eden and Cemu connect to this server instead of reading a kernel device, so
//! the session keeps its kernel-free input path.

use std::env;
use std::fs;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::process;
use std::time::{Duration, Instant};

use vulcan_dsud::{
    build_response, parse_pad_state, parse_request, Pusher, Request, PAD_STATE_LEN, TYPE_PAD_DATA,
};

const DEFAULT_PORT: u16 = 26760;
const DEFAULT_PAD_FILE: &str = "/data/vulcan-gamepad.bin";
/// Receive poll interval; the push schedule advances at the same rate.
const RECEIVE_POLL: Duration = Duration::from_millis(4);
const BUFFER_LEN: usize = 256;

fn usage() -> ! {
    eprintln!(
        "usage: vulcan-dsud [--bind ADDR] [--port PORT] [--pad-file PATH]\n\
         \n\
         Serves the gamepad state file over Cemuhook UDP for Eden and Cemu."
    );
    process::exit(2);
}

fn read_pad(path: &str) -> Option<vulcan_dsud::PadState> {
    let bytes = fs::read(path).ok()?;
    if bytes.len() < PAD_STATE_LEN {
        return None;
    }
    let mut record = [0u8; PAD_STATE_LEN];
    record.copy_from_slice(&bytes[..PAD_STATE_LEN]);
    parse_pad_state(&record)
}

fn main() -> io::Result<()> {
    let mut bind = String::from("127.0.0.1");
    let mut port = DEFAULT_PORT;
    let mut pad_file = String::from(DEFAULT_PAD_FILE);

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || {
            args.next().unwrap_or_else(|| {
                eprintln!("{arg} needs a value");
                usage();
            })
        };
        match arg.as_str() {
            "--bind" => bind = value(),
            "--port" => {
                port = value().parse().unwrap_or_else(|_| {
                    eprintln!("--port needs a number");
                    usage();
                });
            }
            "--pad-file" => pad_file = value(),
            "-h" | "--help" => usage(),
            _ => {
                eprintln!("unknown argument: {arg}");
                usage();
            }
        }
    }

    let address: SocketAddr = format!("{bind}:{port}").parse().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{bind}:{port}: {error}"),
        )
    })?;
    let socket = UdpSocket::bind(address)?;
    socket.set_read_timeout(Some(RECEIVE_POLL))?;
    eprintln!("vulcan-dsud listening on {address} for {pad_file}");

    let mut buffer = [0u8; BUFFER_LEN];
    let mut counter = 0u32;
    let mut pusher = Pusher::default();
    loop {
        match socket.recv_from(&mut buffer) {
            Ok((length, peer)) => {
                let Some(request) = parse_request(&buffer[..length]) else {
                    continue;
                };
                if request.message_type == TYPE_PAD_DATA {
                    pusher.subscribe(peer, Instant::now());
                }
                let pad = read_pad(&pad_file);
                let Some(response) = build_response(request, pad.as_ref(), &mut counter) else {
                    continue;
                };
                if let Err(error) = socket.send_to(&response, peer) {
                    eprintln!("vulcan-dsud send failed: {error}");
                }
            }
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut => {}
            Err(error) => {
                eprintln!("vulcan-dsud receive failed: {error}");
            }
        }

        // Samples are pushed on their own schedule: the client only asks once
        // and then expects a stream.
        while let Some(peer) = pusher.poll(Instant::now()) {
            let pad = read_pad(&pad_file);
            let response = build_response(
                Request {
                    id: 0,
                    message_type: TYPE_PAD_DATA,
                },
                pad.as_ref(),
                &mut counter,
            );
            let Some(response) = response else { break };
            if let Err(error) = socket.send_to(&response, peer) {
                eprintln!("vulcan-dsud send failed: {error}");
                break;
            }
        }
    }
}
