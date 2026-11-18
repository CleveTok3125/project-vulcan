//! Runs one half of the obs-vkcapture relay.
//!
//! Eden and Wine games load the capture sender, which connects to the OBS
//! plugin on an abstract unix socket. A session with its own network namespace
//! runs `game`, which rebinds that name inside the namespace and forwards to the
//! host, where `host` hands the connection to the plugin.

use std::env;
use std::io;
use std::process;

use vulcan_capture_bridge::{serve_game, serve_host, ABSTRACT_NAME};

fn usage() -> ! {
    eprintln!(
        "usage: vulcan-capture-bridge <game|host> --socket PATH\n\
         \t[--abstract NAME] [--ready-file PATH]\n\
         \n\
         game: bind NAME inside the session and relay to PATH.\n\
         host: accept on PATH and relay to NAME, which the plugin binds."
    );
    process::exit(2);
}

fn main() -> io::Result<()> {
    let mut arguments = env::args().skip(1);
    let mode = arguments.next().unwrap_or_else(|| usage());
    let mut socket = String::new();
    let mut name = String::from(ABSTRACT_NAME);
    let mut ready_file: Option<String> = None;

    while let Some(argument) = arguments.next() {
        let mut value = || {
            arguments.next().unwrap_or_else(|| {
                eprintln!("{argument} needs a value");
                usage();
            })
        };
        match argument.as_str() {
            "--socket" => socket = value(),
            "--abstract" => name = value(),
            "--ready-file" => ready_file = Some(value()),
            "-h" | "--help" => usage(),
            _ => {
                eprintln!("unknown argument: {argument}");
                usage();
            }
        }
    }
    if socket.is_empty() {
        eprintln!("--socket is required");
        usage();
    }

    match mode.as_str() {
        "game" => serve_game(&socket, &name, ready_file.as_deref()),
        "host" => serve_host(&socket, &name, ready_file.as_deref()),
        _ => usage(),
    }
}
