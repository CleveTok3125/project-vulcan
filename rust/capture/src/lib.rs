//! Relays the obs-vkcapture socket across a network namespace boundary.
//!
//! The OBS plugin binds the abstract unix socket `@/com/obsproject/vkcapture`
//! and the game-side sender connects to it. Abstract sockets live in the
//! network namespace, so a session with its own namespace needs two halves:
//! the session side binds the abstract name and forwards each connection over a
//! `SOCK_SEQPACKET` socket in the shared runtime directory, and the host side
//! forwards it to the plugin.
//!
//! Frames carry dmabuf file descriptors through `SCM_RIGHTS`, so the relay
//! forwards the control message with the data and closes its copies. Frame
//! sizes come from `capture.h` of the pinned `OBS_VKCAPTURE_REF`; the image
//! build fails when they change.

use std::io;
use std::mem::{size_of, zeroed};
use std::os::unix::io::RawFd;

/// Abstract name the plugin binds and the sender connects to.
pub const ABSTRACT_NAME: &str = "/com/obsproject/vkcapture";

/// Sender-to-plugin message size (`CAPTURE_CLIENT_DATA_SIZE`, `CAPTURE_TEXTURE_DATA_SIZE`).
pub const FRAME_SIZE: usize = 128;

/// Plugin-to-sender control message size (`CAPTURE_CONTROL_DATA_SIZE`).
pub const CONTROL_SIZE: usize = 32;

/// File descriptors a texture frame carries (`CAPTURE_TEXTURE_DATA_SIZE` packs four).
pub const MAX_FDS: usize = 4;

/// Control buffer large enough for one `SCM_RIGHTS` header and `MAX_FDS` descriptors.
const CONTROL_BUFFER: usize = size_of::<libc::cmsghdr>() + MAX_FDS * size_of::<libc::c_int>();

/// Control buffer with the alignment the kernel requires.
#[repr(align(8))]
struct ControlBuffer([u8; CONTROL_BUFFER]);

fn cvt(result: libc::c_int) -> io::Result<libc::c_int> {
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result)
    }
}

fn cvt_len(result: libc::ssize_t) -> io::Result<usize> {
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result as usize)
    }
}

fn socket(kind: libc::c_int) -> io::Result<RawFd> {
    cvt(unsafe { libc::socket(libc::AF_UNIX, kind | libc::SOCK_CLOEXEC, 0) })
}

fn abstract_addr(name: &str) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
    let bytes = name.as_bytes();
    let mut addr: libc::sockaddr_un = unsafe { zeroed() };
    if bytes.len() + 1 > addr.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("abstract name too long: {name}"),
        ));
    }
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    addr.sun_path[0] = 0;
    for (slot, byte) in addr.sun_path[1..].iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let length = size_of::<libc::sa_family_t>() + 1 + bytes.len();
    Ok((addr, length as libc::socklen_t))
}

fn path_addr(path: &str) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
    let bytes = path.as_bytes();
    let mut addr: libc::sockaddr_un = unsafe { zeroed() };
    if bytes.len() + 1 > addr.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("socket path too long: {path}"),
        ));
    }
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (slot, byte) in addr.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let length = size_of::<libc::sa_family_t>() + bytes.len() + 1;
    Ok((addr, length as libc::socklen_t))
}

