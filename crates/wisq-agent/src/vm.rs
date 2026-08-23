//! The wire model, and just enough JSON to write it.
//!
//! The shapes here are the contract in docs/AGENT-PROTOCOL.md, and the Swift
//! client decodes them with `Codable`. A JSON library would be a dependency
//! carried for four object shapes that never change.

use std::fmt::Write as _;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Running,
    Paused,
    Stopped,
    Starting,
    Unknown,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Paused => "paused",
            State::Stopped => "stopped",
            State::Starting => "starting",
            State::Unknown => "unknown",
        }
    }
}

/// What the guest runs. The app uses it only to pick an icon, so `Other` is
/// what an agent reports when it has no better answer — the virsh backend never
/// guesses, and leaves the field out entirely.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuestOs {
    Linux,
    Windows,
    #[allow(dead_code)]
    Other,
}

impl GuestOs {
    pub fn as_str(self) -> &'static str {
        match self {
            GuestOs::Linux => "linux",
            GuestOs::Windows => "windows",
            GuestOs::Other => "other",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vm {
    pub id: String,
    pub name: String,
    pub state: State,
    /// Present only once the console is up; the client polls until it appears.
    pub console_protocol: Option<&'static str>,
    pub console_port: Option<u16>,
    pub guest_os: Option<GuestOs>,
}

impl Vm {
    pub fn new(id: &str, name: &str, state: State) -> Self {
        Vm {
            id: id.to_string(),
            name: name.to_string(),
            state,
            console_protocol: None,
            console_port: None,
            guest_os: None,
        }
    }

    pub fn to_json(&self) -> String {
        // Keys are alphabetical, matching what the Swift daemon emitted, so a
        // recorded response from either side reads the same.
        let mut out = String::with_capacity(160);
        out.push('{');
        if let Some(port) = self.console_port {
            let _ = write!(out, "\"consolePort\":{port},");
        }
        if let Some(protocol) = self.console_protocol {
            let _ = write!(out, "\"consoleProtocol\":\"{protocol}\",");
        }
        if let Some(os) = self.guest_os {
            let _ = write!(out, "\"guestOS\":\"{}\",", os.as_str());
        }
        let _ = write!(out, "\"id\":\"{}\",", escape(&self.id));
        let _ = write!(out, "\"name\":\"{}\",", escape(&self.name));
        let _ = write!(out, "\"state\":\"{}\"", self.state.as_str());
        out.push('}');
        out
    }
}

pub fn list_to_json(vms: &[Vm]) -> String {
    let mut out = String::from("[");
    for (index, vm) in vms.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str(&vm.to_json());
    }
    out.push(']');
    out
}

/// Escapes what JSON requires. Domain names are tame, but a libvirt domain can
/// be called anything, and an unescaped quote would produce a response the
/// client cannot parse.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

/// Reads one boolean field out of a small JSON object.
///
/// The only body this daemon accepts is `{"force": true}`. A parser that
/// understands all of JSON to find one boolean would be more code than the
/// thing it parses.
pub fn json_bool(body: &str, field: &str) -> Option<bool> {
    let needle = format!("\"{field}\"");
    let start = body.find(&needle)? + needle.len();
    let rest = body[start..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omits_console_fields_until_the_console_exists() {
        let vm = Vm::new("debian-13", "Debian 13", State::Stopped);
        assert_eq!(
            vm.to_json(),
            r#"{"id":"debian-13","name":"Debian 13","state":"stopped"}"#
        );
    }

    #[test]
    fn includes_console_fields_once_running() {
        let mut vm = Vm::new("debian-13", "Debian 13", State::Running);
        vm.console_protocol = Some("vnc");
        vm.console_port = Some(5901);
        vm.guest_os = Some(GuestOs::Linux);
        assert_eq!(
            vm.to_json(),
            r#"{"consolePort":5901,"consoleProtocol":"vnc","guestOS":"linux","id":"debian-13","name":"Debian 13","state":"running"}"#
        );
    }

    #[test]
    fn escapes_names_that_would_break_the_response() {
        let vm = Vm::new("a\"b", "back\\slash", State::Unknown);
        assert_eq!(
            vm.to_json(),
            r#"{"id":"a\"b","name":"back\\slash","state":"unknown"}"#
        );
    }

    #[test]
    fn reads_the_force_flag() {
        assert_eq!(json_bool(r#"{"force":true}"#, "force"), Some(true));
        assert_eq!(json_bool(r#"{ "force" : false }"#, "force"), Some(false));
        assert_eq!(json_bool(r#"{}"#, "force"), None);
        assert_eq!(json_bool(r#"{"force":"yes"}"#, "force"), None);
    }
}
