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
    /// When a *graceful* stop was requested. A polite shutdown is a request,
    /// not an act: libvirt sends ACPI and returns, the guest finishes in its
    /// own time — or never, if it has nobody listening for the button. Until
    /// then the domain is still `running`, with its console still open.
    ///
    /// This backend used to ignore `force` entirely and report `stopped` at
    /// once, which taught the opposite of what really happens and made the one
    /// distinction the request body carries invisible.
    stopping_since: Option<Instant>,
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
                stopping_since: None,
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
                stopping_since: None,
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
        if let Some(since) = entry.stopping_since {
            if since.elapsed() >= self.startup_delay {
                entry.stopping_since = None;
                entry.vm.state = State::Stopped;
                entry.vm.console_protocol = None;
                entry.vm.console_port = None;
            }
            return;
        }
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

    /// The two halves of `force`, which this backend used to collapse into one.
    ///
    /// `force: true` is the power cord: `virsh destroy` takes the domain away
    /// and the next read says `shut off`. `force: false` is the button: libvirt
    /// sends ACPI and returns immediately, and the guest is still running —
    /// with its console still open — until it decides otherwise.
    fn stop(&self, id: &str, force: bool) -> Result<Vm> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(id)
            .ok_or(format!("VM introuvable : {id}"))?;
        entry.starting_since = None;
        if force {
            entry.stopping_since = None;
            entry.vm.state = State::Stopped;
            entry.vm.console_port = None;
            entry.vm.console_protocol = None;
            return Ok(entry.vm.clone());
        }
        // A guest that was not running has nothing to be asked politely.
        if entry.vm.state == State::Stopped {
            return Ok(entry.vm.clone());
        }
        entry.stopping_since = Some(Instant::now());
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

impl VirshBackend {
    /// The domains libvirt knows about, by name.
    ///
    /// One `virsh` call, and no `domstate` per domain: this answers "does it
    /// exist" without asking anything else about it, which is what `get` needs
    /// and all it needs.
    fn names(&self) -> Result<Vec<String>> {
        Ok(self
            .run(&["list", "--all", "--name"])?
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect())
    }
}

impl Backend for VirshBackend {
    fn list(&self) -> Result<Vec<Vm>> {
        self.names()?
            .iter()
            .map(|name| self.describe(name))
            .collect()
    }

