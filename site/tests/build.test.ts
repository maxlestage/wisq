import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { LANGS, ROUTES, outputPath, pagePath, routeById } from "../src/routes";
import { copy } from "../src/content";

/// The built artefact, not the source. `bun run build` must run before this;
/// CI does exactly that.
const dist = join(import.meta.dir, "..", "dist");
const read = (relative: string) => readFileSync(join(dist, relative), "utf8");

/// Every document the build writes: each route, in each language. Tests that
/// used to walk the routes walk this instead, or they check half the site.
const BUILT = LANGS.flatMap((lang) =>
  ROUTES.map((route) => ({ route, lang, file: outputPath(route, lang) })),
);

function pngSize(relative: string): { width: number; height: number } {
  const bytes = readFileSync(join(dist, relative));
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (const [index, byte] of signature.entries()) {
    expect(bytes[index], `${relative} n'est pas un PNG`).toBe(byte);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

describe("built output", () => {
  test("the build ran", () => {
    expect(
      existsSync(join(dist, "index.html")),
      "dist/index.html manquant : lancez `bun run build`",
    ).toBe(true);
  });

  test("every route produced a document", () => {
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      expect(existsSync(join(dist, file)), `${file} manquant`).toBe(true);
    }
  });

  test("the page is readable before any JavaScript loads", () => {
    // The whole point of pre-rendering: content in the first response.
    const home = read("index.html");
    expect(home).toContain("Virtual machines on your iPhone.");
    expect(home).toContain("How pairing works");

    const guide = read("docs/index.html");
    expect(guide).toContain("Remote: a VM on your own hardware");
    expect(guide).toContain("wisq-agent");
  });

  /// The strongest guard here: resolve every relative reference against the
  /// directory of the page that makes it, and require the file to exist. A
  /// subdirectory page that says `./chunk.js` instead of `../chunk.js` builds
  /// fine, deploys fine, and 404s in the browser.
  test("every relative reference resolves to a file that exists", () => {
    let checked = 0;
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      const html = read(file);
      const here = dirname(join(dist, file));
      const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((match) => match[1]!);

      for (const raw of refs) {
        if (/^(https?:|data:|mailto:|#)/.test(raw)) continue;
        expect(raw.startsWith("/"), `chemin absolu dans ${file} : ${raw}`).toBe(false);

        // A fragment addresses a place inside a document, not a file:
        // `./#install` is the landing page's install section and resolves to
        // the landing page itself.
        const ref = raw.split("#")[0]!;
        if (ref === "") continue;

        // A directory reference means that directory's index.
        const target = normalize(join(here, ref.endsWith("/") ? `${ref}index.html` : ref));
        expect(existsSync(target), `${file} référence ${raw}, absent du build`).toBe(true);
        checked += 1;
      }
    }
    expect(checked).toBeGreaterThan(40);
  });

  test("every document carries the head a shared link needs", () => {
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      const html = read(file);
      expect(html, `${file} : viewport`).toContain("width=device-width");
      expect(html, `${file} : viewport-fit`).toContain("viewport-fit=cover");
      expect(html, `${file} : canonical`).toContain('rel="canonical"');
      expect(html, `${file} : manifeste`).toContain('rel="manifest"');
      expect(html, `${file} : icône iOS`).toContain('rel="apple-touch-icon"');
      expect(html, `${file} : image sociale`).toContain('property="og:image"');
      // Catches an empty or placeholder description. The bound is deliberately
      // below the shortest real one — the French 404's complete sentence is 39
      // characters — because the guard is against a stub, not against brevity.
      expect(html, `${file} : description`).toMatch(/<meta name="description" content="[^"]{30,}"/);
    }
  });

  /// Within a language, not across it: "Architecture" is the same word in
  /// French, so two pages sharing a title across languages is correct and
  /// telling them apart is what the hreflang links are for.
  test("each page has its own title and description", () => {
    for (const lang of LANGS) {
      const pages = BUILT.filter((page) => page.lang === lang);
      const titles = new Set<string>();
      const descriptions = new Set<string>();
      for (const { file } of pages) {
        const html = read(file);
        titles.add(html.match(/<title>([^<]+)<\/title>/)![1]!);
        descriptions.add(html.match(/<meta name="description" content="([^"]+)"/)![1]!);
      }
      expect(titles.size, `titres distincts en ${lang}`).toBe(pages.length);
      expect(descriptions.size, `descriptions distinctes en ${lang}`).toBe(pages.length);
    }
  });

  /// The whole point of the French build: a French page must not be an English
  /// page wearing a French address.
  test("each French page is actually in French", () => {
    for (const { route, file } of BUILT.filter((page) => page.lang === "fr")) {
      const html = read(file);
      const english = read(outputPath(route, "en"));
      expect(html, `${file} : langue déclarée`).toContain('<html lang="fr">');
      const title = (raw: string) => raw.match(/<title>([^<]+)<\/title>/)![1]!;
      const lede = (raw: string) => raw.match(/<meta name="description" content="([^"]+)"/)![1]!;
      // Titles may legitimately match — "Architecture" — but a page whose
      // title *and* description both match the English one was never
      // translated.
      expect(
        title(html) === title(english) && lede(html) === lede(english),
        `${file} : identique à la version anglaise`,
      ).toBe(false);
    }
  });

  test("hydration knows which page it is on and in which language", () => {
    for (const { route, lang, file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : route`).toContain(`data-route="${route.id}"`);
      expect(html, `${file} : langue`).toContain(`data-lang="${lang}"`);
      expect(html, `${file} : base`).toMatch(/data-base="(\.\/|(\.\.\/)+)"/);
    }
  });

  test("structured data appears once per language, on the landing pages", () => {
    const withJsonLd = BUILT.filter(({ file }) => read(file).includes("application/ld+json"));
    expect(withJsonLd.map(({ route, lang }) => `${lang}:${route.id}`)).toEqual([
      "en:home",
      "fr:home",
    ]);
  });
});

describe("the mark", () => {
  /// Two logos on the landing page and one everywhere else, which is the whole
  /// point of drawing a second one: the header wordmark names the site on every
  /// page, and the full mark gets the room the hero has and no other page does.
  test("the full mark is on the landing page and nowhere else", () => {
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      const html = read(file);
      const marks = html.split('class="hero-logo"').length - 1;
      expect(marks, `${file} : nombre de marques complètes`).toBe(
        route.id === "home" ? 1 : 0,
      );
      // The wordmark is the one logo every page carries.
      expect(html, `${file} : mot-marque`).toContain('class="brand"');
    }
  });

  /// Drawn, not fetched. An <img> here would be a second request before the
  /// hero can paint, and a committed binary nobody can diff.
  test("the mark is inline and costs no request", () => {
    const home = read("index.html");
    expect(home).toContain('<svg class="hero-logo"');
    expect(home.match(/<img[^>]*hero-logo/)).toBeNull();
  });

  /// The header brand and the heading already say what this is, so announcing
  /// it a third time is noise for anyone listening rather than looking.
  test("the mark is decorative", () => {
    const svg = read("index.html").match(/<svg class="hero-logo"[^>]*>/)?.[0];
    expect(svg).toBeDefined();
    expect(svg).toContain('aria-hidden="true"');
  });
});

describe("footer", () => {
  /// A footer is where someone goes when the page did not answer them. It is
  /// on every page or it is not a footer, so this checks every page rather
  /// than the landing one.
  /// Read against the copy rather than against hard-coded English, so the
  /// French pages are held to the same standard in their own language instead
  /// of being exempt from the check.
  test("every page carries the whole footer, in its own language", () => {
    const escape = (text: string) =>
      text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/'/g, "&#x27;");
    for (const { lang, file } of BUILT) {
      const html = read(file);
      const footer = copy[lang].footer;
      for (const heading of Object.values(footer.groups)) {
        expect(html, `${file} : groupe ${heading}`).toContain(`>${escape(heading)}</h2>`);
      }
      for (const label of Object.values(footer.links)) {
        expect(html, `${file} : lien ${label}`).toContain(`>${escape(label)}</a>`);
      }
      expect(html, `${file} : retour en haut`).toContain(`>${escape(footer.backToTop)}</a>`);
      expect(html, `${file} : version`).toContain(`${escape(footer.version)} `);
      expect(html, `${file} : licence`).toContain("Apache-2.0");
    }
  });

  test("the footer's project links point at files the repository has", () => {
    const html = read("index.html");
    for (const path of [
      "/blob/master/LICENSE",
      "/blob/master/CONTRIBUTING.md",
      "/blob/master/SECURITY.md",
      "/blob/master/CHANGELOG.md",
      "/issues",
    ]) {
      expect(html, `lien projet manquant : ${path}`).toContain(`github.com/maxlestage/wisq${path}`);
    }
    const repoRoot = join(dist, "..", "..");
    for (const file of ["LICENSE", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"]) {
      expect(existsSync(join(repoRoot, file)), `${file} absent du dépôt`).toBe(true);
    }
  });

  test("the version shown is the newest released one", () => {
    const changelog = readFileSync(join(dist, "..", "..", "CHANGELOG.md"), "utf8");
    const newest = changelog.match(/^## \[(\d+\.\d+\.\d+)\] —/m)?.[1];
    expect(newest, "aucune version datée dans le CHANGELOG").toBeDefined();
    expect(read("index.html"), "la version du pied de page a dérivé").toContain(
      `Version ${newest}`,
    );
  });
});

describe("progressive web app", () => {
  test("the manifest is valid and complete enough to install", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    expect(manifest.name.length).toBeGreaterThan(0);
    expect(manifest.short_name).toBe("wisq");
    expect(manifest.display).toBe("standalone");
    expect(manifest.background_color).toMatch(/^#[0-9a-f]{6}$/i);
    expect(manifest.theme_color).toMatch(/^#[0-9a-f]{6}$/i);

    // Relative, so the site keeps working when it moves off /wisq/.
    expect(manifest.start_url.startsWith("./")).toBe(true);
    expect(manifest.scope.startsWith("./")).toBe(true);
  });

  test("the manifest's icons exist and are the size they claim", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    expect(manifest.icons.length).toBeGreaterThanOrEqual(3);
    for (const icon of manifest.icons) {
      const relative = icon.src.replace(/^\.\//, "");
      const [width, height] = icon.sizes.split("x").map(Number);
      const actual = pngSize(relative);
      expect(actual.width, `${relative} : largeur`).toBe(width);
      expect(actual.height, `${relative} : hauteur`).toBe(height);
    }
  });

  /// An installable icon that a launcher may crop to a circle needs one
  /// declared maskable, or Android pastes the square onto a white plate.
  test("one icon is declared maskable", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    const maskable = manifest.icons.filter((icon: { purpose?: string }) =>
      icon.purpose?.includes("maskable"),
    );
    expect(maskable.length).toBeGreaterThanOrEqual(1);
  });

  /// iOS ignores the manifest for the Home Screen icon and reads this instead.
  /// It is also the reason these are PNG rather than SVG.
  test("the iOS home screen icon is a real PNG", () => {
    expect(pngSize("apple-touch-icon.png")).toEqual({ width: 180, height: 180 });
  });

  test("the social card is the size the scrapers crop to", () => {
    expect(pngSize("social-card.png")).toEqual({ width: 1200, height: 630 });
  });

  test("the service worker precaches only files that exist", () => {
    const sw = read("sw.js");
    const list = JSON.parse(sw.match(/const PRECACHE = (\[[\s\S]*?\]);/)![1]!) as string[];
    expect(list.length).toBeGreaterThan(5);
    for (const entry of list) {
      const relative = entry.replace(/^\.\//, "");
      const target = join(dist, relative === "" ? "index.html" : relative);
      const file = existsSync(target) && statSync(target).isDirectory()
        ? join(target, "index.html")
        : relative.endsWith("/")
          ? join(dist, relative, "index.html")
          : target;
      expect(existsSync(file), `précache ${entry} : fichier absent`).toBe(true);
    }
  });

  /// The defect this exists for: `Cache.addAll` rejects the entire list when
  /// two entries resolve to the same URL, and a rejected install leaves no
  /// worker at all. The site keeps working and quietly stops being installable
  /// — found by driving a browser, not by reading the code.
  test("the precache list has no duplicates, and the install deduplicates anyway", () => {
    const sw = read("sw.js");
    const list = JSON.parse(sw.match(/const PRECACHE = (\[[\s\S]*?\]);/)![1]!) as string[];
    expect(new Set(list).size, "doublon dans PRECACHE").toBe(list.length);
    expect(sw, "l'installation doit dédupliquer").toContain("new Set(");
  });

  /// One fallback per language, or a reader browsing in French falls out of
  /// French the moment the network goes.
  test("the service worker has an offline fallback per language, and both were built", () => {
    const sw = read("sw.js");
    for (const lang of LANGS) {
      expect(sw, `repli hors ligne ${lang}`).toContain(`${lang}: "./${pagePath(routeById("offline"), lang)}"`);
      expect(existsSync(join(dist, outputPath(routeById("offline"), lang))), `${lang} : page hors ligne`).toBe(true);
    }
    expect(sw, "le repli suit la langue de l'adresse").toContain("offlineFor");
  });

  /// A 404 from a mistyped link, or a 500 from a half-finished deploy, must not
  /// be kept and served back later. Found by watching the cache grow by one
  /// entry per unknown address while driving a browser.
  test("only pages that actually loaded are cached", () => {
    const sw = read("sw.js");
    const navigation = sw.slice(sw.indexOf('request.mode === "navigate"'));
    expect(navigation.slice(0, navigation.indexOf("cache.put"))).toContain("response.ok");
  });

  test("the cache is versioned, so an old one cannot outlive a deploy", () => {
    const sw = read("sw.js");
    expect(sw).toMatch(/const VERSION = "wisq-[0-9a-f]+"/);
    expect(sw).toContain("caches.delete");
  });
});

describe("discoverability", () => {
  test("the sitemap lists every page meant to be found, in both languages", () => {
    const sitemap = read("sitemap.xml");
    const listed = ROUTES.filter((route) => route.listed);
    for (const lang of LANGS) {
      for (const route of listed) {
        expect(sitemap, `${lang}/${route.id} absent du sitemap`).toContain(
          `/wisq/${pagePath(route, lang)}</loc>`,
        );
      }
    }
    expect([...sitemap.matchAll(/<loc>/g)].length).toBe(listed.length * LANGS.length);
    // Each entry names its counterpart, so a search engine shows a reader the
    // one in their language rather than picking for them.
    expect([...sitemap.matchAll(/hreflang=/g)].length).toBe(
      listed.length * LANGS.length * LANGS.length,
    );
    // The offline page and the 404 are not destinations.
    expect(sitemap).not.toContain("offline/");
    expect(sitemap).not.toContain("404");
  });

  test("robots points at the sitemap", () => {
    const robots = read("robots.txt");
    expect(robots).toContain("Sitemap:");
    expect(robots).toContain("sitemap.xml");
  });

  test("an unknown address gets a page, not a bare server error", () => {
    const html = read("404.html");
    expect(html).toContain("Not found");
    // And it can still navigate: a dead end is not a 404 page.
    expect(html).toContain('href="./docs/"');
  });

  /// The privacy page says the site loads nothing from anyone else. That is a
  /// claim about the built artefact, so it is checked against the built
  /// artefact rather than trusted.
  test("no external stylesheet, script, font, image or frame is loaded", () => {
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });

    for (const file of walk(dist).filter((f) => f.endsWith(".html"))) {
      const html = readFileSync(file, "utf8");
      const loaders = [
        ...html.matchAll(/<script[^>]+src="([^"]+)"/g),
        ...html.matchAll(/<link[^>]+rel="(?:stylesheet|preload|preconnect|dns-prefetch)"[^>]+href="([^"]+)"/g),
        ...html.matchAll(/<img[^>]+src="([^"]+)"/g),
        ...html.matchAll(/<iframe[^>]+src="([^"]+)"/g),
      ];
      for (const match of loaders) {
        expect(
          /^https?:/.test(match[1]!),
          `${file} charge une ressource externe : ${match[1]}`,
        ).toBe(false);
      }
    }
  });

  test("the stylesheet and the script fetch nothing from another host", () => {
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });

    for (const file of walk(dist).filter((f) => /\.(css|js)$/.test(f))) {
      const text = readFileSync(file, "utf8");
      // @import and url() in CSS, and fetch/import in JS, are the ways an
      // asset pulls in a third party without the HTML showing it.
      for (const match of text.matchAll(/(?:@import\s+|url\(|fetch\(|import\()["']?(https?:\/\/[^"')\s]+)/g)) {
        expect(false, `${file} contacte ${match[1]}`).toBe(true);
      }
    }
  });

  test("nothing in the build leaks an absolute deploy path", () => {
    // Guards the move off /wisq/: a hardcoded /wisq/ in an asset reference
    // would break the day the site gets its own domain.
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });
    const documents = walk(dist).filter((file) => file.endsWith(".html"));
    expect(documents.length).toBeGreaterThan(0);
    for (const file of documents) {
      const refs = [...readFileSync(file, "utf8").matchAll(/(?:src|href)="(\/[^"]*)"/g)];
      expect(refs.map((match) => match[1]), `${file} : chemin absolu`).toEqual([]);
    }
  });
});
