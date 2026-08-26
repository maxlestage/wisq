//! A minimal HTTP/1.1 server on the standard library.
//!
//! Four routes behind a bearer token on a local network does not need an async
//! runtime and a framework; it needs a listener, a thread per connection, and a
//! careful request reader. What follows is deliberately strict — a daemon that
//! accepts sloppy requests is a daemon whose behaviour nobody can predict.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

/// What sits between the socket and the protocol. The request reader below is
/// written against `Read + Write`, so TLS is a wrapper here and not a second
/// server.
pub enum Transport {
    Plain,
    Tls(Arc<rustls::ServerConfig>),
}

/// Caps, so a hostile or broken client cannot make the daemon allocate.
const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 64 * 1024;

pub struct Request {
    pub method: String,
    pub path: String,
    pub authorization: Option<String>,
    pub body: String,
}

pub struct Response {
    pub status: u16,
    pub body: String,
}

impl Response {
    pub fn json(status: u16, body: String) -> Self {
        Response { status, body }
    }

    pub fn error(status: u16, message: &str) -> Self {
        Response {
            status,
            body: format!("{{\"error\":\"{}\"}}", crate::vm::escape(message)),
        }
    }

    fn reason(&self) -> &'static str {
        match self.status {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            405 => "Method Not Allowed",
            413 => "Payload Too Large",
            426 => "Upgrade Required",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            _ => "OK",
        }
    }
}

pub struct Server {
    listener: TcpListener,
    stop: Arc<AtomicBool>,
}