/// Binds the abstract socket the sender connects to.
pub fn bind_abstract(name: &str) -> io::Result<RawFd> {
    let fd = socket(libc::SOCK_STREAM)?;
    let (addr, length) = abstract_addr(name)?;
    if let Err(error) = cvt(unsafe {
        libc::bind(
            fd,
            &addr as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    }) {
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

/// Connects to the abstract socket the plugin binds.
pub fn connect_abstract(name: &str) -> io::Result<RawFd> {
    let fd = socket(libc::SOCK_STREAM)?;
    let (addr, length) = abstract_addr(name)?;
    if let Err(error) = cvt(unsafe {
        libc::connect(
            fd,
            &addr as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    }) {
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

/// Creates the sequpacket listener both halves share.
pub fn bind_path(path: &str) -> io::Result<RawFd> {
    let fd = socket(libc::SOCK_SEQPACKET)?;
    let (addr, length) = path_addr(path)?;
    // A relay that died without cleanup leaves the path behind.
    let _ = std::fs::remove_file(path);
    if let Err(error) = cvt(unsafe {
        libc::bind(
            fd,
            &addr as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    }) {
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

/// Connects a sequpacket socket to the shared listener.
pub fn connect_path(path: &str) -> io::Result<RawFd> {
    let fd = socket(libc::SOCK_SEQPACKET)?;
    let (addr, length) = path_addr(path)?;
    if let Err(error) = cvt(unsafe {
        libc::connect(
            fd,
            &addr as *const libc::sockaddr_un as *const libc::sockaddr,
            length,
        )
    }) {
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

pub fn listen(fd: RawFd) -> io::Result<()> {
    cvt(unsafe { libc::listen(fd, 8) }).map(|_| ())
}

fn accept(fd: RawFd) -> io::Result<RawFd> {
    loop {
        let accepted = unsafe {
            libc::accept4(
                fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_CLOEXEC,
            )
        };
        if accepted >= 0 {
            return Ok(accepted);
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error);
    }
}

/// Receives one sender frame with the descriptors it carries.
pub fn recv_frame(fd: RawFd) -> io::Result<(Vec<u8>, Vec<RawFd>)> {
    let mut data = vec![0u8; FRAME_SIZE];
    let mut control = ControlBuffer([0u8; CONTROL_BUFFER]);
    let mut iov = libc::iovec {
        iov_base: data.as_mut_ptr().cast(),
        iov_len: data.len(),
    };
    let mut message: libc::msghdr = unsafe { zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.0.as_mut_ptr().cast();
    message.msg_controllen = CONTROL_BUFFER;
    let length = cvt_len(unsafe { libc::recvmsg(fd, &mut message, 0) })?;
    data.truncate(length);

    let mut fds = Vec::new();
    if message.msg_flags & libc::MSG_CTRUNC != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "control message was truncated",
        ));
    }
    if message.msg_controllen >= size_of::<libc::cmsghdr>() {
        // SAFETY: the kernel filled the buffer and reported at least one header.
        unsafe {
            let header = &*(control.0.as_ptr() as *const libc::cmsghdr);
            if header.cmsg_level == libc::SOL_SOCKET && header.cmsg_type == libc::SCM_RIGHTS {
                let bytes = header.cmsg_len - size_of::<libc::cmsghdr>();
                let count = bytes / size_of::<libc::c_int>();
                let base = control.0.as_ptr().add(size_of::<libc::cmsghdr>()) as *const libc::c_int;
                for index in 0..count {
                    fds.push(*base.add(index));
                }
            }
        }
    }
    Ok((data, fds))
}

/// Sends one frame and the descriptors it carries.
pub fn send_frame(fd: RawFd, data: &[u8], fds: &[RawFd]) -> io::Result<()> {
    if fds.len() > MAX_FDS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} descriptors in one frame", fds.len()),
        ));
    }
    let mut iov = libc::iovec {
        iov_base: data.as_ptr() as *mut libc::c_void,
        iov_len: data.len(),
    };
    let mut message: libc::msghdr = unsafe { zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    let mut control = ControlBuffer([0u8; CONTROL_BUFFER]);
    if !fds.is_empty() {
        // SAFETY: the buffer holds one header plus MAX_FDS descriptors.
        unsafe {
            let header = control.0.as_mut_ptr() as *mut libc::cmsghdr;
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = size_of::<libc::cmsghdr>() + size_of_val(fds);
            let base = control.0.as_mut_ptr().add(size_of::<libc::cmsghdr>()) as *mut libc::c_int;
            for (index, descriptor) in fds.iter().enumerate() {
                *base.add(index) = *descriptor;
            }
        }
        message.msg_control = control.0.as_mut_ptr().cast();
        // SAFETY: the length only feeds the size formula of the buffer above.
        message.msg_controllen =
            unsafe { libc::CMSG_SPACE(size_of_val(fds) as libc::c_uint) as usize };
    }
    let sent = cvt_len(unsafe { libc::sendmsg(fd, &message, libc::MSG_NOSIGNAL) })?;
    if sent != data.len() {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            format!("sent {sent} of {} bytes", data.len()),
        ));
    }
    Ok(())
}

/// Receives one control message from the plugin.
pub fn recv_control(fd: RawFd) -> io::Result<[u8; CONTROL_SIZE]> {
    let mut buffer = [0u8; CONTROL_SIZE];
    let mut filled = 0;
    while filled < CONTROL_SIZE {
        let length = cvt_len(unsafe {
            libc::recv(
                fd,
                buffer[filled..].as_mut_ptr().cast(),
                CONTROL_SIZE - filled,
                0,
            )
        })?;
        if length == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        filled += length;
    }
    Ok(buffer)
}

fn write_control(fd: RawFd, data: &[u8; CONTROL_SIZE]) -> io::Result<()> {
    let mut written = 0;
    while written < CONTROL_SIZE {
        let length = cvt_len(unsafe {
            libc::send(
                fd,
                data[written..].as_ptr().cast(),
                CONTROL_SIZE - written,
                libc::MSG_NOSIGNAL,
            )
        })?;
        if length == 0 {
            return Err(io::Error::from(io::ErrorKind::WriteZero));
        }
        written += length;
    }
    Ok(())
}

/// Peer pid of a connected unix socket, or -1 when the kernel refuses.
fn peer_pid(fd: RawFd) -> i32 {
    let mut credentials: libc::ucred = unsafe { zeroed() };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the buffer matches the size the option writes.
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credentials as *mut libc::ucred as *mut libc::c_void,
            &mut length,
        )
    };
    if result == 0 {
        credentials.pid
    } else {
        -1
    }
}

fn shutdown_both(first: RawFd, second: RawFd) {
    // SAFETY: both descriptors belong to this pump until it returns.
    unsafe {
        libc::shutdown(first, libc::SHUT_RDWR);
        libc::shutdown(second, libc::SHUT_RDWR);
    }
}

fn forward_loop(sender: RawFd, plugin: RawFd) {
    while let Ok((data, fds)) = recv_frame(sender) {
        let sent = if data.len() == FRAME_SIZE {
            send_frame(plugin, &data, &fds)
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{} byte frame", data.len()),
            ))
        };
        // The kernel duplicated the descriptors into this process.
        for descriptor in &fds {
            unsafe { libc::close(*descriptor) };
        }
        if sent.is_err() {
            break;
        }
    }
    shutdown_both(sender, plugin);
}

