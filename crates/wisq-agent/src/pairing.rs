//! Pairing: the links the daemon prints so the phone can find it.
//!
//! The format is shared with `AgentPairing` in WisqCore — the Swift side parses
//! exactly this, so the two must not drift.

use std::process::{Command, Stdio};

/// One pairing URL per reachable address, hostname first when it resolves.
///
/// `fingerprint` is the SHA-256 of the daemon's TLS certificate, when TLS is
/// on. Its presence in the link is what tells the phone to speak HTTPS and to
/// pin exactly that certificate — the link is the certificate story, the same
/// way it is already the token story. An old link without `fp` still means
/// plain HTTP, so nothing already printed on a screen somewhere breaks.
pub fn urls(
    port: u16,
    token: &str,
    host_name: Option<&str>,
    fingerprint: Option<&str>,
) -> Vec<String> {
    let mut hosts: Vec<String> = Vec::new();
    if let Some(name) = host_name {
        if !name.is_empty() && name != "localhost" {
            hosts.push(name.to_string());
        }
    }
    hosts.extend(local_addresses());

    let label = host_name.unwrap_or("agent");
    hosts
        .iter()
        .map(|host| {
            let mut url = format!(
                "wisq://agent?host={}&port={}&token={}&name={}",
                percent_encode(host),
                port,
                percent_encode(token),
                percent_encode(label)
            );
            if let Some(fingerprint) = fingerprint {
                url.push_str("&fp=");
                url.push_str(fingerprint);
            }
            url
        })
        .collect()
}

/// IPv4 addresses of the machine, loopback excluded.
///
/// Read from the OS rather than guessed. `getifaddrs` would need libc; `hostname
/// -I` on Linux and `ipconfig` on macOS are both present on the systems this
/// daemon installs on, and an absent one costs a pairing line, never the daemon.
fn local_addresses() -> Vec<String> {
    let candidates: [(&str, &[&str]); 3] = [
        ("hostname", &["-I"]),
        ("ipconfig", &["getifaddr", "en0"]),
        ("ipconfig", &["getifaddr", "en1"]),
    ];

    let mut found = Vec::new();
    for (program, arguments) in candidates {
        let Ok(output) = Command::new(program).args(arguments).output() else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        for token in String::from_utf8_lossy(&output.stdout).split_whitespace() {
            let address = token.trim();
            if address.is_empty()
                || address.starts_with("127.")
                || found.iter().any(|existing| existing == address)
            {
                continue;
            }
            // IPv4 only: the pairing URL goes in a QR code a person points a
            // phone at, and an IPv6 literal there is unreadable and needs
            // brackets the URL form does not carry.
            if address.split('.').count() == 4
                && address.chars().all(|c| c.is_ascii_digit() || c == '.')
            {
                found.push(address.to_string());
            }
        }
    }
    found
}

/// Percent-encodes what a query value must not contain.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Prints a QR for the first pairing URL when `qrencode` is installed.
///
/// A convenience that is absent must never stop the daemon serving, so every
/// failure here is silent.
pub fn print_qr_code_if_possible(url: &str) {
    let _ = Command::new("qrencode")
        .args(["-t", "ANSIUTF8", url])
        .stdout(Stdio::inherit())
        .stderr(Stdio::null())
        .status();
}

/// Announces the daemon over Bonjour, at best effort.
///
/// `avahi-publish-service` on Linux, `dns-sd` on macOS, and silently nothing
/// otherwise. The child is left running for the lifetime of the daemon; both
/// tools stop advertising when their process ends, which is exactly right.
pub fn advertise(port: u16, name: &str) {
    let attempts: [(&str, Vec<String>); 2] = [
        (
            "avahi-publish-service",
            vec![
                name.to_string(),
                "_wisq-agent._tcp".into(),
                port.to_string(),
            ],
        ),
        (
            "dns-sd",
            vec![
                "-R".into(),
                name.to_string(),
                "_wisq-agent._tcp".into(),
                "local".into(),
                port.to_string(),
            ],
        ),
    ];

    for (program, arguments) in attempts {
        if Command::new(program)
            .args(&arguments)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .is_ok()
        {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pairing_url_carries_host_port_token_and_name() {
        let urls = urls(7442, "abc123", Some("nas"), None);
        assert!(!urls.is_empty());
        let first = &urls[0];
        assert!(first.starts_with("wisq://agent?"));
        assert!(first.contains("host=nas"));
        assert!(first.contains("port=7442"));
        assert!(first.contains("token=abc123"));
        assert!(first.contains("name=nas"));
    }

    #[test]
    fn values_that_would_break_the_query_are_encoded() {
        let urls = urls(1, "a b&c=d", Some("my host"), None);
        assert!(urls[0].contains("token=a%20b%26c%3Dd"));
        assert!(urls[0].contains("host=my%20host"));
    }

    /// A SHA-256 digest in hex, the length `AgentPairing.parse` demands on the
    /// Swift side. This test used to pass `aa11bb22` — four bytes — and assert
    /// the link ended with it, which quietly documented a link the phone
    /// refuses. A fixture the other end would reject is a fixture that
    /// describes a contract nobody has.
    const A_REAL_FINGERPRINT: &str =
        "07070707070707070707070707070707070707070707070707070707070707aa";

    #[test]
    fn the_fingerprint_rides_the_link_only_when_tls_is_on() {
        let with = urls(7442, "t", Some("nas"), Some(A_REAL_FINGERPRINT));
        assert!(
            with[0].ends_with(&format!("&fp={A_REAL_FINGERPRINT}")),
            "{}",
            with[0]
        );
        let without = urls(7442, "t", Some("nas"), None);
        assert!(!without[0].contains("fp="), "{}", without[0]);
    }

    /// The length the Swift side demands, asserted here rather than assumed.
    /// `AgentPairing.fingerprintByteCount` is 32, so 64 hex characters.
    #[test]
    fn the_fingerprint_in_a_link_is_the_length_the_phone_accepts() {
        let link = &urls(7442, "t", Some("nas"), Some(A_REAL_FINGERPRINT))[0];
        let hex = link
            .rsplit("&fp=")
            .next()
            .expect("le lien porte une empreinte");
        assert_eq!(hex.len(), 64, "{link}");
        assert!(
            hex.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "{link}"
        );
    }

    #[test]
    fn loopback_is_never_offered_as_a_pairing_address() {
        for url in urls(7442, "t", Some("host"), None) {
            assert!(!url.contains("host=127."), "{url}");
        }
    }
}
