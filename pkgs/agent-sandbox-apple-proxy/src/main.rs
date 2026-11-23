//! HTTP CONNECT proxy on a Unix socket: the only network exit of the VM.
//!
//! agent-sandbox-apple-proxy --socket <path> --allow <file> --startup <file> --log <file>

mod policy;

use policy::{is_global, Decision, Policy};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::exit;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const MAX_HEAD: usize = 16 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// How long a client has to send its whole request head.
const HEAD_TIMEOUT: Duration = Duration::from_secs(30);
/// How long to wait after a failed accept(), such as one out of
/// descriptors, before trying again: never a busy loop.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);
/// The open-file limit asked for, macOS's OPEN_MAX.
const NOFILE_WANT: u64 = 10240;

/// struct rlimit: rlim_t is 64 bits on macOS and on 64-bit Linux.
#[repr(C)]
struct RLimit {
    cur: u64,
    max: u64,
}

#[cfg(any(target_os = "linux", target_os = "android"))]
const RLIMIT_NOFILE: i32 = 7;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
const RLIMIT_NOFILE: i32 = 8;

extern "C" {
    fn signal(signum: i32, handler: extern "C" fn(i32)) -> usize;
    fn unlink(path: *const std::os::raw::c_char) -> i32;
    fn _exit(code: i32) -> !;
    fn umask(mask: u32) -> u32;
    fn getrlimit(resource: i32, rlim: *mut RLimit) -> i32;
    fn setrlimit(resource: i32, rlim: *const RLimit) -> i32;
}

static SOCKET_PATH: OnceLock<CString> = OnceLock::new();

/// std cannot catch signals, so this does the two things shutdown needs
/// (both async-signal-safe) and leaves: remove the socket, exit 0.
extern "C" fn on_signal(_: i32) {
    if let Some(p) = SOCKET_PATH.get() {
        unsafe { unlink(p.as_ptr()) };
    }
    unsafe { _exit(0) };
}

/// Raises the soft open-file limit to min(hard, 10240): macOS starts a
/// process at 256, and a tunnel holds two descriptors. Returns the soft
/// limit now in force.
fn raise_nofile_limit() -> io::Result<u64> {
    let mut l = RLimit { cur: 0, max: 0 };
    if unsafe { getrlimit(RLIMIT_NOFILE, &mut l) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let want = l.max.min(NOFILE_WANT);
    if l.cur >= want {
        return Ok(l.cur);
    }
    let raised = RLimit { cur: want, max: l.max };
    if unsafe { setrlimit(RLIMIT_NOFILE, &raised) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(want)
}

struct Args {
    socket: PathBuf,
    allow: PathBuf,
    startup: PathBuf,
    log: PathBuf,
}

fn parse_args() -> Result<Args, String> {
    let (mut socket, mut allow, mut startup, mut log) = (None, None, None, None);
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--socket" => &mut socket,
            "--allow" => &mut allow,
            "--startup" => &mut startup,
            "--log" => &mut log,
            _ => return Err(format!("unexpected '{flag}'")),
        };
        *slot = Some(PathBuf::from(it.next().ok_or(format!("{flag} needs a value"))?));
    }
    let need = |v: Option<PathBuf>, n: &str| v.ok_or(format!("missing {n}"));
    Ok(Args {
        socket: need(socket, "--socket")?,
        allow: need(allow, "--allow")?,
        startup: need(startup, "--startup")?,
        log: need(log, "--log")?,
    })
}

fn read_hosts(path: &PathBuf) -> Result<Vec<String>, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect())
}

struct Log(Mutex<File>);

impl Log {
    /// One log line. The text can carry bytes the VM chose, so control
    /// characters are escaped: a request cannot forge a second line.
    fn line(&self, s: &str) {
        let s: String = s
            .chars()
            .flat_map(|c| {
                let mut out = String::new();
                if c.is_control() {
                    out.extend(c.escape_default());
                } else {
                    out.push(c);
                }
                out.chars().collect::<Vec<_>>()
            })
            .collect();
        if let Ok(mut f) = self.0.lock() {
            let _ = writeln!(f, "{s}");
        }
    }
}

/// Resolve once; refuse if any address is non-global; return them all.
fn resolve_public(host: &str, port: u16) -> Result<Vec<SocketAddr>, String> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve: {e}"))?
        .collect();
    if let Some(bad) = addrs.iter().find(|a| !is_global(a.ip())) {
        return Err(format!("non-global {}", bad.ip()));
    }
    if addrs.is_empty() {
        return Err("resolve: no addresses".to_string());
    }
    Ok(addrs)
}

