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
///
/// The request handler is exported and `Bun.serve` only runs when this file is
/// the entry point, so `tests/serve.test.ts` can put a `Request` through it
/// without opening a port. A preview server that claims to serve the site "the
/// way a real host would" is making a checkable claim, and it should be checked.

import { join, extname } from "node:path";

const root = join(import.meta.dir, "..", "dist");

/// The content types this server states explicitly.
///
/// **Every one of them currently coincides with what Bun infers on its own** —
/// checked, including `.webmanifest`, which is the one worth doubting. Removing
/// this map changes no response and fails no test. It is kept anyway, for the
/// reason in the header comment: a service worker that arrives without a
/// JavaScript content type is refused, and that is a failure worth not leaving
/// to a dependency's inference table. The tests assert the resulting header
/// rather than this map, so whichever of the two supplies it, the contract is
/// the thing being held.
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

/// What a host should send for each kind of file this build produces.
///
/// Everything used to be `no-store`, which made the preview reliably fresh and
/// quietly unlike any real host: nobody serves a content-hashed asset with
/// `no-store`, and a preview that differs from production in the one dimension
/// you are previewing is not a preview. Three classes, and the reason for each:
///
///   - **Hashed assets.** `chunk-<hash>.js` and `chunk-<hash>.css` are named
///     after their content, so the name changes whenever the bytes do. There is
///     no such thing as a stale one, which is exactly what `immutable` asserts:
///     do not even revalidate. A year is the conventional ceiling.
///   - **The service worker.** Never from a cache, or an update never reaches
///     the browser and the site is frozen at whatever it last installed. This is
///     the one that has to be right — a wrong answer here is not slow, it is
///     permanent.
///   - **Everything else** — documents, the manifest, the icons, the social
///     card. Unhashed names, so their content can change under a fixed address.
///     `no-cache` is not `no-store`: the browser keeps the copy and revalidates
///     before using it, which costs a 304 rather than a download and can never
///     serve something stale.
///
/// None of this reaches the deployed site: it is served by GitHub Pages, which
/// sends its own headers and offers no way to set them. That is the honest
/// state of the "cache headers" item, and it is why the caching that actually
/// decides what a returning reader downloads lives in the service worker, which
/// `build.tsx` generates and this project does control. These headers are what
/// the preview promises, and what to configure the day the site moves to a host
/// that takes instructions.
export function cacheControl(path: string): string {
  // This line returns what the fallback below already returns, so deleting it
  // changes nothing today and no test can see it go. It earns its place the
  // moment the fallback stops agreeing: made `immutable`, the fallback breaks
  // nine tests with this line present and eleven without — the two extra being
  // the service worker's, which is the failure that is permanent rather than
  // slow. A guard that duplicates the default it guards against cannot be
  // tested by removing it, only by changing the default.
  if (path.endsWith("sw.js")) return "no-cache";
  if (/\/chunk-[a-z0-9]+\.(js|css)$/.test(path)) return "public, max-age=31536000, immutable";
  return "no-cache";
}

export async function handler(request: Request): Promise<Response> {
  const url = new URL(request.url);
  let path = decodeURIComponent(url.pathname);
  if (path.endsWith("/")) path += "index.html";

  const file = Bun.file(join(root, path));
  if (await file.exists()) {
    return new Response(file, {
      headers: {
        "content-type": TYPES[extname(path)] ?? "application/octet-stream",
        "cache-control": cacheControl(path),
      },
    });
  }

  // What a static host does with an unknown address, so the 404 page is
  // testable rather than assumed.
  const notFound = Bun.file(join(root, "404.html"));
  if (await notFound.exists()) {
    return new Response(notFound, {
      status: 404,
      headers: { "content-type": TYPES[".html"]!, "cache-control": "no-cache" },
    });
  }
  return new Response("404", { status: 404 });
}

if (import.meta.main) {
  const port = Number(process.env.PORT ?? 4321);
  Bun.serve({ port, fetch: handler });
  console.log(`aperçu du site construit : http://127.0.0.1:${port}/`);
}
