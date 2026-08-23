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
