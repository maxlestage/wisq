//! The agent's TLS identity: one self-signed certificate, pinned by the link.
//!
//! The certificate story a NAS owner can live with is no story at all. Nobody
//! installing a daemon with a one-line curl will also operate a certificate
//! authority, so the agent signs its own certificate, keeps it forever, and
//! hands its SHA-256 fingerprint to the phone inside the pairing link — the
//! same channel that already carries the bearer token. The phone then trusts
//! exactly that certificate and nothing else: no CA, no chain, no name checks,
//! just "the machine I paired with is the machine I am talking to".
//!
//! Two consequences are deliberate. The certificate never rotates on its own,
//! because the fingerprint in every previously shared link must keep working;
//! deleting the two files in `~/.wisq-agent` is the rotation story, and it
//! invalidates old links on purpose. And it barely expires (year 9999),
//! because expiry is a CA-world safeguard — under pinning it could only strand
//! a phone against a perfectly healthy daemon.

use std::fmt::Write as _;
use std::path::Path;
use std::sync::Arc;

/// File names under the agent's state directory, next to `token`.
/// DER rather than PEM: the agent only ever reads them back itself, DER needs
/// no parser, and `openssl x509 -inform der` reads it fine when a person wants
/// to look inside.
const CERTIFICATE_FILE: &str = "tls-certificate.der";
const KEY_FILE: &str = "tls-key.der";

pub struct Identity {
    pub config: Arc<rustls::ServerConfig>,
    /// Lowercase hex SHA-256 of the certificate in DER form — what the pairing
    /// link carries and what the phone compares against the wire.
    pub fingerprint: String,
}

/// Loads the identity from `directory`, creating and persisting it on first
/// run. The fingerprint is stable across restarts, which is what makes links
/// long-lived.
pub fn load_or_create(directory: &Path) -> Result<Identity, String> {
    let certificate_path = directory.join(CERTIFICATE_FILE);
    let key_path = directory.join(KEY_FILE);

    let (certificate, key) = match (std::fs::read(&certificate_path), std::fs::read(&key_path)) {
        (Ok(certificate), Ok(key)) if !certificate.is_empty() && !key.is_empty() => {
            (certificate, key)
        }
        _ => {
            let (certificate, key) = generate()?;
            std::fs::create_dir_all(directory)
                .map_err(|e| format!("création de {} : {e}", directory.display()))?;
            owner_only_directory(directory);
            write_owner_only(&certificate_path, &certificate)?;
            write_owner_only(&key_path, &key)?;
            (certificate, key)
        }
    };

    let fingerprint = fingerprint_hex(&certificate);
    let config = server_config(certificate, key)?;
    Ok(Identity {
        config,
        fingerprint,
    })
}

/// A fresh ECDSA P-256 key and a certificate signed with it.
fn generate() -> Result<(Vec<u8>, Vec<u8>), String> {
    let mut params = rcgen::CertificateParams::new(vec!["wisq-agent".to_string()])
        .map_err(|e| format!("paramètres du certificat : {e}"))?;
    // Pinning makes expiry pure downside: the phone checks the fingerprint,
    // not the dates, but a strict TLS stack in some future client would
    // refuse an expired certificate against a daemon that is perfectly fine.
    params.not_before = rcgen::date_time_ymd(2026, 1, 1);
    params.not_after = rcgen::date_time_ymd(9999, 1, 1);
    let key = rcgen::KeyPair::generate().map_err(|e| format!("génération de la clé : {e}"))?;
    let certificate = params
        .self_signed(&key)
        .map_err(|e| format!("signature du certificat : {e}"))?;
    Ok((certificate.der().to_vec(), key.serialize_der()))
}

pub fn fingerprint_hex(certificate_der: &[u8]) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, certificate_der);
    let mut out = String::with_capacity(64);
    for byte in digest.as_ref() {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn server_config(
    certificate_der: Vec<u8>,
    key_der: Vec<u8>,
) -> Result<Arc<rustls::ServerConfig>, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("versions TLS : {e}"))?
        .with_no_client_auth()
        .with_single_cert(
            vec![rustls::pki_types::CertificateDer::from(certificate_der)],
            rustls::pki_types::PrivateKeyDer::try_from(key_der)
                .map_err(|e| format!("clé illisible : {e}"))?,
        )
        .map_err(|e| format!("certificat refusé : {e}"))?;
    Ok(Arc::new(config))
}

