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

fn write_owner_only(path: &Path, bytes: &[u8]) -> Result<(), String> {
    std::fs::write(path, bytes).map_err(|e| format!("écriture de {} : {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
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
}
