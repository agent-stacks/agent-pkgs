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
use std::time::Duration;

const MAX_HEAD: usize = 16 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

extern "C" {
    fn signal(signum: i32, handler: extern "C" fn(i32)) -> usize;
    fn unlink(path: *const std::os::raw::c_char) -> i32;
    fn _exit(code: i32) -> !;
    fn umask(mask: u32) -> u32;
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
    fn line(&self, s: &str) {
        if let Ok(mut f) = self.0.lock() {
            let _ = writeln!(f, "{s}");
        }
    }
}

/// Resolve once; refuse if any address is non-global; return the first.
fn resolve_public(host: &str, port: u16) -> Result<SocketAddr, String> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve: {e}"))?
        .collect();
    if let Some(bad) = addrs.iter().find(|a| !is_global(a.ip())) {
        return Err(format!("non-global {}", bad.ip()));
    }
    addrs.first().copied().ok_or_else(|| "resolve: no addresses".to_string())
}

/// Copy `from` to `to` until EOF, then close the write side of `to`.
fn pipe<R: Read, W: Write>(mut from: R, mut to: W, done: impl FnOnce()) {
    let _ = io::copy(&mut from, &mut to);
    done();
}

fn handle(mut c: UnixStream, policy: &Mutex<Policy>, log: &Log) -> io::Result<()> {
    let mut head = Vec::new();
    let mut buf = [0u8; 4096];
    let end = loop {
        if let Some(i) = head.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if head.len() > MAX_HEAD {
            return Ok(());
        }
        let n = c.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
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
    let addr = match resolve_public(&host, port) {
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
    let mut u = match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
        Ok(u) => u,
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
    let (c2, u2) = (c.try_clone()?, u.try_clone()?);
    let up = thread::spawn(move || pipe(c2, u2.try_clone().unwrap(), move || {
        let _ = u2.shutdown(Shutdown::Write);
    }));
    let c3 = c.try_clone()?;
    pipe(u, c, move || {
        let _ = c3.shutdown(Shutdown::Write);
    });
    let _ = up.join();
    Ok(())
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
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
        let Ok(conn) = conn else { continue };
        let (policy, log) = (Arc::clone(&policy), Arc::clone(&log));
        thread::spawn(move || {
            if let Err(e) = handle(conn, &policy, &log) {
                log.line(&format!("error {e}"));
            }
        });
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("agent-sandbox-apple-proxy: {e}");
        exit(2);
    }
}