/// Narrows the directory holding the secrets to its owner.
///
/// `create_dir_all` cannot take a mode, so this is a second syscall and there is
/// no way to avoid one — but unlike the files, nothing sensitive exists inside
/// it yet at that point, so the window contains nothing to read. It is a second
/// line anyway: the files are 0600 on their own, and this stops a future writer
/// who forgets from leaving something world-readable beside them.
fn owner_only_directory(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// Writes a secret so that it is **never readable by anyone else, not even for
/// an instant**.
///
/// The obvious version — `fs::write` then `set_permissions(0o600)` — is what
/// this was, and it has a window. `fs::write` creates the file with the default
/// mode, which under the usual `umask 022` is **0644**; the narrowing happens on
/// the next syscall. Measured on this project's own container: 644, then 600.
/// The state directory is 0755, so it does not cover the gap either. Anyone
/// with a local account and a loop could read a private key or a bearer token
/// out of that window.
///
/// The mode therefore goes in the `open`, where the kernel applies it before
/// the file exists to anyone. `create_new` rather than `create`: an existing
/// file would keep its own mode, so silently writing into one would put the
/// secret back where it started.
#[cfg(unix)]
fn write_owner_only(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    // Replacing rather than refusing: `load_or_create` reaches here when it has
    // decided to write a fresh identity, and a leftover from a half-finished
    // previous run must not make the daemon unstartable.
    let _ = std::fs::remove_file(path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("création de {} : {e}", path.display()))?;
    file.write_all(bytes)
        .map_err(|e| format!("écriture de {} : {e}", path.display()))
}

#[cfg(not(unix))]
fn write_owner_only(path: &Path, bytes: &[u8]) -> Result<(), String> {
    std::fs::write(path, bytes).map_err(|e| format!("écriture de {} : {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_identity_survives_a_restart_with_the_same_fingerprint() {
        let directory = std::env::temp_dir().join(format!("wisq-tls-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);

        let first = load_or_create(&directory).expect("première création");
        let second = load_or_create(&directory).expect("relecture");
        assert_eq!(first.fingerprint, second.fingerprint);
        assert_eq!(first.fingerprint.len(), 64);

        // Rotation is deletion: a fresh directory means a fresh certificate.
        let _ = std::fs::remove_dir_all(&directory);
        let third = load_or_create(&directory).expect("recréation");
        assert_ne!(first.fingerprint, third.fingerprint);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn the_key_is_not_world_readable() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let directory =
                std::env::temp_dir().join(format!("wisq-tls-perm-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&directory);
            load_or_create(&directory).expect("création");
            let mode = std::fs::metadata(directory.join(KEY_FILE))
                .expect("métadonnées")
                .permissions()
                .mode();
            assert_eq!(mode & 0o077, 0, "la clé privée doit être 0600");
            let _ = std::fs::remove_dir_all(&directory);
        }
    }

    /// The test above is true and insufficient, and that gap is the whole point
    /// of this one.
    ///
    /// It reads the mode **after** the write finished. `fs::write` followed by
    /// `set_permissions(0o600)` ends at 0600 too, so that assertion passed for
    /// as long as the race existed and would pass again the moment someone
    /// reintroduced it. A guard that inspects only the final state cannot see a
    /// window in the middle.
    ///
    /// So this watches. A thread stats the file as fast as it can while the
    /// writer runs, and records every mode that is not 0600. Measured against
    /// the old shape before the fix: **747 such observations in 100 rounds** —
    /// the window is not narrow, it is roughly seven stats wide. Against the
    /// current one: zero, at 100, 1 000 and 10 000 rounds.
    ///
    /// It cannot fail spuriously: a file created with the mode already in the
    /// `open` is never anything but 0600, so a single observation to the
    /// contrary is a real regression rather than bad luck.
    #[test]
    #[cfg(unix)]
    fn a_secret_is_never_world_readable_even_for_an_instant() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
        use std::sync::Arc;

        let directory = std::env::temp_dir().join(format!("wisq-tls-race-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("répertoire");
        let path = directory.join("secret-de-test");

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
            write_owner_only(&path, b"un secret").expect("écriture");
        }
        stop.store(true, Ordering::Relaxed);
        watcher.join().expect("observateur");

        assert_eq!(
            seen_wide.load(Ordering::Relaxed),
            0,
            "le secret a existé avec un mode autre que 0600"
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// The directory is a second line rather than the first — the files inside
    /// are 0600 on their own — but it is what stops a future writer who forgets
    /// from leaving something readable beside them.
    #[test]
    #[cfg(unix)]
    fn the_state_directory_belongs_to_its_owner_alone() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!("wisq-tls-dir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        load_or_create(&directory).expect("création");
        let mode = std::fs::metadata(&directory)
            .expect("métadonnées")
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "le répertoire d'état doit être 0700");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
