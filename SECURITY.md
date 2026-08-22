# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
["Report a vulnerability"](../../security/advisories/new) form rather than a
public issue. You should receive an initial response within a week.

## Scope worth knowing about

- The **agent v1 speaks plain HTTP** behind a mandatory bearer token. This
  is documented and intentional: it is designed for trusted networks or an
  existing tunnel (WireGuard, Tailscale), exactly like unencrypted VNC.
  Reports about the absence of TLS are known — it is tracked in the
  roadmap. Reports about token handling, auth bypass, or parser abuse of
  the HTTP server are very much in scope.
- The **VNC DES authentication** is weak by protocol design (RFC 6143);
  wisq warns users about plaintext transport in the editor. In scope:
  anything that leaks the password further than the protocol already does.
- The **rv32ima emulator** executes untrusted guest code by design. In
  scope: any way for a guest to corrupt emulator memory outside its RAM
  allocation, or to escape the machine abstraction.
