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
            500 => "Internal Server Error",
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
    /// machinery guarding against a load that does not exist.
    pub fn serve<H>(&self, handler: H) -> !
    where
        H: Fn(Request) -> Response + Send + Sync + 'static,
    {
        let handler = Arc::new(handler);
        for stream in self.listener.incoming() {
            let Ok(stream) = stream else { continue };
            if self.stop.load(Ordering::Acquire) {
                break;
            }
            let handler = Arc::clone(&handler);
            thread::spawn(move || {
                let _ = handle_connection(stream, handler.as_ref());
            });
        }
        std::process::exit(0)
    }
}

fn handle_connection<H>(mut stream: TcpStream, handler: &H) -> std::io::Result<()>
where
    H: Fn(Request) -> Response,
{
    stream.set_nodelay(true).ok();
    let response = match read_request(&mut stream) {
        Ok(request) => handler(request),
        Err(response) => response,
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
    stream.shutdown(Shutdown::Both).ok();
    Ok(())
}

fn read_request(stream: &mut TcpStream) -> Result<Request, Response> {
    let mut reader = BufReader::new(stream);

    let mut request_line = String::new();
    read_line(&mut reader, &mut request_line)?;
    let mut parts = request_line.trim_end().split(' ');
    let (Some(method), Some(path)) = (parts.next(), parts.next()) else {
        return Err(Response::error(400, "requête malformée"));
    };
    let (method, path) = (method.to_string(), path.to_string());

    let mut authorization = None;
    let mut content_length = 0usize;
    let mut header_bytes = request_line.len();

    loop {
        let mut line = String::new();
        read_line(&mut reader, &mut line)?;
        header_bytes += line.len();
        if header_bytes > MAX_HEADER_BYTES {
            return Err(Response::error(413, "en-têtes trop volumineux"));
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
                content_length = value
                    .parse()
                    .map_err(|_| Response::error(400, "Content-Length invalide"))?;
                if content_length > MAX_BODY_BYTES {
                    return Err(Response::error(413, "corps trop volumineux"));
                }
            }
            _ => {}
        }
    }

    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader
            .read_exact(&mut body)
            .map_err(|_| Response::error(400, "corps incomplet"))?;
    }

    Ok(Request {
        method,
        path,
        authorization,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

fn read_line<R: BufRead>(reader: &mut R, out: &mut String) -> Result<(), Response> {
    let mut raw = Vec::new();
    let read = reader
        .take(MAX_HEADER_BYTES as u64)
        .read_until(b'\n', &mut raw)
        .map_err(|_| Response::error(400, "lecture impossible"))?;
    if read == 0 {
        return Err(Response::error(400, "connexion fermée"));
    }
    *out = String::from_utf8_lossy(&raw).into_owned();
    Ok(())
}
