//! Routing for the protocol in docs/AGENT-PROTOCOL.md.

use crate::backend::Backend;
use crate::http::{Request, Response};
use crate::vm::{json_bool, list_to_json};

pub struct Service {
    backend: Box<dyn Backend>,
    token: String,
}

impl Service {
    pub fn new(backend: Box<dyn Backend>, token: String) -> Self {
        Service { backend, token }
    }

    pub fn handle(&self, request: Request) -> Response {
        if !self.authorized(&request) {
            return Response::error(401, "jeton manquant ou invalide");
        }

        // Routes are /v1/vms[/{id}[/start|/stop]].
        let path = request.path.split('?').next().unwrap_or("");
        let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
        if parts.first() != Some(&"v1") || parts.len() < 2 || parts[1] != "vms" {
            return Response::error(404, &format!("route inconnue : {}", request.path));
        }

        // Every route below the collection carries an identifier, and it comes
        // from the address bar of whoever is talking to us. Checked once, here,
        // before any of them can hand it to a subprocess.
        if parts.len() >= 3 && !is_plausible_domain_name(parts[2]) {
            return Response::error(404, "identifiant de VM invalide");
        }

        match (request.method.as_str(), parts.len()) {
            ("GET", 2) => match self.backend.list() {
                Ok(vms) => Response::json(200, list_to_json(&vms)),
                Err(message) => Response::error(500, &message),
            },

            ("GET", 3) => match self.backend.get(parts[2]) {
                Ok(Some(vm)) => Response::json(200, vm.to_json()),
                Ok(None) => Response::error(404, &format!("VM introuvable : {}", parts[2])),
                Err(message) => Response::error(500, &message),
            },

            ("POST", 4) if parts[3] == "start" => match self.backend.start(parts[2]) {
                Ok(vm) => Response::json(200, vm.to_json()),
                Err(message) => Response::error(404, &message),
            },

            ("POST", 4) if parts[3] == "stop" => {
                let force = json_bool(&request.body, "force").unwrap_or(false);
                match self.backend.stop(parts[2], force) {
                    Ok(vm) => Response::json(200, vm.to_json()),
                    Err(message) => Response::error(404, &message),
                }
            }

            ("GET", _) | ("POST", _) => {
                Response::error(404, &format!("route inconnue : {}", request.path))
            }
            _ => Response::error(405, &format!("méthode non gérée : {}", request.method)),
        }
    }

    fn authorized(&self, request: &Request) -> bool {
        let Some(header) = request.authorization.as_deref() else {
            return false;
        };
        let Some(presented) = header.strip_prefix("Bearer ") else {
            return false;
        };
        constant_time_eq(presented.trim().as_bytes(), self.token.as_bytes())
    }
}

/// Compares in time that does not depend on how much of the token matched.
///
/// The token is a bearer credential on a network the daemon does not control.
/// A byte-at-a-time comparison leaks its prefix to anyone patient enough to
/// measure, and the fix costs nothing.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut difference = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        difference |= x ^ y;
    }
    difference == 0
}