fn reverse_loop(plugin: RawFd, sender: RawFd) {
    while let Ok(data) = recv_control(plugin) {
        if write_control(sender, &data).is_err() {
            break;
        }
    }
    shutdown_both(plugin, sender);
}

/// Copies one connection in both directions and closes it afterwards.
pub fn pump(sender: RawFd, plugin: RawFd) {
    let forward = std::thread::spawn(move || forward_loop(sender, plugin));
    let reverse = std::thread::spawn(move || reverse_loop(plugin, sender));
    let _ = forward.join();
    let _ = reverse.join();
    // SAFETY: both threads are done with the descriptors.
    unsafe {
        libc::close(sender);
        libc::close(plugin);
    }
}

fn accept_loop(
    role: &'static str,
    listener: RawFd,
    mut connect: impl FnMut() -> io::Result<RawFd>,
) {
    loop {
        let peer = match accept(listener) {
            Ok(peer) => peer,
            Err(error) => {
                eprintln!("vulcan-capture-bridge: {role}: accept failed: {error}");
                continue;
            }
        };
        let pid = peer_pid(peer);
        eprintln!("vulcan-capture-bridge: {role}: connection from pid {pid}");
        match connect() {
            Ok(relay) => {
                std::thread::spawn(move || {
                    pump(peer, relay);
                    eprintln!("vulcan-capture-bridge: {role}: pid {pid} disconnected");
                });
            }
            Err(error) => {
                eprintln!(
                    "vulcan-capture-bridge: {role}: pid {pid} cannot reach the other half: {error}"
                );
                // SAFETY: the accepted descriptor is not shared yet.
                unsafe { libc::close(peer) };
            }
        }
    }
}

/// Serves the session side: binds the sender's abstract name and relays to `socket_path`.
pub fn serve_game(socket_path: &str, name: &str, ready_file: Option<&str>) -> io::Result<()> {
    let listener = bind_abstract(name)?;
    listen(listener)?;
    if let Some(path) = ready_file {
        std::fs::write(path, format!("@{name}\n"))?;
    }
    eprintln!("vulcan-capture-bridge: listening on @{name} for {socket_path}");
    accept_loop("session", listener, || connect_path(socket_path));
    Ok(())
}

