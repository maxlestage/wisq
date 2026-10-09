# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
["Report a vulnerability"](../../security/advisories/new) form rather than a
public issue. You should receive an initial response within a week.

## Scope worth knowing about

- The **agent speaks TLS by default** since 0.3.0, behind a mandatory bearer
  token: a self-signed certificate whose SHA-256 fingerprint travels in the
  pairing link and is pinned by the app. `--no-tls` turns it off for a tunnel
  that already encrypts (WireGuard, Tailscale), and is documented as such.
  Reports about pinning bypass, token handling, auth bypass, or parser abuse
  of the HTTP server are very much in scope.
- The **VNC DES authentication** is weak by protocol design (RFC 6143);
  wisq warns users about plaintext transport in the editor. In scope:
  anything that leaks the password further than the protocol already does.
- The **local machines** — the rv32ima interpreter and the x86-64 core —
  execute untrusted guest code by design. In scope: any way for a guest to
  corrupt emulator memory outside its RAM allocation, or to escape the
  machine abstraction.
