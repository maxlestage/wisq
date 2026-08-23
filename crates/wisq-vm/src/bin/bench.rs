//! Boots a real kernel and reports interpreter throughput.
//!
//! Deliberately the same shape as the Swift `wisq-bench`, down to the wording,
//! because the only useful comparison between two implementations is one where
//! nothing but the implementation differs.
//!
//!   cargo run --release --bin wisq-bench-rs -- --image /path/to/Image

use std::sync::{Arc, Mutex};
use std::time::Instant;
use wisq_vm::{Machine, DEFAULT_RAM_SIZE};

fn argument(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    let index = args.iter().position(|a| a == name)?;
    args.get(index + 1).cloned()
}

fn main() {
    let image_path = argument("--image")
        .or_else(|| std::env::var("WISQ_LINUX_IMAGE").ok())
        .unwrap_or_else(|| "/tmp/wisq-test-linux-image/Image".to_string());
    let budget: u64 = argument("--instructions")
        .and_then(|v| v.parse().ok())
        .unwrap_or(200_000_000);
    let marker = argument("--until").unwrap_or_else(|| "buildroot login:".to_string());

    let Ok(image) = std::fs::read(&image_path) else {
        eprintln!("image introuvable : {image_path}");
        std::process::exit(2);
    };

    // Construction cost is not a footnote on a phone: it is 64 MB of guest RAM
    // being obtained, and whether those pages become resident up front decides
    // both the tap-to-boot delay and how much memory the app holds.
    let alloc_start = Instant::now();

    let console = Arc::new(Mutex::new(Console::default()));
    let sink = Arc::clone(&console);

    // The stop is decided inside the output callback, synchronously, exactly
    // where the Swift benchmark decides it. A watcher thread polling for the
    // marker would let the guest run a little further before noticing, and the
    // instruction counts would stop being comparable.
    let stopper: Arc<Mutex<Option<wisq_vm::Handle>>> = Arc::new(Mutex::new(None));
    let trigger = Arc::clone(&stopper);
    let watch_marker = marker.clone();

    let mut machine = Machine::new(
        DEFAULT_RAM_SIZE,
        Box::new(move |bytes: &[u8]| {
            let mut guard = sink.lock().unwrap();
            guard.add(bytes);
            if guard.reached(&watch_marker) {
                if let Some(handle) = trigger.lock().unwrap().as_ref() {
                    handle.stop();
                }
            }
        }),
    );
    let alloc_ms = alloc_start.elapsed().as_secs_f64() * 1000.0;

    *stopper.lock().unwrap() = Some(machine.handle());
    machine.load(&image, None).expect("chargement du noyau");

    let start = Instant::now();
    let outcome = machine.run(budget);
    let elapsed = start.elapsed().as_secs_f64();

    let retired = machine.retired_instructions();
    let mips = retired as f64 / elapsed / 1e6;
    let guard = console.lock().unwrap();

    println!(
        "instructions : {:.1} M retirées (budget {:.0} M)",
        retired as f64 / 1e6,
        budget as f64 / 1e6
    );
    println!("construction : {alloc_ms:.1} ms (64 Mo de RAM invitée)");
    println!("durée        : {elapsed:.3} s");
    println!("débit        : {mips:.1} MIPS");
    println!(
        "repère « {} » : {}",
        marker,
        if guard.reached(&marker) {
            "atteint"
        } else {
            "PAS ATTEINT"
        }
    );
    println!(
        "bannière noyau : {}   sortie : {} octets   issue : {:?}",
        if guard.reached("Linux version") {
            "oui"
        } else {
            "NON"
        },
        guard.bytes,
        outcome
    );

    if std::env::args().any(|a| a == "--console") {
        println!("--- console ---");
        println!("{}", guard.text);
    }

    // A benchmark that does not check the guest actually booted measures
    // nothing.
    if !guard.reached("Linux version") {
        eprintln!("le noyau n'a pas démarré : mesure sans valeur");
        std::process::exit(1);
    }
}

#[derive(Default)]
struct Console {
    text: String,
    bytes: usize,
}

impl Console {
    fn add(&mut self, bytes: &[u8]) {
        self.bytes += bytes.len();
        if self.text.len() < 65_536 {
            self.text.push_str(&String::from_utf8_lossy(bytes));
        }
    }

    fn reached(&self, needle: &str) -> bool {
        self.text.contains(needle)
    }
}
