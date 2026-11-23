//! The decisions: which targets may be reached, and which addresses count
//! as public. Pure, so it is unit-tested without sockets.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// The target a client sends to say the VM has finished starting.
const LATCH_HOST: &str = "agent-sandbox-apple.start-done";

#[derive(Debug)]
pub enum Decision {
    /// The startup-only hosts are closed from now on.
    Latch,
    Connect { host: String, port: u16 },
    Deny(&'static str),
}

pub struct Policy {
    agent: Vec<String>,
    startup: Vec<String>,
    latched: bool,
}

impl Policy {
    pub fn new(agent: Vec<String>, startup: Vec<String>) -> Policy {
        Policy { agent, startup, latched: false }
    }

    pub fn decide(&mut self, target: &str) -> Decision {
        let Some((host, port)) = target.rsplit_once(':') else {
            return Decision::Deny("bad target");
        };
        let Ok(port) = port.parse::<u16>() else {
            return Decision::Deny("bad port");
        };
        if host.eq_ignore_ascii_case(LATCH_HOST) && port == 0 {
            self.latched = true;
            return Decision::Latch;
        }
        // The allow-list holds names only: no IP literals, bracketed or not.
        if host.is_empty()
            || port == 0
            || host.contains([':', '[', ']'])
            || host.trim_end_matches('.').parse::<IpAddr>().is_ok()
        {
            return Decision::Deny("bad target");
        }
        let ok = host_allowed(host, &self.agent)
            || (!self.latched && host_allowed(host, &self.startup));
        if ok {
            Decision::Connect { host: host.to_string(), port }
        } else {
            Decision::Deny("allow-list")
        }
    }
}

/// An exact or subdomain match, ignoring case and a trailing dot.
pub fn host_allowed(host: &str, list: &[String]) -> bool {
    let h = host.trim_end_matches('.').to_ascii_lowercase();
    list.iter().any(|d| {
        let d = d.trim().trim_start_matches('.').trim_end_matches('.').to_ascii_lowercase();
        !d.is_empty() && (h == d || h.ends_with(&format!(".{d}")))
    })
}

/// True only for addresses on the public internet.
pub fn is_global(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => is_global_v4(a),
        IpAddr::V6(a) => match a.to_ipv4_mapped() {
            Some(v4) => is_global_v4(v4),
            None => is_global_v6(a),
        },
    }
}

fn is_global_v4(a: Ipv4Addr) -> bool {
    let o = a.octets();
    !(a.is_unspecified()
        || a.is_loopback()
        || a.is_private()
        || a.is_link_local()
        || a.is_broadcast()
        || a.is_documentation()
        || a.is_multicast()
        || o[0] == 0 // 0.0.0.0/8
        || (o[0] == 100 && o[1] & 0xc0 == 64) // CGNAT 100.64/10
        || (o[0] == 192 && o[1] == 0 && o[2] == 0) // IETF protocol 192.0.0/24
        || (o[0] == 198 && o[1] & 0xfe == 18) // benchmarking 198.18/15
        || o[0] >= 240) // reserved
}

fn is_global_v6(a: Ipv6Addr) -> bool {
    let s = a.segments();
    !(a.is_unspecified()
        || a.is_loopback()
        || a.is_multicast()
        || s[0] & 0xfe00 == 0xfc00 // ULA fc00::/7
        || s[0] & 0xffc0 == 0xfe80 // link-local fe80::/10
        || (s[0] == 0x2001 && s[1] == 0x0db8) // documentation
        || (s[0] == 0x64 && s[1] == 0xff9b && s[2..6] == [0, 0, 0, 0])) // NAT64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn exact_and_subdomain_match() {
        let l = vec!["anthropic.com".into()];
        assert!(host_allowed("anthropic.com", &l));
        assert!(host_allowed("API.anthropic.com.", &l));
        assert!(!host_allowed("evilanthropic.com", &l));
        assert!(!host_allowed("api.anthropic.com.attacker.net", &l));
    }
    #[test] fn non_global_addresses() {
        for a in ["127.0.0.1","10.0.0.1","172.16.0.1","192.168.64.1",
                  "169.254.169.254","100.64.0.1","0.0.0.0","::1","fe80::1",
                  "fc00::1","::ffff:192.168.1.1","::ffff:127.0.0.1"] {
            assert!(!is_global(a.parse().unwrap()), "{a}");
        }
        for a in ["1.1.1.1","2606:4700::1111"] { assert!(is_global(a.parse().unwrap())); }
    }
    #[test] fn latch_closes_startup_hosts_for_good() {
        let mut p = Policy::new(vec!["api.anthropic.com".into()], vec!["cache.nixos.org".into()]);
        assert!(matches!(p.decide("cache.nixos.org:443"), Decision::Connect{..}));
        assert!(matches!(p.decide("agent-sandbox-apple.start-done:0"), Decision::Latch));
        assert!(matches!(p.decide("cache.nixos.org:443"), Decision::Deny(_)));
        assert!(matches!(p.decide("agent-sandbox-apple.start-done:0"), Decision::Latch));
        assert!(matches!(p.decide("cache.nixos.org:443"), Decision::Deny(_)));
        assert!(matches!(p.decide("api.anthropic.com:443"), Decision::Connect{..}));
    }
    #[test] fn bad_targets_are_denied() {
        let mut p = Policy::new(vec!["a.com".into()], vec![]);
        for t in ["a.com", "a.com:x", "a.com:70000", "[::1]:443", "1.1.1.1:443"] {
            assert!(matches!(p.decide(t), Decision::Deny(_)), "{t}");
        }
    }
}
