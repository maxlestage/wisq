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
