/// Serves the built site. On Heroku this is the host; locally it is the
/// preview, and they are the same code on purpose.
///
/// `bun run dev` is for writing the site; this is for checking the thing that
/// ships — and now for shipping it, since the `Procfile` runs this file. What
/// used to be the argument for keeping the preview honest is now simply true:
/// there is one server, `tests/serve.test.ts` holds it, and a reader gets what
/// the tests describe.
///
/// The difference from `dev` matters more than it sounds: the service worker, the
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

import { REQUEST_ORIGIN } from "../src/site-url";

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
/// **All of this now reaches the deployed site, and that is new.** Under GitHub
/// Pages none of it did — Pages sends its own headers and offers no way to set
/// them — so this file was a promise about a host that never listened, and the
/// caching that actually decided what a returning reader downloaded lived
/// entirely in the service worker `build.tsx` generates.
///
/// The site is served by Heroku now, and the `Procfile` at the repository root
/// runs *this file*. The comment above used to end "what to configure the day
/// the site moves to a host that takes instructions"; that day arrived, and
/// nothing had to be configured, because the day had been written for. What
/// changed is the weight: these three lines are production, and the service
/// worker is no longer carrying the caching alone.
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

/// The file types that carry the site's own address, and are therefore rewritten
/// per request.
///
/// Nothing else needs it: the scripts, the stylesheets and the images name
/// their neighbours by relative path, and the service worker caches by relative
/// path too. Rewriting only these four keeps the hashed assets — the bulk of
/// the bytes — a straight file handoff.
const ADDRESSED = new Set([".html", ".xml", ".txt", ".webmanifest"]);

/// Puts the address the reader actually used into what they receive.
///
/// The build stamps `REQUEST_ORIGIN` when `SITE_URL` is unset, so the canonical
/// links, the `hreflang` alternates, the sitemap, `robots.txt` and the social
/// card all point at the host answering the request. A deployment does not have
/// to be told its own name, and moving it somewhere else needs no rebuild.
///
/// `SITE_URL` set at build time short-circuits this: the sentinel is not in the
/// files, so the replacement finds nothing and the pinned address stands.
export function requestOrigin(request: Request): string {
  const url = new URL(request.url);
  // Heroku terminates TLS at its router and forwards plain HTTP to the dyno, so
  // the scheme this process sees is `http` for a reader who typed `https`.
  // Canonical links and sitemap entries that said `http` would advertise the
  // site at an address that redirects, on every page. The router states what
  // the reader used; `X-Forwarded-Proto` is that statement.
  //
  // Only the two schemes a browser can be on are honoured. The header is
  // attacker-controlled on a host that does not set it, and the worst a wrong
  // value could do here is stamp a scheme; refusing anything else keeps it from
  // stamping something that is not a scheme at all.
  const forwarded = request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim();
  const scheme = forwarded === "https" || forwarded === "http" ? forwarded : url.protocol.replace(":", "");
  return `${scheme}://${url.host}/`;
}

export function withRequestOrigin(body: string, request: Request): string {
  return body.split(REQUEST_ORIGIN).join(requestOrigin(request));
}

export async function handler(request: Request): Promise<Response> {
  const url = new URL(request.url);
  let path = decodeURIComponent(url.pathname);
  if (path.endsWith("/")) path += "index.html";

  const file = Bun.file(join(root, path));
  if (await file.exists()) {
    const type = TYPES[extname(path)] ?? "application/octet-stream";
    const headers = { "content-type": type, "cache-control": cacheControl(path) };
    if (ADDRESSED.has(extname(path))) {
      return new Response(withRequestOrigin(await file.text(), request), { headers });
    }
    return new Response(file, { headers });
  }

  // What a static host does with an unknown address, so the 404 page is
  // testable rather than assumed.
  const notFound = Bun.file(join(root, "404.html"));
  if (await notFound.exists()) {
    return new Response(withRequestOrigin(await notFound.text(), request), {
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