impl Server {
    /// Binds to `port`; pass 0 for an ephemeral one and read `port()` back.
    pub fn bind(port: u16) -> std::io::Result<Self> {
        let listener = TcpListener::bind(("0.0.0.0", port))?;
        Ok(Server {
            listener,
            stop: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn port(&self) -> u16 {
        self.listener.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Serves until the process ends. One thread per connection: the client is
    /// a phone making a handful of short requests, so a thread pool would be
    /// machinery guarding against a load that does not exist. The TLS
    /// handshake happens on the connection's own thread for the same reason a
    /// slow request must not block accept.
    pub fn serve<H>(&self, transport: Transport, handler: H) -> !
    where
        H: Fn(Request) -> Response + Send + Sync + 'static,
    {
        let handler = Arc::new(handler);
        let transport = Arc::new(transport);
        for stream in self.listener.incoming() {
            let Ok(stream) = stream else { continue };
            if self.stop.load(Ordering::Acquire) {
                break;
            }
            let handler = Arc::clone(&handler);
            let transport = Arc::clone(&transport);
            thread::spawn(move || {
                let _ = handle_connection(stream, &transport, handler.as_ref());
            });
        }
        std::process::exit(0)
    }
}

fn handle_connection<H>(
    mut stream: TcpStream,
    transport: &Transport,
    handler: &H,
) -> std::io::Result<()>
where
    H: Fn(Request) -> Response,
{
    stream.set_nodelay(true).ok();
    // A connection thread must be reclaimable: without deadlines, a client
    // that connects and never speaks — or a half-open TLS handshake — parks a
    // thread forever.
    let deadline = Some(std::time::Duration::from_secs(20));
    stream.set_read_timeout(deadline).ok();
    stream.set_write_timeout(deadline).ok();
    match transport {
        Transport::Plain => {
            let result = exchange(&mut stream, handler);
            stream.shutdown(Shutdown::Both).ok();
            result?;
        }
        Transport::Tls(config) => {
            // A plain-HTTP client — an app from before 0.3, or someone's curl
            // without https:// — deserves an answer, not a stall: rustls reads
            // "GET /" as a TLS record header announcing kilobytes that never
            // come, and sits on the socket until its deadline. One peeked byte
            // settles it, because every TLS connection opens with a handshake
            // record (0x16) and no HTTP method starts with one.
            let mut first = [0u8; 1];
            if !matches!(stream.peek(&mut first), Ok(1)) || first[0] != 0x16 {
                let response = Response::error(
                    426,
                    "cet agent parle TLS : utilisez https, ré-appairez, ou relancez-le avec --no-tls",
                );
                let body = response.body.as_bytes();
                let head = format!(
                    "HTTP/1.1 426 Upgrade Required\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(head.as_bytes()).ok();
                stream.write_all(body).ok();
                stream.flush().ok();
                stream.shutdown(Shutdown::Both).ok();
                return Ok(());
            }
            let connection = rustls::ServerConnection::new(Arc::clone(config))
                .map_err(|e| std::io::Error::other(e.to_string()))?;
            let mut tls = rustls::StreamOwned::new(connection, stream);
            let result = exchange(&mut tls, handler);
            tls.conn.send_close_notify();
            let _ = tls.flush();
            tls.sock.shutdown(Shutdown::Both).ok();
            result?;
        }
    }
    Ok(())
}

/// Why a request could not be read. The distinction decides whether answering
/// is possible at all: a malformed request on a healthy stream deserves a 400,
/// but a dead transport — socket gone, TLS handshake failed — must be closed
/// without a reply. Writing an HTTP response into a failed TLS handshake makes
/// rustls try to continue that handshake, which blocks on a client that is
/// itself blocked reading: a deadlock, one leaked thread per hostile or merely
/// outdated client.
enum ReadFailure {
    Protocol(Response),
    Transport,
}

/// One request, one response, then close — over whatever the transport gives.
fn exchange<S, H>(stream: &mut S, handler: &H) -> std::io::Result<()>
where
    S: Read + Write,
    H: Fn(Request) -> Response,
{
    let response = match read_request(stream) {
        Ok(request) => handler(request),
        Err(ReadFailure::Protocol(response)) => response,
        Err(ReadFailure::Transport) => return Ok(()),
    };

    let body = response.body.as_bytes();
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        response.reason(),
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()?;
    Ok(())
}

fn read_request<S: Read>(stream: &mut S) -> Result<Request, ReadFailure> {
    let mut reader = BufReader::new(stream);

    let mut request_line = String::new();
    read_line(&mut reader, &mut request_line)?;
    let mut parts = request_line.trim_end().split(' ');
    let (Some(method), Some(path)) = (parts.next(), parts.next()) else {
        return Err(ReadFailure::Protocol(Response::error(
            400,
            "requête malformée",
        )));
    };
    let (method, path) = (method.to_string(), path.to_string());

    let mut authorization = None;
    // `None` until a `Content-Length` is seen, so a second one is detectable.
    // Two of them with different values is the request-smuggling primitive, and
    // "the last one wins" is how a parser becomes the half of a pair that
    // disagrees.
    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    let mut header_bytes = request_line.len();

    loop {
        let mut line = String::new();
        read_line(&mut reader, &mut line)?;
        header_bytes += line.len();
        if header_bytes > MAX_HEADER_BYTES {
            return Err(ReadFailure::Protocol(Response::error(
                413,
                "en-têtes trop volumineux",
            )));
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        // Header names are case-insensitive, and clients disagree about case.
        match name.to_ascii_lowercase().as_str() {
            "authorization" => authorization = Some(value.to_string()),
            "content-length" => {
                // RFC 9112 §6.3: a Content-Length is 1*DIGIT and nothing else.
                // `usize::from_str` is more generous — it accepts a leading `+`,
                // so `Content-Length: +5` parsed happily before this check.
                if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(ReadFailure::Protocol(Response::error(
                        400,
                        "Content-Length invalide",
                    )));
                }
                let declared: usize = value.parse().map_err(|_| {
                    ReadFailure::Protocol(Response::error(400, "Content-Length invalide"))
                })?;
                // Two of them are only tolerable when they agree; RFC 9112 §6.3
                // says to reject otherwise, and this daemon rejects either way
                // because a repeated header is already a client doing something
                // it cannot explain.
                if content_length.is_some() {
                    return Err(ReadFailure::Protocol(Response::error(
                        400,
                        "Content-Length répété",
                    )));
                }
                if declared > MAX_BODY_BYTES {
                    return Err(ReadFailure::Protocol(Response::error(
                        413,
                        "corps trop volumineux",
                    )));
                }
                content_length = Some(declared);
            }
            // This daemon frames bodies by length and nothing else. Chunked
            // requests used to arrive, have their body silently dropped, and be
            // acted on as though the client had sent none — the worst available
            // answer, because the client is told 200 for something it did not
            // ask. RFC 9112 §6.1 gives the right one: 501 for a transfer coding
            // that is not implemented.
            "transfer-encoding" => chunked = true,
            _ => {}
        }
    }

    if chunked {
        return Err(ReadFailure::Protocol(Response::error(
            501,
            "Transfer-Encoding non pris en charge",
        )));
    }

    let content_length = content_length.unwrap_or(0);
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader
            .read_exact(&mut body)
            .map_err(|_| ReadFailure::Transport)?;
    }

    Ok(Request {
        method,
        path,
        authorization,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

fn read_line<R: BufRead>(reader: &mut R, out: &mut String) -> Result<(), ReadFailure> {
    let mut raw = Vec::new();
    let read = reader
        .take(MAX_HEADER_BYTES as u64)
        .read_until(b'\n', &mut raw)
        // A read that errors is a transport problem — a vanished socket or a
        // failed TLS handshake — and both are streams no answer can cross.
        .map_err(|_| ReadFailure::Transport)?;
    if read == 0 {
        return Err(ReadFailure::Transport);
    }
    *out = String::from_utf8_lossy(&raw).into_owned();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream;

    /// The client half of the pinning story, as the app implements it: trust
    /// exactly the certificate whose SHA-256 matches the pairing link, and
    /// nothing else — no CA, no names, no dates.
    #[derive(Debug)]
    struct PinnedVerifier {
        fingerprint: String,
    }

    impl rustls::client::danger::ServerCertVerifier for PinnedVerifier {
        fn verify_server_cert(
            &self,
            end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            if crate::tls::fingerprint_hex(end_entity) == self.fingerprint {
                Ok(rustls::client::danger::ServerCertVerified::assertion())
            } else {
                Err(rustls::Error::General("empreinte inattendue".into()))
            }
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            rustls::crypto::ring::default_provider()
                .signature_verification_algorithms
                .supported_schemes()
        }
    }

    fn tls_server() -> (u16, String) {
        let directory = std::env::temp_dir().join(format!(
            "wisq-http-tls-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        let identity = crate::tls::load_or_create(&directory).expect("identité");
        let fingerprint = identity.fingerprint.clone();
        let server = Server::bind(0).expect("bind");
        let port = server.port();
        let config = identity.config;
        thread::spawn(move || {
            server.serve(Transport::Tls(config), |request| {
                Response::json(200, format!("{{\"echo\":\"{}\"}}", request.path))
            });
        });
        let _ = std::fs::remove_dir_all(&directory);
        (port, fingerprint)
    }

    fn pinned_client(fingerprint: &str) -> Arc<rustls::ClientConfig> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("versions")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PinnedVerifier {
                fingerprint: fingerprint.to_string(),
            }))
            .with_no_client_auth();
        Arc::new(config)
    }

    fn request_over_tls(port: u16, config: Arc<rustls::ClientConfig>) -> std::io::Result<String> {
        let name = rustls::pki_types::ServerName::try_from("wisq-agent").expect("nom");
        let connection = rustls::ClientConnection::new(config, name)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        let socket = TcpStream::connect(("127.0.0.1", port))?;
        let mut stream = rustls::StreamOwned::new(connection, socket);
        stream.write_all(b"GET /v1/vms HTTP/1.1\r\nHost: x\r\n\r\n")?;
        let mut body = String::new();
        stream.read_to_string(&mut body)?;
        Ok(body)
    }

    #[test]
    fn a_client_pinning_the_right_fingerprint_gets_served() {
        let (port, fingerprint) = tls_server();
        let body = request_over_tls(port, pinned_client(&fingerprint)).expect("échange TLS");
        assert!(body.contains("\"echo\":\"/v1/vms\""), "{body}");
    }

    #[test]
    fn a_client_pinning_the_wrong_fingerprint_never_reaches_the_service() {
        let (port, _) = tls_server();
        let wrong = "00".repeat(32);
        let error = request_over_tls(port, pinned_client(&wrong))
            .expect_err("le mauvais certificat doit être refusé");
        assert!(error.to_string().contains("empreinte"), "{error}");
    }

    /// A plain client must learn what went wrong in milliseconds. The first
    /// version of this path stalled such clients for the whole socket
    /// deadline: rustls read "GET /" as a TLS record header and waited for
    /// kilobytes that were never coming.
    #[test]
    fn plain_http_against_the_tls_port_is_told_to_upgrade_quickly() {
        let (port, _) = tls_server();
        let started = std::time::Instant::now();
        let mut socket = TcpStream::connect(("127.0.0.1", port)).expect("connexion");
        socket
            .write_all(b"GET /v1/vms HTTP/1.1\r\nHost: x\r\n\r\n")
            .expect("écriture");
        let mut reply = Vec::new();
        let _ = socket.read_to_end(&mut reply);
        let reply = String::from_utf8_lossy(&reply);
        assert!(reply.starts_with("HTTP/1.1 426"), "{reply}");
        assert!(reply.contains("--no-tls"), "{reply}");
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "la réponse doit être immédiate, pas au bout du délai de socket"
        );
    }

    /// A plain server that reports back exactly what the parser handed it, so
    /// these tests can tell "the body was rejected" from "the body arrived
    /// empty" — a distinction the daemon used to lose.
    fn echoing_server() -> u16 {
        let server = Server::bind(0).expect("bind");
        let port = server.port();
        thread::spawn(move || {
            server.serve(Transport::Plain, |request| {
                Response::json(200, format!("{{\"len\":{}}}", request.body.len()))
            });
        });
        port
    }

    fn raw(port: u16, wire: &str) -> String {
        let mut socket = TcpStream::connect(("127.0.0.1", port)).expect("connexion");
        socket.write_all(wire.as_bytes()).expect("écriture");
        let mut reply = Vec::new();
        let _ = socket.read_to_end(&mut reply);
        String::from_utf8_lossy(&reply).into_owned()
    }

    /// The one that bit an honest client rather than an attacker: any HTTP
    /// library that decides to stream a body sends `Transfer-Encoding: chunked`,
    /// and this daemon answered 200 for a request whose body it had thrown away.
    #[test]
    fn a_chunked_request_is_refused_rather_than_silently_emptied() {
        let port = echoing_server();
        let reply = raw(
            port,
            "POST /v1/x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        );
        assert!(reply.starts_with("HTTP/1.1 501"), "{reply}");
        assert!(
            !reply.contains("\"len\":0"),
            "le corps a été avalé : {reply}"
        );
    }

    /// Two lengths that disagree is the request-smuggling primitive. This
    /// daemon closes every connection after one exchange, so it cannot be
    /// desynchronised on its own — but it is exactly the sort of daemon someone
    /// puts behind a reverse proxy on a NAS, and then the pair disagreeing is
    /// the whole attack.
    #[test]
    fn conflicting_content_lengths_are_refused() {
        let port = echoing_server();
        let reply = raw(
            port,
            "POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nContent-Length: 3\r\n\r\nhello",
        );
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
    }

    /// Even when they agree: a repeated framing header is a client doing
    /// something it cannot explain, and guessing on its behalf is how the two
    /// halves of a proxy pair end up guessing differently.
    #[test]
    fn a_repeated_content_length_is_refused_even_when_it_agrees() {
        let port = echoing_server();
        let reply = raw(
            port,
            "POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
        );
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
    }

    /// Both framings at once: the CL.TE desync. Length wins in one parser,
    /// chunked in the other, and the bytes after the first body become a second
    /// request that only one of them can see.
    #[test]
    fn a_request_framed_twice_is_refused() {
        let port = echoing_server();
        let reply = raw(
            port,
            "POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello",
        );
        assert!(reply.starts_with("HTTP/1.1 501"), "{reply}");
    }

    /// `usize::from_str` accepts a leading `+`; RFC 9112 says the value is
    /// 1*DIGIT. The two disagreeing is how a length means one thing here and
    /// another next door.
    #[test]
    fn a_content_length_that_is_not_digits_is_refused() {
        let port = echoing_server();
        for value in ["+5", "0x5", "", "five", "-1", "5.0", "5,5"] {
            let reply = raw(
                port,
                &format!("POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: {value}\r\n\r\nhello"),
            );
            assert!(
                reply.starts_with("HTTP/1.1 400"),
                "Content-Length: {value:?} accepté : {reply}"
            );
        }
    }

    /// The other side of that line, and it caught the first draft of the test
    /// above rather than the code: **surrounding whitespace is legal.** RFC 9112
    /// puts optional whitespace around every field value, so ` 5` and `5 ` are
    /// an ordinary five and refusing them would break conforming clients. The
    /// parser trims before it validates, which is the right order.
    #[test]
    fn whitespace_around_a_content_length_is_not_an_error() {
        let port = echoing_server();
        for value in [" 5", "5 ", "  5  "] {
            let reply = raw(
                port,
                &format!("POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length:{value}\r\n\r\nhello"),
            );
            assert!(
                reply.starts_with("HTTP/1.1 200"),
                "Content-Length:{value:?} refusé : {reply}"
            );
            assert!(reply.contains("\"len\":5"), "{reply}");
        }
    }

    /// The control case, and the reason the five above are not simply "refuse
    /// everything": an ordinary request still works, with its body intact.
    #[test]
    fn an_ordinary_request_still_carries_its_body() {
        let port = echoing_server();
        let reply = raw(
            port,
            "POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello",
        );
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        assert!(reply.contains("\"len\":5"), "{reply}");
    }

    /// And a request with no body at all, which is every GET the app makes.
    #[test]
    fn a_request_with_no_body_is_unaffected() {
        let port = echoing_server();
        let reply = raw(port, "GET /v1/vms HTTP/1.1\r\nHost: h\r\n\r\n");
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        assert!(reply.contains("\"len\":0"), "{reply}");
    }
}