    /// Absent and unreachable are different answers, and this used to give the
    /// first for both.
    ///
    /// `Ok(self.describe(id).ok())` turned every failure into "no such VM": a
    /// host with libvirtd stopped, or without `virsh` installed at all, told
    /// the phone *VM introuvable : debian-13* about a machine that exists and
    /// is fine. The service's `Err(message) => 500` arm could never run, so the
    /// one place prepared to report the real cause was unreachable code.
    ///
    /// Asking the domain about itself cannot separate the two: `virsh domstate`
    /// exits non-zero for an unknown domain and for a hypervisor it cannot
    /// reach, and telling those apart would mean reading its prose. So the
    /// question is asked of the *list* instead, which fails only when libvirt
    /// fails. A name that is not in a list libvirt successfully produced is
    /// genuinely not there — that is the other edge, and it still answers 404.
    fn get(&self, id: &str) -> Result<Option<Vm>> {
        if !self.names()?.iter().any(|name| name == id) {
            return Ok(None);
        }
        self.describe(id).map(Some)
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

#[cfg(test)]
mod virsh_tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    /// A `virsh` of our own: a shell script that prints what the test wants and
    /// exits how the test wants.
    ///
    /// The alternative — a trait around `Command` — would let the tests agree
    /// with a mock about something the real binary does differently. This runs
    /// the actual spawn, the actual exit status and the actual stdout, so what
    /// is exercised is the code path a host takes.
    struct FakeVirsh {
        path: std::path::PathBuf,
        _dir: std::path::PathBuf,
    }

    impl FakeVirsh {
        fn new(script: &str) -> FakeVirsh {
            let dir = std::env::temp_dir()
                .join(format!("wisq-virsh-{}", std::process::id()))
                .join(
                    format!("{:?}", std::time::SystemTime::now())
                        .replace([' ', ':', '{', '}'], "_"),
                );
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("virsh");
            let mut file = std::fs::File::create(&path).unwrap();
            writeln!(file, "#!/bin/sh\n{script}").unwrap();
            drop(file);
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            wait_until_executable(&path);
            FakeVirsh { path, _dir: dir }
        }

        fn backend(&self) -> VirshBackend {
            VirshBackend::new(self.path.to_string_lossy().into_owned())
        }
    }

    impl Drop for FakeVirsh {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self._dir);
        }
    }

    /// Waits for a freshly written script to be executable, and only for that.
    ///
    /// Found by a red build rather than by reading: `Text file busy`. Rust runs
    /// tests on several threads, and `Command::spawn` forks — a child forked
    /// while this file was still open for writing inherits that descriptor and
    /// holds it until its own `exec`, and Linux refuses to execute a file any
    /// process has open for writing. The window is a few microseconds wide and
    /// belongs to whichever other test happened to be starting a process, which
    /// is why it passed here, passed in CI, and failed on the next run.
    ///
    /// So this waits — and waits for **that** and nothing else. Any other error
    /// is returned as it is, so a genuinely missing binary still fails the test
    /// that is about a genuinely missing binary rather than spinning here.
    fn wait_until_executable(path: &std::path::Path) {
        const ETXTBSY: i32 = 26;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match Command::new(path).arg("--probe-de-disponibilite").output() {
                Err(error) if error.raw_os_error() == Some(ETXTBSY) => {
                    std::thread::sleep(Duration::from_millis(1));
                }
                _ => return,
            }
        }
        panic!("le faux virsh est resté « Text file busy » cinq secondes");
    }

    /// The probe has to be able to say "something here" before "nothing here"
    /// means anything: a fake that never worked would make every test below
    /// pass for the wrong reason.
    #[test]
    fn the_fake_virsh_answers_at_all() {
        let virsh = FakeVirsh::new(
            r#"case "$1" in
  list) echo debian-13 ;;
  domstate) echo running ;;
  vncdisplay) echo :1 ;;
esac"#,
        );
        let vm = virsh
            .backend()
            .get("debian-13")
            .unwrap()
            .expect("la VM doit être trouvée");
        assert_eq!(vm.state, State::Running);
        assert_eq!(vm.console_port, Some(5901));
    }

    /// The defect. `Ok(self.describe(id).ok())` turned every failure into "no
    /// such VM", so a host whose libvirtd is stopped told the phone the machine
    /// did not exist — and the service arm that reports the real cause was
    /// unreachable code.
    #[test]
    fn a_hypervisor_that_cannot_be_reached_is_not_a_missing_vm() {
        let virsh = FakeVirsh::new(
            r#"echo "error: failed to connect to the hypervisor" >&2
exit 1"#,
        );
        match virsh.backend().get("debian-13") {
            Err(message) => assert!(
                message.contains("hypervisor"),
                "la cause réelle doit remonter, obtenu : {message}"
            ),
            Ok(other) => panic!("un hyperviseur injoignable a été rendu comme {other:?}"),
        }
    }

    /// And when `virsh` is not installed at all, which is the same lie by a
    /// different route.
    #[test]
    fn a_missing_virsh_is_not_a_missing_vm() {
        let backend = VirshBackend::new("/n/existe/pas/virsh".to_string());
        assert!(
            backend.get("debian-13").is_err(),
            "un virsh absent a été rendu comme une VM absente"
        );
    }

    /// The other edge, and half the work: a name libvirt successfully did not
    /// list is genuinely absent, and must still answer "absent" rather than an
    /// error. A fix that reported everything as unreachable would pass the two
    /// tests above and break the 404 the app relies on.
    #[test]
    fn a_domain_libvirt_does_not_list_is_still_absent() {
        let virsh = FakeVirsh::new(
            r#"case "$1" in
  list) echo debian-13 ;;
  *) echo "error: failed to get domain" >&2; exit 1 ;;