/// Connects to the first of `addrs` that answers, in order.
fn connect_any(addrs: &[SocketAddr], timeout: Duration) -> Result<(TcpStream, SocketAddr), String> {
    let mut last = "no addresses".to_string();
    for a in addrs {
        match TcpStream::connect_timeout(a, timeout) {
            Ok(s) => return Ok((s, *a)),
            Err(e) => last = format!("{a}: {e}"),
        }
    }
    Err(last)
}

/// Reads the request head, within `timeout` for the whole of it. Returns
/// the bytes read and where the head ends in them, or None when the
/// client left or sent too much; a client too slow is a TimedOut error.
/// The read timeout is cleared again before it returns the head.
fn read_head(c: &mut UnixStream, timeout: Duration) -> io::Result<Option<(Vec<u8>, usize)>> {
    let deadline = Instant::now() + timeout;
    let timed_out = || io::Error::new(io::ErrorKind::TimedOut, "request head timed out");
    let mut head = Vec::new();
    let mut buf = [0u8; 4096];
    let end = loop {
        if let Some(i) = head.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if head.len() > MAX_HEAD {
            return Ok(None);
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(timed_out());
        }
        c.set_read_timeout(Some(left))?;
        let n = match c.read(&mut buf) {
            Ok(n) => n,
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {
                return Err(timed_out())
            }
            Err(e) => return Err(e),
        };
        if n == 0 {
            return Ok(None);
        }
        head.extend_from_slice(&buf[..n]);
    };
    c.set_read_timeout(None)?;
    Ok(Some((head, end)))
}

/// Pipes `c` and `u` both ways until both are done, closing the write
/// side of each once its source ends. It borrows both, so a tunnel holds
/// two descriptors, and nothing in it can panic.
fn tunnel(c: &UnixStream, u: &TcpStream) {
    thread::scope(|s| {
        let up = thread::Builder::new().spawn_scoped(s, || {
            let _ = io::copy(&mut &*c, &mut &*u);
            let _ = u.shutdown(Shutdown::Write);
        });
        if up.is_err() {
            // No thread for the upload: drop the tunnel.
            return;
        }
        let _ = io::copy(&mut &*u, &mut &*c);
        let _ = c.shutdown(Shutdown::Write);
    });
}

