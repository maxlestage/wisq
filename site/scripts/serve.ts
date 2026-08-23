/// Serves the built site the way a real host would.
///
/// `bun run dev` is for writing the site; this is for checking the thing that
/// ships. The difference matters more than it sounds: the service worker, the
/// manifest and the offline behaviour only exist in the build, and a browser
/// refuses to install a service worker that arrives without a JavaScript
/// content type — so a preview server that omits it reports a PWA that does
/// not work when the deployed site is fine.
///
///   bun run preview        then open http://127.0.0.1:4321/

import { join, extname } from "node:path";

const root = join(import.meta.dir, "..", "dist");
const port = Number(process.env.PORT ?? 4321);

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".xml": "application/xml; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
};

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);
    let path = decodeURIComponent(url.pathname);
    if (path.endsWith("/")) path += "index.html";

    const file = Bun.file(join(root, path));
    if (await file.exists()) {
      return new Response(file, {
        headers: {
          "content-type": TYPES[extname(path)] ?? "application/octet-stream",
          // A service worker must not be served from a stale cache, or an
          // update never reaches the browser.
          "cache-control": path.endsWith("sw.js") ? "no-cache" : "no-store",
        },
      });
    }

    // What a static host does with an unknown address, so the 404 page is
    // testable rather than assumed.
    const notFound = Bun.file(join(root, "404.html"));
    if (await notFound.exists()) {
      return new Response(notFound, {
        status: 404,
        headers: { "content-type": TYPES[".html"]! },
      });
    }
    return new Response("404", { status: 404 });
  },
});

console.log(`aperçu du site construit : http://127.0.0.1:${port}/`);