esac"#,
        );
        assert_eq!(virsh.backend().get("fantome").unwrap(), None);
    }

    /// `list` reads the same source, so a hypervisor it cannot reach is an
    /// error there too — it always was, and this pins it while the helper they
    /// now share is introduced.
    #[test]
    fn listing_propagates_what_it_cannot_reach() {
        let virsh = FakeVirsh::new("exit 1");
        assert!(virsh.backend().list().is_err());
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

    /// libvirt has no `starting`, and the protocol document used to promise one.
    ///
    /// `POST /v1/vms/{id}/start` was described as answering with the state
    /// `starting`. The demo backend does; this one cannot, because there is no
    /// `virsh domstate` output that means it — a domain is `running` from the
    /// moment it exists, while its guest is still bringing up a display. The
    /// document now says what holds for both backends, and this pins the half
    /// that made the old wording false.
    ///
    /// It is not a test of the `match` above by another name: it asserts about
    /// the function's whole range, so an arm added later that invented a
    /// `starting` out of some libvirt string would fail here rather than
    /// quietly make the client wait for a state that never arrives.
    /// The power cord takes the domain away at once, and the console with it.
    #[test]
    fn forcing_a_stop_takes_effect_immediately() {
        let backend = DemoBackend::new(Duration::from_secs(30));
        backend.start("win11").unwrap();
        std::thread::sleep(Duration::from_millis(5));
        // Force it out of `starting` as libvirt's `destroy` would.
        let stopped = backend.stop("win11", true).unwrap();
        assert_eq!(stopped.state, State::Stopped);
        assert_eq!(stopped.console_port, None);
        assert_eq!(backend.get("win11").unwrap().unwrap().state, State::Stopped);
    }

    /// And the button is a request. A guest that has not finished shutting down
    /// is still running, with its console still open — which is what libvirt
    /// reports after `virsh shutdown`, and what this backend used to hide by
    /// ignoring `force` and answering `stopped` to both.
    ///
    /// The delay is long enough that only a backend which reads `force` can
    /// pass: one that stops immediately fails the first assertion, one that
    /// never stops fails the last.
    #[test]
    fn a_graceful_stop_is_a_request_the_guest_answers_in_its_own_time() {
        let backend = DemoBackend::new(Duration::from_millis(80));
        backend.start("debian-13").unwrap();
        std::thread::sleep(Duration::from_millis(120));
        assert_eq!(
            backend.get("debian-13").unwrap().unwrap().state,
            State::Running,
            "l'invité doit avoir fini de démarrer avant qu'on lui demande de s'arrêter"
        );

        let asked = backend.stop("debian-13", false).unwrap();
        assert_eq!(
            asked.state,
            State::Running,
            "un arrêt ACPI est une demande : l'invité tourne encore quand elle revient"
        );
        assert!(
            asked.console_port.is_some(),
            "et sa console est encore ouverte"
        );

        std::thread::sleep(Duration::from_millis(120));
        let settled = backend.get("debian-13").unwrap().unwrap();
        assert_eq!(
            settled.state,
            State::Stopped,
            "puis l'invité finit par obéir"
        );
        assert_eq!(settled.console_port, None);
    }

    /// Asking politely twice is not an error, and asking a stopped guest is not
    /// a way to restart the clock: the other edge of the rule.
    #[test]
    fn a_graceful_stop_on_a_stopped_guest_changes_nothing() {
        let backend = DemoBackend::new(Duration::from_millis(10));
        let stopped = backend.stop("debian-13", false).unwrap();
        assert_eq!(stopped.state, State::Stopped);
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(
            backend.get("debian-13").unwrap().unwrap().state,
            State::Stopped
        );
    }

    #[test]
    fn no_libvirt_state_means_starting() {
        for output in [
            "running",
            "idle",
            "paused",
            "in shutdown",
            "shut off",
            "crashed",
            "pmsuspended",
            "no state",
            "",
            "starting",
        ] {
            assert_ne!(
                parse_domstate(output),
                State::Starting,
                "{output:?} a été lu comme « starting », que libvirt ne dit jamais"
            );
        }
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