fn handle(mut c: UnixStream, policy: &Mutex<Policy>, log: &Log) -> io::Result<()> {
    let Some((head, end)) = read_head(&mut c, HEAD_TIMEOUT)? else {
        return Ok(());
    };
    let first = String::from_utf8_lossy(&head[..head.iter().position(|&b| b == b'\r').unwrap_or(0)])
        .into_owned();
    let mut parts = first.split(' ');
    let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    if method != "CONNECT" {
        log.line(&format!("deny {first} (not CONNECT)"));
        return c.write_all(b"HTTP/1.1 405 CONNECT only\r\n\r\n");
    }
    let decision = policy.lock().unwrap_or_else(|e| e.into_inner()).decide(target);
    let (host, port) = match decision {
        Decision::Latch => {
            log.line("latch closed");
            return c.write_all(b"HTTP/1.1 200 Latched\r\n\r\n");
        }
        Decision::Deny(reason) => {
            log.line(&format!("deny {target} ({reason})"));
            return c.write_all(b"HTTP/1.1 403 Not on allow-list\r\n\r\n");
        }
        Decision::Connect { host, port } => (host, port),
    };
    let addrs = match resolve_public(&host, port) {
        Ok(a) => a,
        Err(e) => {
            log.line(&format!("deny {target} ({e})"));
            let resp: &[u8] = if e.starts_with("non-global") {
                b"HTTP/1.1 403 Private address\r\n\r\n"
            } else {
                b"HTTP/1.1 502 Resolve failed\r\n\r\n"
            };
            return c.write_all(resp);
        }
    };
    let (mut u, addr) = match connect_any(&addrs, CONNECT_TIMEOUT) {
        Ok(found) => found,
        Err(e) => {
            log.line(&format!("deny {target} (connect: {e})"));
            return c.write_all(b"HTTP/1.1 502 Connect failed\r\n\r\n");
        }
    };
    c.write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")?;
    log.line(&format!("allow {host}:{port} -> {}", addr.ip()));
    if end < head.len() {
        u.write_all(&head[end..])?;
    }
    tunnel(&c, &u);
    Ok(())
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    if let Err(e) = raise_nofile_limit() {
        eprintln!("agent-sandbox-apple-proxy: cannot raise the open-file limit: {e}");
    }
    let policy = Arc::new(Mutex::new(Policy::new(
        read_hosts(&args.allow)?,
        read_hosts(&args.startup)?,
    )));
    let log = Arc::new(Log(Mutex::new(
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&args.log)
            .map_err(|e| format!("{}: {e}", args.log.display()))?,
    )));

    let _ = fs::remove_file(&args.socket);
    unsafe { umask(0o177) };
    let listener = UnixListener::bind(&args.socket).map_err(|e| format!("bind: {e}"))?;
    fs::set_permissions(&args.socket, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("chmod: {e}"))?;

    let path = CString::new(args.socket.as_os_str().as_encoded_bytes())
        .map_err(|e| e.to_string())?;
    let _ = SOCKET_PATH.set(path);
    unsafe {
        signal(15, on_signal);
        signal(2, on_signal);
    }

    println!("ready");
    io::stdout().flush().map_err(|e| e.to_string())?;

    for conn in listener.incoming() {
        let conn = match conn {
            Ok(conn) => conn,
            Err(_) => {
                // Out of descriptors, say: the connection waits in the
                // backlog until one is free.
                thread::sleep(ACCEPT_BACKOFF);
                continue;
            }
        };
        let (policy, log) = (Arc::clone(&policy), Arc::clone(&log));
        let spawned = thread::Builder::new().spawn(move || {
            if let Err(e) = handle(conn, &policy, &log) {
                log.line(&format!("error {e}"));
            }
        });
        if spawned.is_err() {
            // No thread to serve it: the connection is dropped, closed.
            thread::sleep(ACCEPT_BACKOFF);
        }
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("agent-sandbox-apple-proxy: {e}");
        exit(2);
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::time::Instant;

    #[test]
    fn head_read_gives_up_on_a_stalled_client() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        b.write_all(b"CONNECT x.com:443 HTTP/1.1\r\n").unwrap();
        let start = Instant::now();
        let e = read_head(&mut a, Duration::from_millis(200)).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(2), "{:?}", start.elapsed());
    }

    #[test]
    fn head_read_gives_up_on_a_trickling_client() {
        // One byte at a time, each within a per-read timeout: the
        // deadline is for the whole head.
        let (mut a, mut b) = UnixStream::pair().unwrap();
        let t = thread::spawn(move || {
            for _ in 0..20 {
                if b.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
        });
        let start = Instant::now();
        assert!(read_head(&mut a, Duration::from_millis(300)).is_err());
        assert!(start.elapsed() < Duration::from_millis(900), "{:?}", start.elapsed());
        drop(a);
        let _ = t.join();
    }

    #[test]
    fn head_read_returns_the_head_and_clears_the_timeout() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        b.write_all(b"CONNECT x.com:443 HTTP/1.1\r\n\r\nrest").unwrap();
        let (head, end) = read_head(&mut a, Duration::from_secs(5)).unwrap().unwrap();
        assert_eq!(&head[..end], b"CONNECT x.com:443 HTTP/1.1\r\n\r\n");
        assert_eq!(&head[end..], b"rest");
        assert_eq!(a.read_timeout().unwrap(), None);
    }

    #[test]
    fn tunnel_copies_both_ways_and_half_closes() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut got = Vec::new();
            s.read_to_end(&mut got).unwrap();
            s.write_all(b"echo:").unwrap();
            s.write_all(&got).unwrap();
        });
        let (mut client, side) = UnixStream::pair().unwrap();
        let u = TcpStream::connect(addr).unwrap();
        let t = thread::spawn(move || tunnel(&side, &u));
        client.write_all(b"hi").unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut out = String::new();
        client.read_to_string(&mut out).unwrap();
        assert_eq!(out, "echo:hi");
        t.join().unwrap();
        server.join().unwrap();
    }

    #[test]
    fn connect_tries_every_address() {
        let dead = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let live = TcpListener::bind("127.0.0.1:0").unwrap();
        let (s, used) = connect_any(&[dead, live.local_addr().unwrap()], CONNECT_TIMEOUT).unwrap();
        assert_eq!(s.peer_addr().unwrap(), live.local_addr().unwrap());
        assert_eq!(used, live.local_addr().unwrap());
        assert!(connect_any(&[dead], CONNECT_TIMEOUT).is_err());
        assert!(connect_any(&[], CONNECT_TIMEOUT).is_err());
    }

    #[test]
    fn open_file_limit_is_raised() {
        let now = raise_nofile_limit().unwrap();
        let mut l = RLimit { cur: 0, max: 0 };
        assert_eq!(unsafe { getrlimit(RLIMIT_NOFILE, &mut l) }, 0);
        assert_eq!(l.cur, now);
        assert!(l.cur >= l.max.min(NOFILE_WANT), "{} {}", l.cur, l.max);
    }
}
