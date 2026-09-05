//! wisq-agent: the daemon that lets the phone power VMs on before connecting.
//!
//!   wisq-agent                     libvirt via virsh, port 7442, TLS
//!   wisq-agent --demo              two fake VMs, for trying the app
//!   wisq-agent --port 9000
//!   wisq-agent --token SECRET      (otherwise generated and persisted)
//!   wisq-agent --no-tls            plain HTTP, for pre-0.3 clients and tunnels
//!
//! Rust because of what this is: a small daemon people install on a NAS or a
//! laptop and forget about. It has no interface, no platform framework and no
//! reason to carry a language runtime — and the previous Swift build had to be
//! linked statically against one, which made the download 22 MB for a program
//! that serves four routes.

mod backend;
mod domain;
mod http;
mod pairing;
mod service;
mod tls;
mod vm;

use backend::{Backend, DemoBackend, VirshBackend};
use service::Service;

use std::io::Write;
use std::time::Duration;

fn main() {
    let mut port: u16 = 7442;
    let mut token: Option<String> = None;
    let mut demo = false;
    let mut virsh = "/usr/bin/virsh".to_string();
    // How long a demo "boot" takes. Seconds when a person is watching, and
    // milliseconds when the cross-language protocol tests are, so they exercise
    // the starting→running transition without spending two seconds on it.
    let mut demo_delay = Duration::from_secs(2);
    let mut use_tls = true;

    let all: Vec<String> = std::env::args().skip(1).collect();

    // **Une sous-commande, et elle passe avant tout le reste.** `bureau` ne sert
    // pas le protocole : elle construit une machine à partir d'une image et
    // rend la main. Elle vit dans le même binaire parce qu'elle écrit le même
    // domaine que la route de création, et deux générateurs de XML libvirt
    // divergeraient à la première correction.
    if all.first().map(String::as_str) == Some("bureau") {
        desktop_command(all[1..].to_vec());
    }

    let mut arguments = all.into_iter();
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--port" => match arguments.next().and_then(|v| v.parse().ok()) {
                Some(value) => port = value,
                None => fail("--port attend un nombre entre 1 et 65535"),
            },
            "--token" => token = arguments.next(),
            "--demo" => demo = true,
            "--no-tls" => use_tls = false,
            "--demo-delay" => match arguments.next().and_then(|v| v.parse().ok()) {
                Some(ms) => demo_delay = Duration::from_millis(ms),
                None => fail("--demo-delay attend un nombre de millisecondes"),
            },
            "--virsh" => {
                if let Some(path) = arguments.next() {
                    virsh = path;
                }
            }
            "--help" | "-h" => {
                println!(
                    "wisq-agent [--port N] [--token SECRET] [--demo] [--demo-delay MS] [--virsh CHEMIN] [--no-tls]\n\n\
                     Sert le protocole décrit dans docs/AGENT-PROTOCOL.md. Sans --token, un\n\
                     jeton est généré au premier lancement et conservé dans ~/.wisq-agent/token.\n\
                     TLS est actif par défaut : le certificat auto-signé vit à côté du jeton\n\
                     et son empreinte voyage dans le lien d'appairage. --no-tls repasse en\n\
                     HTTP clair, pour un client d'avant 0.3 ou un tunnel qui chiffre déjà."
                );
                std::process::exit(0);
            }
            other => fail(&format!("argument inconnu : {other}")),
        }
    }

    let token = token.unwrap_or_else(resolve_stored_token);

    // The identity is loaded before the socket binds: a daemon that cannot
    // vouch for its certificate should fail loudly at startup, not on the
    // first connection.
    let identity = if use_tls {
        Some(
            tls::load_or_create(&state_directory())
                .unwrap_or_else(|error| fail(&format!("identité TLS : {error}"))),
        )
    } else {
        None
    };

    let backend: Box<dyn Backend> = if demo {
        Box::new(DemoBackend::new(demo_delay))
    } else {
        Box::new(VirshBackend::new(virsh))
    };

    let server = http::Server::bind(port)
        .unwrap_or_else(|error| fail(&format!("démarrage impossible : {error}")));
    let bound = server.port();

    let host_name = host_name();
    // Written straight to stdout and flushed: a daemon's startup lines must
    // reach journald or a log file as they happen, not when a buffer fills.
    emit(&format!(
        "wisq-agent en écoute sur le port {bound} ({})",
        if demo { "démo" } else { "virsh" }
    ));
    emit(&format!("jeton : {token}"));
    match &identity {
        Some(identity) => emit(&format!("TLS : sha256 {}", identity.fingerprint)),
        None => emit("TLS désactivé (--no-tls) : réseau de confiance ou tunnel uniquement"),
    }

    let urls = pairing::urls(
        bound,
        &token,
        host_name.as_deref(),
        identity
            .as_ref()
            .map(|identity| identity.fingerprint.as_str()),
    );
    if !urls.is_empty() {
        emit("appairage :");
        for url in &urls {
            emit(&format!("  {url}"));
        }
        emit("");
        pairing::print_qr_code_if_possible(&urls[0]);
    }

    // The service name doubles as the address: mDNS makes host "nas" reachable
    // at nas.local, so the app can offer "<name>.local" without resolving SRV.
    pairing::advertise(bound, host_name.as_deref().unwrap_or("wisq-agent"));

    let service = Service::new(backend, token);
    let transport = match identity {
        Some(identity) => http::Transport::Tls(identity.config),
        None => http::Transport::Plain,
    };
    server.serve(transport, move |request| service.handle(request));
}