/// Serves the host side: accepts from `socket_path` and relays to the plugin.
pub fn serve_host(socket_path: &str, name: &str, ready_file: Option<&str>) -> io::Result<()> {
    let listener = bind_path(socket_path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "cannot bind {socket_path}: {error}; \
                 check that the session runtime directory exists and is writable"
            ),
        )
    })?;
    listen(listener)?;
    if let Some(path) = ready_file {
        std::fs::write(path, format!("{socket_path}\n"))?;
    }
    eprintln!("vulcan-capture-bridge: relaying {socket_path} to @{name}");
    accept_loop("host", listener, || connect_abstract(name));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::io::AsRawFd;
    use std::time::{Duration, Instant};

    fn pair(kind: libc::c_int) -> (RawFd, RawFd) {
        let mut fds = [-1; 2];
        let result = unsafe { libc::socketpair(libc::AF_UNIX, kind, 0, fds.as_mut_ptr()) };
        assert_eq!(result, 0, "socketpair: {}", io::Error::last_os_error());
        (fds[0], fds[1])
    }

    fn unique(label: &str) -> String {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let index = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        format!("/tmp/vcb-{label}-{}-{index}", std::process::id())
    }

    fn wait_ready(path: &std::path::Path) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if path.exists() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }

    #[test]
    fn pumps_frames_and_fds_both_ways() {
        let (sender, bridge_sender) = pair(libc::SOCK_STREAM);
        let (bridge_plugin, plugin) = pair(libc::SOCK_SEQPACKET);
        std::thread::spawn(move || pump(bridge_sender, bridge_plugin));

        let null = std::fs::File::open("/dev/null").expect("open /dev/null");
        let descriptor = null.as_raw_fd();

        let payload = vec![0x11u8; FRAME_SIZE];
        assert!(send_frame(sender, &payload, &[]).is_ok());
        assert!(send_frame(sender, &payload, &[descriptor]).is_ok());

        for (index, expected_fds) in [0usize, 1].into_iter().enumerate() {
            let (data, fds) = recv_frame(plugin).expect("frame");
            assert_eq!(data.len(), FRAME_SIZE, "frame {index}");
            assert_eq!(fds.len(), expected_fds, "frame {index} descriptors");
            for fd in fds {
                unsafe { libc::close(fd) };
            }
        }

        let control = [0x22u8; CONTROL_SIZE];
        assert!(write_control(plugin, &control).is_ok());
        assert_eq!(recv_control(sender).expect("control"), control);

        unsafe {
            libc::close(sender);
            libc::close(plugin);
        }
    }

    #[test]
    fn both_halves_relay_one_connection() {
        let suffix = format!(
            "{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .subsec_nanos()
        );
        let sender_name = format!("/vulcan-test-sender-{suffix}");
        let plugin_name = format!("/vulcan-test-plugin-{suffix}");
        let socket_path = unique("relay");
        let ready_game = unique("ready-game");
        let ready_host = unique("ready-host");

        // Stand-in for the OBS plugin: reads one frame and answers one control message.
        let plugin_listener = bind_abstract(&plugin_name).expect("plugin bind");
        listen(plugin_listener).expect("plugin listen");
        std::thread::spawn(move || {
            let client = accept(plugin_listener).expect("plugin accept");
            let (data, fds) = recv_frame(client).expect("plugin frame");
            assert_eq!(data.len(), FRAME_SIZE);
            assert_eq!(fds.len(), 1);
            for fd in fds {
                unsafe { libc::close(fd) };
            }
            write_control(client, &[0x33u8; CONTROL_SIZE]).expect("plugin control");
        });

        let host_path = socket_path.clone();
        let host_name = plugin_name.clone();
        let host_ready = ready_host.clone();
        std::thread::spawn(move || {
            serve_host(&host_path, &host_name, Some(&host_ready)).expect("host half");
        });
        let game_path = socket_path.clone();
        let game_name = sender_name.clone();
        let game_ready = ready_game.clone();
        std::thread::spawn(move || {
            serve_game(&game_path, &game_name, Some(&game_ready)).expect("game half");
        });
        assert!(wait_ready(std::path::Path::new(&ready_host)), "host ready");
        assert!(wait_ready(std::path::Path::new(&ready_game)), "game ready");

        // Stand-in for the game sender.
        let sender = connect_abstract(&sender_name).expect("sender connect");
        let null = std::fs::File::open("/dev/null").expect("open /dev/null");
        assert!(send_frame(sender, &[0x44u8; FRAME_SIZE], &[null.as_raw_fd()]).is_ok());
        assert_eq!(
            recv_control(sender).expect("sender control"),
            [0x33u8; CONTROL_SIZE]
        );

        unsafe { libc::close(sender) };
        let _ = std::fs::remove_file(&socket_path);
        let _ = std::fs::remove_file(&ready_game);
        let _ = std::fs::remove_file(&ready_host);
    }
}
