//! What the agent knows how to do to VMs, whatever runs them underneath.

use crate::vm::{GuestOs, State, Vm};
use std::collections::BTreeMap;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub type Result<T> = std::result::Result<T, String>;

pub trait Backend: Send + Sync {
    fn list(&self) -> Result<Vec<Vm>>;
    fn get(&self, id: &str) -> Result<Option<Vm>>;
    fn start(&self, id: &str) -> Result<Vm>;
    fn stop(&self, id: &str, force: bool) -> Result<Vm>;
}

/// In-memory backend with realistic state transitions. Two uses: exercising the
/// full client–agent round trip in tests, and trying the app without libvirt —
/// `wisq-agent --demo` gives the phone something honest to talk to.
pub struct DemoBackend {
    entries: Mutex<BTreeMap<String, Entry>>,
    startup_delay: Duration,
}

struct Entry {
    vm: Vm,
    running_port: u16,
    /// When a start was requested; the boot completes on its own, the way a
    /// real guest does, and the client discovers it by polling exactly as it
    /// will against libvirt.
    starting_since: Option<Instant>,
}

impl DemoBackend {
    pub fn new(startup_delay: Duration) -> Self {
        let mut entries = BTreeMap::new();
        let mut debian = Vm::new("debian-13", "Debian 13", State::Stopped);
        debian.guest_os = Some(GuestOs::Linux);
        entries.insert(
            "debian-13".to_string(),
            Entry {
                vm: debian,
                running_port: 5901,
                starting_since: None,
            },
        );
        let mut windows = Vm::new("win11", "Windows 11", State::Stopped);
        windows.guest_os = Some(GuestOs::Windows);
        entries.insert(
            "win11".to_string(),
            Entry {
                vm: windows,
                running_port: 5902,
                starting_since: None,
            },
        );
        DemoBackend {
            entries: Mutex::new(entries),
            startup_delay,
        }
    }

    /// Advances any boot whose delay has elapsed. Called on every read, so the
    /// transition happens without a timer thread that would outlive a stop.
    fn settle(&self, entry: &mut Entry) {
        let Some(since) = entry.starting_since else {
            return;
        };
        if since.elapsed() < self.startup_delay {
            return;
        }
        entry.starting_since = None;
        entry.vm.state = State::Running;
        entry.vm.console_protocol = Some("vnc");
        entry.vm.console_port = Some(entry.running_port);
    }
}

impl Backend for DemoBackend {
    fn list(&self) -> Result<Vec<Vm>> {
        let mut entries = self.entries.lock().unwrap();
        Ok(entries
            .values_mut()
            .map(|entry| {
                self.settle(entry);
                entry.vm.clone()
            })
            .collect())
    }

    fn get(&self, id: &str) -> Result<Option<Vm>> {
        let mut entries = self.entries.lock().unwrap();
        Ok(entries.get_mut(id).map(|entry| {
            self.settle(entry);
            entry.vm.clone()
        }))
    }

    fn start(&self, id: &str) -> Result<Vm> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(id)
            .ok_or(format!("VM introuvable : {id}"))?;
        self.settle(entry);
        if entry.vm.state == State::Running {
            return Ok(entry.vm.clone());
        }
        entry.vm.state = State::Starting;
        entry.vm.console_port = None;
        entry.vm.console_protocol = None;
        entry.starting_since = Some(Instant::now());
        Ok(entry.vm.clone())
    }

    fn stop(&self, id: &str, _force: bool) -> Result<Vm> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(id)
            .ok_or(format!("VM introuvable : {id}"))?;
        entry.starting_since = None;
        entry.vm.state = State::Stopped;
        entry.vm.console_port = None;
        entry.vm.console_protocol = None;
        Ok(entry.vm.clone())
    }
}

/// libvirt backend, driven through the `virsh` CLI rather than the C library:
/// no linking headache, and the daemon degrades to a clear error on hosts
/// without libvirt instead of failing to build on them.
pub struct VirshBackend {
    path: String,
}

impl VirshBackend {
    pub fn new(path: String) -> Self {
        VirshBackend { path }
    }

