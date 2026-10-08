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
import { mkdtempSync, readdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { IMMUTABLE, cacheControl, handler, immutableNames } from "../scripts/serve";
import { REQUEST_ORIGIN, siteURL } from "../src/site-url";

const dist = join(import.meta.dir, "..", "dist");

/// Tout ce que la construction écrit à la racine de `dist`, dossiers exclus :
/// les documents vivent dans des sous-dossiers et sont tenus ailleurs.
function builtFiles(): string[] {
  return readdirSync(dist).filter((name) => statSync(join(dist, name)).isFile());
}

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

  /// **La police partait en `no-cache`, et c'est mesuré.** Le plus gros actif
  /// du site — 90 104 octets, le seul binaire du dépôt — était revalidé à
  /// chaque navigation pendant que le `.css` haché posé juste à côté partait en
  /// `immutable`. Relevé avec `curl` sur le serveur réel :
  ///
  ///     /archivo-variable-latin-<hash>.woff2   no-cache   application/octet-stream
  ///     /chunk-<hash>.css                      immutable  text/css
  ///
  /// Les deux moitiés du défaut ont la même forme. L'en-tête de `cacheControl`
  /// énonce une **propriété** — « named after their content, so the name
  /// changes whenever the bytes do » — et la règle implémentait une
  /// **orthographe**, `/chunk-[a-z0-9]+\.(js|css)$/`. Et l'en-tête de `TYPES`
  /// affirme que chaque entrée « coincides with what Bun infers on its own » ;
  /// c'est vrai des entrées présentes, et la police n'en avait aucune — Bun
  /// n'infère pas `font/woff2`, il rend `application/octet-stream`.
  test("la police adressée par son contenu est immuable, et porte son type", async () => {
    const name = builtFiles().find((file) => file.endsWith(".woff2"));
    expect(name, "aucune police dans dist").toBeDefined();
    const response = await get(name!);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
    expect(response.headers.get("content-type")).toBe("font/woff2");
  });

  /// **Rien de ce que la construction produit ne sort sans type.**
  ///
  /// Dérivé de `dist` plutôt que de la table : c'est l'acte qu'on mesure, pas
  /// son empreinte. Un type d'actif nouveau — la police en a été le premier en
  /// deux ans — se signale ici au lieu de partir en flux d'octets, ce qui est
  /// précisément la panne que l'en-tête de `TYPES` dit vouloir éviter.
  test("aucun fichier construit ne part en flux d'octets", async () => {
    const seen = new Set<string>();
    for (const name of builtFiles()) {
      const response = await get(name);
      expect(response.status, name).toBe(200);
      expect(response.headers.get("content-type"), `${name} : ${extname(name)} sans type`)
        .not.toBe("application/octet-stream");
      seen.add(extname(name));
    }
    // Sinon la boucle ci-dessus pourrait ne rien avoir parcouru.
    expect(seen.size, "dist ne porte qu'une sorte de fichier").toBeGreaterThan(4);
  });

  /// **L'immuabilité vient de la construction, pas d'un motif de nom.**
  ///
  /// `build.tsx` est le seul qui sache quels noms il a tirés d'une empreinte de
  /// contenu : il en écrit la liste, et le serveur la lit. Ce test la relit par
  /// un autre chemin — les extensions présentes dans `dist` — pour que deux
  /// lecteurs du même fait aient à s'accorder.
  test("la liste des immuables est celle que la construction a écrite", () => {
    const files = builtFiles();
    const attendus = new Set(
      files.filter(
        (name) =>
          name.endsWith(".woff2") ||
          (name.startsWith("chunk-") && (name.endsWith(".js") || name.endsWith(".css"))),
      ),
    );
    expect(attendus.size, "ni police ni actif haché dans dist").toBeGreaterThan(2);
    expect(new Set(IMMUTABLE)).toEqual(attendus);

    // Et la conséquence, dans les deux sens, sur chaque fichier construit.
    for (const name of files) {
      const expected = attendus.has(name)
        ? "public, max-age=31536000, immutable"
        : "no-cache";
      expect(cacheControl(`/${name}`), name).toBe(expected);
    }
  });

  /// **Un serveur qui ne trouve pas la liste ne doit pas servir tout en
  /// `no-cache` sans le dire.** Ce serait la panne qu'on vient de corriger,
  /// revenue en silence : un dixième de seconde de plus par navigation, que
  /// rien ne signale. Il refuse, et c'est pourquoi `serve.ts` ne peut même pas
  /// s'importer sans elle.
  test("sans la liste, le serveur refuse au lieu de deviner", () => {
    const vide = mkdtempSync(join(tmpdir(), "wisq-serve-vide-"));
    expect(() => immutableNames(vide)).toThrow(/immutable\.txt/);
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
  /// Lu directement, sur les noms que la construction a réellement produits.
  ///
  /// **Ce tableau portait `/chunk-abc123.js` et attendait `immutable`**, et
  /// c'était la prémisse du défaut : un chemin qui ne figure nulle part dans
  /// `dist` achetait un an de cache parce qu'il en avait l'**orthographe**.
  /// L'appartenance décide maintenant, et elle vient de la construction — donc
  /// un nom qui ressemble à un actif haché sans en être un revalide, ce qui est
  /// strictement plus fort que ce que ce tableau tenait avant.
  test.each([
    ["/sw.js", "no-cache"],
    [`/${hashedAsset(".js")}`, "public, max-age=31536000, immutable"],
    [`/${hashedAsset(".css")}`, "public, max-age=31536000, immutable"],
    ["/index.html", "no-cache"],
    ["/fr/docs/index.html", "no-cache"],
    ["/manifest.webmanifest", "no-cache"],
    // Not hashed, whatever it looks like: the extension decides nothing on its
    // own, and a stylesheet that is not content-addressed must revalidate.
    ["/styles.css", "no-cache"],
    // Et l'orthographe non plus : celui-ci a tout l'air d'un actif haché, et
    // la construction ne l'a jamais écrit.
    ["/chunk-abc123.js", "no-cache"],
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