/// What a libvirt domain name is allowed to look like, as far as this daemon is
/// concerned.
///
/// **The leading dash is the whole point.** `VirshBackend` runs
/// `Command::new(virsh).args(["start", id])` — argv, never a shell, so an
/// identifier containing `; rm -rf /` is one harmless argument that virsh will
/// fail to find. Verified with a probe rather than assumed. But an argument
/// *beginning with a dash* is not data to an option parser, it is an option:
/// `virsh start --version` is not a request to start a domain called
/// `--version`.
///
/// So this is argument injection rather than command injection, and it needs the
/// bearer token, which makes it an escalation inside an authenticated session —
/// from "drive this host's VMs" to "run virsh with flags of your choosing" —
/// rather than a way in. Narrow, and cheap enough to close that arguing about
/// the severity would cost more than the fix.
///
/// Deliberately an allowlist. A denylist of "characters virsh dislikes" is a
/// guess about another program's parser that ages badly; a domain name is
/// letters, digits, dot, dash and underscore, and anything else can be refused
/// without losing a name anyone would really use. libvirt itself is stricter
/// still, but matching it exactly would mean tracking its rules forever.
///
/// `.` and `..` are refused although every character in them is allowed. They
/// are path segments, not names: a client that puts `..` in
/// `/v1/vms/{id}/start` is not asking about a domain, and no libvirt domain is
/// called that. Found by making the phone run this same list of cases — both
/// sides accepted them, and neither should.
fn is_plausible_domain_name(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 255
        && !id.starts_with('-')
        && id != "."
        && id != ".."
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::DemoBackend;
    use std::time::Duration;

    fn service() -> Service {
        Service::new(
            Box::new(DemoBackend::new(Duration::from_millis(5))),
            "secret-token".to_string(),
        )
    }

    fn request(method: &str, path: &str, token: Option<&str>, body: &str) -> Request {
        Request {
            method: method.to_string(),
            path: path.to_string(),
            authorization: token.map(|t| format!("Bearer {t}")),
            body: body.to_string(),
        }
    }

    /// The same list of cases as `VMIdentifierTests` on the phone side.
    ///
    /// Written twice on purpose. This rule lived here alone: the protocol
    /// document did not state it and the client did not know it, so the app
    /// would happily save a machine this daemon refuses. Now both sides keep
    /// it, and two implementations keeping one rule separately is exactly how
    /// a rule drifts — unless the fixtures are the same on both sides.
    #[test]
    fn the_two_sides_agree_on_what_an_identifier_may_be() {
        let refused = [
            "",
            "-domaine",
            "--version",
            "mon domaine",
            "mon/domaine",
            "../../admin",
            "..",
            ".",
            "domaine;rm",
            "domaine\0",
            "café",
            "domaine?x=1",
            "domaine#f",
            "domaine@hôte",
        ];
        for id in refused {
            assert!(
                !is_plausible_domain_name(id),
                "{id:?} aurait dû être refusé"
            );
        }

        let accepted = [
            "debian",
            "debian-12",
            "debian_12",
            "debian.12",
            "DEBIAN",
            "vm0",
            "0",
            "a.b-c_d.9",
        ];
        for id in accepted {
            assert!(
                is_plausible_domain_name(id),
                "{id:?} aurait dû être accepté"
            );
        }

        // Les deux bords de la limite, comptés en octets.
        assert!(is_plausible_domain_name(&"a".repeat(255)));
        assert!(!is_plausible_domain_name(&"a".repeat(256)));
    }

    /// An identifier that begins with a dash is not a domain name to an option
    /// parser, it is an option. `VirshBackend` builds argv rather than a shell
    /// line, so nothing here is command injection — probed and confirmed: an id
    /// of `; rm -rf /` arrives as one argument virsh cannot find. What it *is*
    /// is argument injection, and it stops at the routing boundary now.
    #[test]
    fn an_identifier_that_looks_like_an_option_is_refused() {
        for id in ["-c", "--version", "--connect=x", "-", "--"] {
            for path in [
                format!("/v1/vms/{id}"),
                format!("/v1/vms/{id}/start"),
                format!("/v1/vms/{id}/stop"),
            ] {
                let response = service().handle(request(
                    if path.ends_with("start") || path.ends_with("stop") {
                        "POST"
                    } else {
                        "GET"
                    },
                    &path,
                    Some("secret-token"),
                    "",
                ));
                assert_eq!(response.status, 404, "{path} a été accepté");
                assert!(
                    response.body.contains("invalide"),
                    "{path} : {}",
                    response.body
                );
            }
        }
    }

    /// Everything else a hostile caller might try, refused by the same rule.
    ///
    /// **The message is the assertion, not the status.** Both answers here are
    /// 404: one from the validation, one from a backend that looked for the name
    /// and did not find it. A test asserting only the status passes whichever
    /// happened, which is exactly what it did — dropping the character allowlist
    /// left the whole suite green until this checked the wording instead.
    #[test]
    fn an_identifier_outside_the_allowed_shape_is_refused() {
        for id in [
            "a b", // a space would split nothing, but it is not a name
            "a$b", "a;b", "a\nb", "é",       // outside ASCII
            "a\u{0}b", // a NUL, which no argv can carry anyway
        ] {
            let response = service().handle(request(
                "GET",
                &format!("/v1/vms/{id}"),
                Some("secret-token"),
                "",
            ));
            assert_eq!(response.status, 404, "{id:?} a été accepté");
            assert!(
                response.body.contains("invalide"),
                "{id:?} a atteint le backend au lieu d'être refusé : {}",
                response.body
            );
        }
    }

    /// The other direction, and the one that matters for not breaking anybody:
    /// the names people really give their domains still work. A validator that
    /// refuses `debian-12.local` is worse than the hole it closes.
    #[test]
    fn ordinary_domain_names_still_reach_the_backend() {
        for id in [
            "debian12",
            "debian-12",
            "debian_12",
            "debian-12.local",
            "VM1",
            "a",
            "0",
            "win11-dev.example.com",
        ] {
            let response = service().handle(request(
                "GET",
                &format!("/v1/vms/{id}"),
                Some("secret-token"),
                "",
            ));
            // 404 "VM introuvable" is the honest answer from the demo backend;
            // what must not happen is the *validation* refusing the name, so the
            // message is what distinguishes the two.
            assert!(
                !response.body.contains("invalide"),
                "{id} a été refusé par la validation : {}",
                response.body
            );
        }
    }

    #[test]
    fn lists_vms_for_a_valid_token() {
        let response = service().handle(request("GET", "/v1/vms", Some("secret-token"), ""));
        assert_eq!(response.status, 200);
        assert!(response.body.contains("debian-13"));
        assert!(response.body.contains("win11"));
    }

    #[test]
    fn rejects_a_missing_or_wrong_token() {
        assert_eq!(
            service().handle(request("GET", "/v1/vms", None, "")).status,
            401
        );
        assert_eq!(
            service()
                .handle(request("GET", "/v1/vms", Some("nope"), ""))
                .status,
            401
        );
        // A correct prefix is still wrong.
        assert_eq!(
            service()
                .handle(request("GET", "/v1/vms", Some("secret"), ""))
                .status,
            401
        );
    }

    #[test]
    fn an_unknown_route_says_so_in_json() {
        let response = service().handle(request("GET", "/v1/nope", Some("secret-token"), ""));
        assert_eq!(response.status, 404);
        assert!(response.body.starts_with("{\"error\""));
    }

    #[test]
    fn a_query_string_does_not_change_the_route() {
        let response = service().handle(request("GET", "/v1/vms?x=1", Some("secret-token"), ""));
        assert_eq!(response.status, 200);
    }

    #[test]
    fn starting_reports_starting_then_running() {
        let service = service();
        let response = service.handle(request(
            "POST",
            "/v1/vms/debian-13/start",
            Some("secret-token"),
            "",
        ));
        assert_eq!(response.status, 200);
        assert!(response.body.contains("\"state\":\"starting\""));

        std::thread::sleep(Duration::from_millis(20));
        let response = service.handle(request(
            "GET",
            "/v1/vms/debian-13",
            Some("secret-token"),
            "",
        ));
        assert!(response.body.contains("\"state\":\"running\""));
        assert!(response.body.contains("\"consolePort\":5901"));
    }

    #[test]
    fn stopping_reads_the_force_flag_and_survives_an_empty_body() {
        let service = service();
        assert_eq!(
            service
                .handle(request(
                    "POST",
                    "/v1/vms/win11/stop",
                    Some("secret-token"),
                    ""
                ))
                .status,
            200
        );
        assert_eq!(
            service
                .handle(request(
                    "POST",
                    "/v1/vms/win11/stop",
                    Some("secret-token"),
                    r#"{"force":true}"#
                ))
                .status,
            200
        );
    }

    #[test]
    fn an_unknown_vm_is_a_404_with_a_readable_message() {
        let response = service().handle(request(
            "POST",
            "/v1/vms/ghost/start",
            Some("secret-token"),
            "",
        ));
        assert_eq!(response.status, 404);
        assert!(response.body.contains("ghost"));
    }
}