    fn run(&self, arguments: &[&str]) -> Result<String> {
        let output = Command::new(&self.path)
            .args(arguments)
            .output()
            .map_err(|e| format!("virsh introuvable ({}) : {e}", self.path))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    fn describe(&self, id: &str) -> Result<Vm> {
        let state = parse_domstate(&self.run(&["domstate", id])?);
        let mut vm = Vm::new(id, id, state);
        if state == State::Running {
            if let Some(port) = parse_vnc_display(self.run(&["vncdisplay", id]).ok().as_deref()) {
                vm.console_protocol = Some("vnc");
                vm.console_port = Some(port);
            }
        }
        Ok(vm)
    }
}

impl Backend for VirshBackend {
    fn list(&self) -> Result<Vec<Vm>> {
        self.run(&["list", "--all", "--name"])?
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|name| self.describe(name))
            .collect()
    }

    fn get(&self, id: &str) -> Result<Option<Vm>> {
        Ok(self.describe(id).ok())
    }

    fn start(&self, id: &str) -> Result<Vm> {
        self.run(&["start", id])?;
        self.describe(id)
    }

    fn stop(&self, id: &str, force: bool) -> Result<Vm> {
        // ACPI shutdown by default; destroy is the power cord.
        self.run(&[if force { "destroy" } else { "shutdown" }, id])?;
        self.describe(id)
    }
}

// Parsing, pure and testable without libvirt on the machine.

pub fn parse_domstate(output: &str) -> State {
    match output.trim() {
        "running" => State::Running,
        "paused" | "pmsuspended" => State::Paused,
        "shut off" | "in shutdown" | "crashed" => State::Stopped,
        _ => State::Unknown,
    }
}

/// virsh prints VNC displays as `:N` or `host:N`; the port is 5900 + N.
pub fn parse_vnc_display(output: Option<&str>) -> Option<u16> {
    let trimmed = output?.trim();
    let (_, display) = trimmed.rsplit_once(':')?;
    let display: u16 = display.parse().ok()?;
    5900u16.checked_add(display)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_every_domstate_libvirt_prints() {
        assert_eq!(parse_domstate("running\n"), State::Running);
        assert_eq!(parse_domstate("paused"), State::Paused);
        assert_eq!(parse_domstate("pmsuspended"), State::Paused);
        assert_eq!(parse_domstate("shut off\n\n"), State::Stopped);
        assert_eq!(parse_domstate("in shutdown"), State::Stopped);
        assert_eq!(parse_domstate("crashed"), State::Stopped);
        assert_eq!(parse_domstate("something new"), State::Unknown);
    }

    #[test]
    fn turns_a_vnc_display_into_a_port() {
        assert_eq!(parse_vnc_display(Some(":1\n")), Some(5901));
        assert_eq!(parse_vnc_display(Some("127.0.0.1:2")), Some(5902));
        assert_eq!(parse_vnc_display(Some("")), None);
        assert_eq!(parse_vnc_display(None), None);
    }

    #[test]
    fn a_demo_boot_reaches_running_and_publishes_a_console() {
        let backend = DemoBackend::new(Duration::from_millis(10));
        let started = backend.start("debian-13").unwrap();
        assert_eq!(started.state, State::Starting);
        assert_eq!(started.console_port, None);

        std::thread::sleep(Duration::from_millis(30));
        let settled = backend.get("debian-13").unwrap().unwrap();
        assert_eq!(settled.state, State::Running);
        assert_eq!(settled.console_port, Some(5901));
        assert_eq!(settled.console_protocol, Some("vnc"));
    }

    #[test]
    fn stopping_clears_the_console() {
        let backend = DemoBackend::new(Duration::from_millis(1));
        backend.start("win11").unwrap();
        std::thread::sleep(Duration::from_millis(10));
        let stopped = backend.stop("win11", true).unwrap();
        assert_eq!(stopped.state, State::Stopped);
        assert_eq!(stopped.console_port, None);
    }

    #[test]
    fn an_unknown_domain_is_an_error_not_a_panic() {
        let backend = DemoBackend::new(Duration::from_millis(1));
        assert!(backend.start("nope").is_err());
        assert!(backend.get("nope").unwrap().is_none());
    }
}