/// `wisq-agent bureau` : d'une image à un bureau, en une commande.
///
/// **Ce que cette commande résout.** wisq affiche un bureau distant depuis
/// longtemps ; ce qui manquait, c'était la machine à afficher. Écrire un domaine
/// libvirt à la main demande de connaître le modèle de carte graphique qui va
/// avec son compositeur, l'ordre d'amorçage, le canal de l'agent invité et le
/// mot de passe SPICE. Quatre occasions de se tromper, dont trois donnent un
/// écran noir sans message.
fn desktop_command(arguments: Vec<String>) -> ! {
    let mut image: Option<String> = None;
    let mut name: Option<String> = None;
    let mut memory_mib: u32 = 4096;
    let mut cpus: u32 = 4;
    let mut disk_gib: u32 = 64;
    let mut video = domain::Video::Virtio;
    let mut listen = "0.0.0.0".to_string();
    let mut virsh = "/usr/bin/virsh".to_string();
    let mut folder: Option<String> = None;
    let mut show_only = false;

    let mut rest = arguments.into_iter();
    while let Some(argument) = rest.next() {
        match argument.as_str() {
            "--image" => image = rest.next(),
            "--nom" => name = rest.next(),
            "--memoire" => match rest.next().and_then(|v| v.parse().ok()) {
                Some(value) => memory_mib = value,
                None => fail("--memoire attend un nombre de mébioctets"),
            },
            "--processeurs" => match rest.next().and_then(|v| v.parse().ok()) {
                Some(value) => cpus = value,
                None => fail("--processeurs attend un nombre"),
            },
            "--disque" => match rest.next().and_then(|v| v.parse().ok()) {
                Some(value) => disk_gib = value,
                None => fail("--disque attend un nombre de gibioctets"),
            },
            "--video" => match rest.next().as_deref().and_then(domain::Video::parse) {
                Some(value) => video = value,
                None => fail("--video attend virtio ou qxl"),
            },
            "--ecoute" => {
                if let Some(value) = rest.next() {
                    listen = value;
                }
            }
            "--virsh" => {
                if let Some(value) = rest.next() {
                    virsh = value;
                }
            }
            "--dossier" => folder = rest.next(),
            "--montrer" => show_only = true,
            "--help" | "-h" => {
                println!(
                    "wisq-agent bureau --image CHEMIN [--nom N] [--memoire MiB] [--processeurs N]\n\
                     \x20                  [--disque GiB] [--video virtio|qxl] [--ecoute ADRESSE]\n\
                     \x20                  [--dossier DIR] [--virsh CHEMIN] [--montrer]\n\n\
                     Construit une machine autour d'une image d'installation et la démarre :\n\
                     un disque qcow2, l'image amorcée en premier, un bureau SPICE avec mot de\n\
                     passe, la tablette, le son et le canal de l'agent invité. Affiche ensuite\n\
                     ce qu'il faut taper dans wisq.\n\n\
                     --montrer écrit le domaine sur la sortie standard sans rien créer.\n\
                     --video virtio pour un bureau Wayland (Hyprland, GNOME, KDE), qxl pour X11.\n\
                     --ecoute 0.0.0.0 rend le bureau visible depuis le téléphone ; le mot de\n\
                     passe engendré est ce qui le garde."
                );
                std::process::exit(0);
            }
            other => fail(&format!("argument inconnu : {other}")),
        }
    }

    let Some(image) = image else {
        fail("wisq-agent bureau --image CHEMIN (--help pour le reste)")
    };
    if let Err(message) = domain::check_image(&image) {
        fail(&message);
    }
    // Le nom vient du fichier quand personne n'en donne : « omarchy-4.0.2.iso »
    // devient « omarchy-4.0.2 », ce qui est ce que quelqu'un aurait tapé.
    let name = name.unwrap_or_else(|| {
        let stem = std::path::Path::new(&image)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "bureau".to_string());
        stem.chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                    c
                } else {
                    '-'
                }
            })
            .collect()
    });
    if !service::is_plausible_domain_name(&name) {
        fail(&format!(
            "nom de machine refusé : {name} — lettres, chiffres, point, tiret et souligné"
        ));
    }

    let folder = folder.unwrap_or_else(|| match std::env::var_os("HOME") {
        Some(home) => std::path::Path::new(&home)
            .join("wisq-disques")
            .to_string_lossy()
            .to_string(),
        None => "wisq-disques".to_string(),
    });
    let disk = std::path::Path::new(&folder).join(format!("{name}.qcow2"));
    let disk_path = disk.to_string_lossy().to_string();

    let password = domain::generate_password().unwrap_or_else(|error| fail(&error));
    let accelerator = if show_only {
        // Rien n'est sondé en mode « montrer » : la commande doit pouvoir
        // écrire un domaine sur une machine qui n'a pas libvirt du tout.
        domain::Accelerator::Kvm
    } else {
        capabilities(&virsh)
    };

    let desktop = domain::Desktop {
        name: name.clone(),
        image: image.clone(),
        disk: disk_path.clone(),
        memory_mib,
        cpus,
        video,
        listen: listen.clone(),
        password: password.clone(),
        accelerator,
    };

    if show_only {
        print!("{}", desktop.xml());
        std::process::exit(0);
    }

    if let Some(warning) = accelerator.warning() {
        emit(&format!("attention : {warning}"));
    }

    // Le disque, s'il n'existe pas déjà : réutiliser celui d'une installation
    // précédente est ce qu'on veut quand on redéfinit une machine, et l'écraser
    // effacerait un système installé sans le dire.
    if disk.exists() {
        emit(&format!("disque existant réutilisé : {disk_path}"));
    } else {
        if let Err(error) = std::fs::create_dir_all(&folder) {
            fail(&format!("dossier des disques ({folder}) : {error}"));
        }
        let created = std::process::Command::new("qemu-img")
            .args(["create", "-f", "qcow2", &disk_path, &format!("{disk_gib}G")])
            .output();
        match created {
            Ok(output) if output.status.success() => emit(&format!(
                "disque créé : {disk_path} ({disk_gib} Gio, épars)"
            )),
            Ok(output) => fail(&format!(
                "qemu-img a refusé : {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )),
            Err(error) => fail(&format!("qemu-img introuvable : {error}")),
        }
    }

    // Le domaine passe par un fichier plutôt que par l'entrée standard : c'est
    // ce que `virsh define` prend, et le fichier reste là pour être relu.
    let xml_path = std::path::Path::new(&folder).join(format!("{name}.xml"));
    if let Err(error) = std::fs::write(&xml_path, desktop.xml()) {
        fail(&format!("écriture du domaine : {error}"));
    }
    run_virsh(&virsh, &["define", &xml_path.to_string_lossy()]);
    run_virsh(&virsh, &["start", &name]);

    emit("");
    emit(&format!("La machine « {name} » tourne."));
    emit("");
    emit("Dans wisq, ajoutez une machine :");
    emit(&format!(
        "  hôte      {}",
        host_name()
            .map(|n| format!("{n}.local"))
            .unwrap_or_else(|| "l'adresse de cet ordinateur".to_string())
    ));
    emit("  protocole SPICE");
    emit("  port      celui que l'agent annonce pour cette machine");
    emit(&format!("  mot de passe  {password}"));
    emit("");
    emit("Le mot de passe n'est écrit nulle part ailleurs : notez-le maintenant.");
    std::process::exit(0)
}

/// Ce que l'hôte sait accélérer, demandé à libvirt plutôt que deviné.
fn capabilities(virsh: &str) -> domain::Accelerator {
    match std::process::Command::new(virsh)
        .arg("capabilities")
        .output()
    {
        Ok(output) if output.status.success() => {
            domain::Accelerator::from_capabilities(&String::from_utf8_lossy(&output.stdout))
        }
        _ => domain::Accelerator::None,
    }
}

fn run_virsh(virsh: &str, arguments: &[&str]) {
    match std::process::Command::new(virsh).args(arguments).output() {
        Ok(output) if output.status.success() => {
            let line = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !line.is_empty() {
                emit(&line);
            }
        }
        Ok(output) => fail(&format!(
            "virsh {} a échoué : {}",
            arguments.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )),
        Err(error) => fail(&format!("virsh introuvable ({virsh}) : {error}")),
    }
}

fn emit(line: &str) {
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(2)
}

fn host_name() -> Option<String> {
    if let Ok(name) = std::env::var("HOSTNAME") {
        if !name.is_empty() {
            return Some(name);
        }
    }
    let output = std::process::Command::new("hostname").output().ok()?;
    let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // macOS reports "nas.local"; the pairing URL wants the label, and the app
    // appends .local itself.
    let name = name.strip_suffix(".local").unwrap_or(&name).to_string();
    (!name.is_empty()).then_some(name)
}

/// Where the token and the TLS identity live. Falls back to the working
/// directory only when HOME is absent, which on the systems this runs on
/// means "being debugged".
fn state_directory() -> std::path::PathBuf {
    match std::env::var_os("HOME") {
        Some(home) => std::path::Path::new(&home).join(".wisq-agent"),
        None => std::path::PathBuf::from(".wisq-agent"),
    }
}

/// Explicit beats stored beats generated. The generated token persists so the
/// pairing survives daemon restarts.
fn resolve_stored_token() -> String {
    let directory = state_directory();
    let file = directory.join("token");

    if let Ok(stored) = std::fs::read_to_string(&file) {
        let stored = stored.trim();
        if !stored.is_empty() {
            return stored.to_string();
        }
    }

    let generated = generate_token();
    let _ = std::fs::create_dir_all(&directory);
    set_owner_only_directory(&directory);
    // The mode goes in the `open`, not in a `set_permissions` afterwards. The
    // afterwards version — which this was — creates the file at the default
    // mode first, 0644 under the usual umask, and narrows it on the next
    // syscall. Measured: 644, then 600. A bearer token that controls every VM
    // on the machine spent that window readable by any local account.
    let _ = write_owner_only(&file, generated.as_bytes());
    generated
}

/// Creates a file already narrowed to its owner, or replaces one that exists.
///
/// `create_new` rather than `create` so an existing file's mode is never
/// inherited; the explicit `remove_file` first is what makes replacing a
/// leftover from a half-finished run possible without that inheritance.
#[cfg(unix)]
fn write_owner_only(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let _ = std::fs::remove_file(path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)
}

#[cfg(not(unix))]
fn write_owner_only(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

/// The directory is narrowed too, as a second line: the token inside is 0600 on
/// its own, and this stops a future writer who forgets from leaving something
/// world-readable beside it. `create_dir_all` takes no mode, so this is
/// necessarily a second syscall — harmless, because nothing sensitive is inside
/// the directory yet when it runs.
#[cfg(unix)]
fn set_owner_only_directory(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
fn set_owner_only_directory(_path: &std::path::Path) {}

/// 32 characters from the OS random source.
///
/// This is a bearer credential; a seeded PRNG would make it guessable from the
/// daemon's start time. `/dev/urandom` exists on both platforms this runs on,
/// and if it cannot be read the daemon refuses rather than inventing a secret
/// it cannot vouch for.
fn generate_token() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    // Exactly 32 bytes, never `fs::read`: reading a random device to EOF waits
    // for an end that never comes, growing a Vec until allocation fails. That
    // was this function's first branch for two releases, masked because every
    // test passes --token; the first person to run the daemon bare would have
    // watched it eat memory instead of printing a pairing link.
    use std::io::Read;
    let mut buffer = [0u8; 32];
    let read =
        std::fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut buffer));
    if read.is_err() {
        fail("impossible de lire /dev/urandom : refus de générer un jeton faible");
    }
    buffer
        .iter()
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The token is a bearer credential that controls every VM on the machine,
    /// so it gets the same guarantee as the private key: it is never readable by
    /// anyone else, not even between two syscalls.
    ///
    /// The same watching thread as `tls::tests`, for the same reason — an
    /// assertion on the final mode passes whether the file was created narrow or
    /// created wide and narrowed afterwards, so it cannot see the window it is
    /// supposed to be guarding. Against the old shape this counted hundreds of
    /// wide observations in a hundred rounds.
    #[test]
    #[cfg(unix)]
    fn the_token_is_never_world_readable_even_for_an_instant() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
        use std::sync::Arc;

        let directory =
            std::env::temp_dir().join(format!("wisq-token-race-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("répertoire");
        let path = directory.join("token");

        let seen_wide = Arc::new(AtomicU32::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (counter, halt, watched) = (Arc::clone(&seen_wide), Arc::clone(&stop), path.clone());
        let watcher = std::thread::spawn(move || {
            while !halt.load(Ordering::Relaxed) {
                if let Ok(metadata) = std::fs::metadata(&watched) {
                    if metadata.permissions().mode() & 0o777 != 0o600 {
                        counter.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        });

        for _ in 0..100 {
            let _ = std::fs::remove_file(&path);
            write_owner_only(&path, b"un-jeton-de-test").expect("écriture");
        }
        stop.store(true, Ordering::Relaxed);
        watcher.join().expect("observateur");

        assert_eq!(
            seen_wide.load(Ordering::Relaxed),
            0,
            "le jeton a existé avec un mode autre que 0600"
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// And the content still arrives — the control case, so the test above
    /// cannot be satisfied by a writer that never writes anything.
    #[test]
    fn the_token_file_actually_holds_the_token() {
        let directory =
            std::env::temp_dir().join(format!("wisq-token-write-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("répertoire");
        let path = directory.join("token");

        write_owner_only(&path, b"abc123").expect("écriture");
        assert_eq!(std::fs::read_to_string(&path).expect("relecture"), "abc123");

        // And replacing one that exists, which is the half-finished-run case.
        write_owner_only(&path, b"def456").expect("réécriture");
        assert_eq!(std::fs::read_to_string(&path).expect("relecture"), "def456");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
