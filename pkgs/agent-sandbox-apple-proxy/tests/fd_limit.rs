//! Out of file descriptors, the proxy waits rather than spinning on
//! accept(), and serves again once they are back. Its own test binary,
//! as it reads the CPU time of waited-for children.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

#[repr(C)]
struct RLimit {
    cur: u64,
    max: u64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct TimeVal {
    sec: i64,
    #[cfg(target_os = "macos")]
    usec: i32,
    #[cfg(not(target_os = "macos"))]
    usec: i64,
}

#[repr(C)]
struct RUsage {
    utime: TimeVal,
    stime: TimeVal,
    rest: [i64; 32],
}

extern "C" {
    fn setrlimit(resource: i32, rlim: *const RLimit) -> i32;
    fn getrusage(who: i32, usage: *mut RUsage) -> i32;
}

#[cfg(any(target_os = "linux", target_os = "android"))]
const RLIMIT_NOFILE: i32 = 7;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
const RLIMIT_NOFILE: i32 = 8;
const RUSAGE_CHILDREN: i32 = -1;

fn children_cpu() -> f64 {
    let mut u = RUsage {
        utime: TimeVal::default(),
        stime: TimeVal::default(),
        rest: [0; 32],
    };
    assert_eq!(unsafe { getrusage(RUSAGE_CHILDREN, &mut u) }, 0);
    let t = |v: TimeVal| v.sec as f64 + v.usec as f64 / 1e6;
    t(u.utime) + t(u.stime)
}

#[test]
fn out_of_fds_it_waits_instead_of_spinning() {
    let dir = std::env::temp_dir().join(format!("asap-{}-fds", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("allow"), "localhost\n").unwrap();
    fs::write(dir.join("startup"), "").unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_agent-sandbox-apple-proxy"));
    cmd.arg("--socket")
        .arg(dir.join("sock"))
        .arg("--allow")
        .arg(dir.join("allow"))
        .arg("--startup")
        .arg(dir.join("startup"))
        .arg("--log")
        .arg(dir.join("log"))
        .stdout(Stdio::piped());
    // A hard limit of 32 open files, which the proxy cannot raise.
    unsafe {
        cmd.pre_exec(|| {
            let l = RLimit { cur: 32, max: 32 };
            if setrlimit(RLIMIT_NOFILE, &l) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let before = children_cpu();
    let mut child = cmd.spawn().unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.as_mut().unwrap())
        .read_line(&mut line)
        .unwrap();
    assert_eq!(line.trim(), "ready");

    // More idle clients than it has descriptors for, held for 2 s.
    let clients: Vec<UnixStream> = (0..60)
        .map(|_| UnixStream::connect(dir.join("sock")).unwrap())
        .collect();
    thread::sleep(Duration::from_secs(2));
    drop(clients);

    // It serves again.
    let mut s = UnixStream::connect(dir.join("sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    s.write_all(b"CONNECT example.org:443 HTTP/1.1\r\n\r\n").unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    assert!(out.starts_with("HTTP/1.1 403"), "{out}");

    child.kill().unwrap();
    child.wait().unwrap();
    let cpu = children_cpu() - before;
    let _ = fs::remove_dir_all(&dir);
    assert!(cpu < 0.5, "the proxy used {cpu:.2} s of CPU while out of descriptors");
}
