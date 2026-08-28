/// What the preview server promises about caching.
///
/// `scripts/serve.ts` says it serves the site "the way a real host would", and
/// that is a checkable claim rather than a description. It was not true: every
/// file went out as `no-store`, which is reliably fresh and unlike any host
/// that has ever existed. These tests are what makes the claim mean something.
///
/// The handler is imported and called with a `Request`; no port is opened, so
/// nothing here can hang a CI runner or collide with a port already in use.

import { describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { cacheControl, handler } from "../scripts/serve";
import { REQUEST_ORIGIN, siteURL } from "../src/site-url";

const dist = join(import.meta.dir, "..", "dist");

function hashedAsset(extension: string): string {
  const name = readdirSync(dist).find(
    (file) => file.startsWith("chunk-") && file.endsWith(extension),
  );
  if (!name) throw new Error(`aucun actif haché en ${extension} dans dist`);
  return name;
}

async function get(path: string): Promise<Response> {
  return handler(new Request(`http://127.0.0.1/${path.replace(/^\//, "")}`));
}

describe("what the preview server sends", () => {
  /// The one that has to be right. A service worker served from a cache freezes
  /// the site at whatever it last installed, and no later deploy can reach the
  /// reader — a failure that is permanent rather than slow.
  test("the service worker is never served from a cache", async () => {
    const response = await get("sw.js");
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-cache");
    expect(response.headers.get("content-type")).toStartWith("text/javascript");
  });

  /// A content-hashed name cannot go stale, so revalidating one is a round trip
  /// that can only ever answer "still the same".
  test.each([[".js"], [".css"]])("a hashed %s asset is immutable for a year", async (ext) => {
    const response = await get(hashedAsset(ext));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
  });

  /// Unhashed names whose content changes under a fixed address. `no-cache`
  /// keeps the copy and revalidates it — a 304 rather than a download — so it
  /// is cheap and can never be stale.
  test.each([
    ["", "a document"],
    ["docs/", "a written page"],
    ["manifest.webmanifest", "the manifest"],
    ["icon-192.png", "an icon"],
    ["social-card.png", "the social card"],
  ])("%s (%s) is revalidated rather than trusted", async (path) => {
    const response = await get(path);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-cache");
  });

  /// `no-cache` and `no-store` are different instructions and the difference is
  /// the whole point: `no-store` forbids keeping the bytes at all, so every
  /// visit re-downloads the page. That is what this server used to send for
  /// everything.
  test("nothing is served with no-store", async () => {
    for (const path of ["", "docs/", "sw.js", "manifest.webmanifest", hashedAsset(".js")]) {
      const value = (await get(path)).headers.get("cache-control");
      expect(value, `${path} : no-store`).not.toContain("no-store");
    }
  });

  test("an unknown address gets the 404 page, and it is not cached", async () => {
    const response = await get("this/does/not/exist");
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toStartWith("text/html");
    expect(response.headers.get("cache-control")).toBe("no-cache");
  });
});

describe("the rule itself", () => {
  /// Read directly, so a path that never appears in `dist` today is still
  /// classified the way the comment in `serve.ts` says it is.
  test.each([
    ["/sw.js", "no-cache"],
    ["/chunk-abc123.js", "public, max-age=31536000, immutable"],
    ["/chunk-abc123.css", "public, max-age=31536000, immutable"],
    ["/index.html", "no-cache"],
    ["/fr/docs/index.html", "no-cache"],
    ["/manifest.webmanifest", "no-cache"],
    // Not hashed, whatever it looks like: the extension decides nothing on its
    // own, and a stylesheet that is not content-addressed must revalidate.
    ["/styles.css", "no-cache"],
  ])("%s -> %s", (path, expected) => {
    expect(cacheControl(path)).toBe(expected);
  });
});

/// The address the site gives for itself, when nobody told it one.
///
/// `SITE_URL` used to be required at build time, and `scripts/heroku-build.sh`
/// refused to build without it. That turned "the operator forgot a config var"
/// into "the deployment fails", which on a phone means the site does not go up
/// at all — three builds in a row died there. The address is now resolved where
/// it is known: here, from the request.
///
/// Every assertion below was checked by breaking the rewrite and watching it
/// fail; the sentinel is deliberately an unreachable `.invalid` host, so a
/// rewrite that silently stopped happening would leave a visibly broken link
/// rather than a plausible wrong one.
describe("the address the site gives for itself", () => {
  async function bodyFrom(host: string, path: string): Promise<string> {
    const response = await handler(new Request(`${host}/${path.replace(/^\//, "")}`));
    expect(response.status).toBe(path === "nulle-part" ? 404 : 200);
    return response.text();
  }

  /// What the address in a served file should be, given how `dist` was built.
  ///
  /// The tests below used to assume the build had no `SITE_URL`, which is how
  /// CI and `scripts/verify.sh` build it — and would have gone red for anyone
  /// who happened to have the variable exported. That is a test of the
  /// operator's shell rather than of the server. Both configurations are real,
  /// the deployment uses the first, and CI now runs the Heroku build path both
  /// ways; the contract holds in each.
  const pinned = siteURL() === REQUEST_ORIGIN ? null : siteURL();
  function expected(host: string): string {
    return pinned ?? `${host}/`;
  }

  test.each([
    ["", "the home page"],
    ["fr/", "the French home page"],
    ["docs/", "a written page"],
  ])("%s (%s) is canonical at the host that served it", async (path) => {
    const body = await bodyFrom("https://exemple.test", path);
    expect(body).toContain(`<link rel="canonical" href="${expected("https://exemple.test")}`);
    expect(body).not.toContain(REQUEST_ORIGIN);
  });

  /// The same build, served from two hosts, gives each of them its own address.
  /// A test on one host alone would pass against a hardcoded string.
  test("two hosts get two different answers from the same files", async () => {
    if (pinned) return; // A pinned address is the same everywhere, by design.
    const one = await bodyFrom("https://un.test", "");
    const two = await bodyFrom("https://deux.test", "");
    expect(one).toContain("https://un.test/");
    expect(two).toContain("https://deux.test/");
    expect(one).not.toContain("deux.test");
    expect(two).not.toContain("un.test");
  });

  /// The three files that are not pages and carry the address anyway. The
  /// sitemap is the one that matters: every entry in it is absolute.
  test.each([
    ["sitemap.xml", "<loc>"],
    ["robots.txt", "Sitemap: "],
  ])("%s points at the host that served it", async (path, prefix) => {
    const body = await bodyFrom("https://exemple.test", path);
    expect(body).toContain(`${prefix}${expected("https://exemple.test")}`);
    expect(body).not.toContain(REQUEST_ORIGIN);
  });

  /// The 404 page is served through a different branch of the handler, and a
  /// rewrite added to one branch and not the other is exactly the kind of thing
  /// that survives review.
  test("the 404 page is rewritten too", async () => {
    const body = await bodyFrom("https://exemple.test", "nulle-part");
    expect(body).not.toContain(REQUEST_ORIGIN);
  });

  /// Heroku terminates TLS at its router, so the dyno sees plain HTTP for a
  /// reader who typed `https`. Without this the canonical link on every page
  /// would name an address that redirects.
  test("a reader behind a TLS-terminating proxy gets an https address", async () => {
    const response = await handler(
      new Request("http://wisq.example/", { headers: { "x-forwarded-proto": "https" } }),
    );
    const body = await response.text();
    expect(body).toContain(`<link rel="canonical" href="${expected("https://wisq.example")}`);
    if (!pinned) expect(body).not.toContain("http://wisq.example");
  });

  /// The header is attacker-controlled wherever a router does not set it, and a
  /// value that is not a scheme must not become one.
  test.each([["gopher"], [""], ["https evil"], ["javascript:"]])(
    "a forwarded scheme of %p is refused rather than stamped",
    async (proto) => {
      const response = await handler(
        new Request("http://wisq.example/", { headers: { "x-forwarded-proto": proto } }),
      );
      const body = await response.text();
      expect(body).toContain(`<link rel="canonical" href="${expected("http://wisq.example")}`);
      if (proto !== "") expect(body).not.toContain(`${proto}://wisq.example`);
    },
  );

  /// The whole build, swept: nothing served may still carry the sentinel.
  test("no served file leaks the sentinel", async () => {
    for (const name of readdirSync(dist)) {
      if (!/\.(html|xml|txt|webmanifest)$/.test(name)) continue;
      const body = await bodyFrom("https://exemple.test", name);
      expect(body).not.toContain(REQUEST_ORIGIN);
    }
  });
});
