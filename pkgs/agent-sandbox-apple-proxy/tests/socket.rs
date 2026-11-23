use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};

struct Proxy {
    child: Child,
    dir: std::path::PathBuf,
}

impl Proxy {
    fn start(name: &str) -> Proxy {
        let dir = std::env::temp_dir().join(format!("asap-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("allow"), "localhost\n").unwrap();
        fs::write(dir.join("startup"), "").unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_agent-sandbox-apple-proxy"))
            .arg("--socket")
            .arg(dir.join("sock"))
            .arg("--allow")
            .arg(dir.join("allow"))
            .arg("--startup")
            .arg(dir.join("startup"))
            .arg("--log")
            .arg(dir.join("log"))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap())
            .read_line(&mut line)
            .unwrap();
        assert_eq!(line.trim(), "ready");
        Proxy { child, dir }
    }

    fn request(&self, req: &str) -> String {
        let mut s = UnixStream::connect(self.dir.join("sock")).unwrap();
        s.write_all(req.as_bytes()).unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        out
    }

    fn log(&self) -> String {
        fs::read_to_string(self.dir.join("log")).unwrap_or_default()
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn non_connect_gets_405() {
    let p = Proxy::start("405");
    assert!(p.request("GET / HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 405"));
}

#[test]
fn allowed_name_with_private_address_is_refused() {
    let p = Proxy::start("private");
    let r = p.request("CONNECT localhost:1 HTTP/1.1\r\n\r\n");
    assert!(r.starts_with("HTTP/1.1 403"), "{r}");
    assert!(p.log().contains("deny localhost:1 (non-global"), "{}", p.log());
}

#[test]
fn name_off_the_list_is_refused_before_resolving() {
    let p = Proxy::start("list");
    let r = p.request("CONNECT example.org:443 HTTP/1.1\r\n\r\n");
    assert!(r.starts_with("HTTP/1.1 403"), "{r}");
    assert!(p.log().contains("deny example.org:443 (allow-list)"), "{}", p.log());
}

#[test]
fn socket_mode_is_0600() {
    let p = Proxy::start("mode");
    let mode = fs::metadata(p.dir.join("sock")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn sigterm_exits_zero_and_removes_socket() {
    let mut p = Proxy::start("term");
    Command::new("kill")
        .arg(p.child.id().to_string())
        .status()
        .unwrap();
    let status = p.child.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    assert!(!p.dir.join("sock").exists());
}
