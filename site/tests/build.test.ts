import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { ROUTES, outputPath } from "../src/routes";

/// The built artefact, not the source. `bun run build` must run before this;
/// CI does exactly that.
const dist = join(import.meta.dir, "..", "dist");
const read = (relative: string) => readFileSync(join(dist, relative), "utf8");

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
    for (const route of ROUTES) {
      const file = outputPath(route);
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
    for (const route of ROUTES) {
      const file = outputPath(route);
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
    for (const route of ROUTES) {
      const file = outputPath(route);
      const html = read(file);
      expect(html, `${file} : viewport`).toContain("width=device-width");
      expect(html, `${file} : viewport-fit`).toContain("viewport-fit=cover");
      expect(html, `${file} : canonical`).toContain('rel="canonical"');
      expect(html, `${file} : manifeste`).toContain('rel="manifest"');
      expect(html, `${file} : icône iOS`).toContain('rel="apple-touch-icon"');
      expect(html, `${file} : image sociale`).toContain('property="og:image"');
      expect(html, `${file} : description`).toMatch(/<meta name="description" content="[^"]{40,}"/);
    }
  });

  test("each page has its own title and description", () => {
    const titles = new Set<string>();
    const descriptions = new Set<string>();
    for (const route of ROUTES) {
      const html = read(outputPath(route));
      titles.add(html.match(/<title>([^<]+)<\/title>/)![1]!);
      descriptions.add(html.match(/<meta name="description" content="([^"]+)"/)![1]!);
    }
    // 404 borrows nothing from another page; every route is distinct.
    expect(titles.size).toBe(ROUTES.length);
    expect(descriptions.size).toBe(ROUTES.length);
  });

  test("hydration knows which page it is on", () => {
    for (const route of ROUTES) {
      const html = read(outputPath(route));
      expect(html, `${outputPath(route)} : route`).toContain(`data-route="${route.id}"`);
      expect(html, `${outputPath(route)} : base`).toMatch(/data-base="\.\.?\/"/);
    }
  });

  test("structured data appears once, on the landing page", () => {
    const withJsonLd = ROUTES.filter((route) =>
      read(outputPath(route)).includes("application/ld+json"),
    );
    expect(withJsonLd.map((route) => route.id)).toEqual(["home"]);
  });
});

describe("footer", () => {
  /// A footer is where someone goes when the page did not answer them. It is
  /// on every page or it is not a footer, so this checks every page rather
  /// than the landing one.
  test("every page carries the whole footer", () => {
    for (const route of ROUTES) {
      const file = outputPath(route);
      const html = read(file);
      for (const heading of ["Product", "Documentation", "Project"]) {
        expect(html, `${file} : groupe ${heading}`).toContain(`>${heading}</h2>`);
      }
      for (const label of ["Install", "Issues", "Contributing", "Security", "Changelog"]) {
        expect(html, `${file} : lien ${label}`).toContain(`>${label}</a>`);
      }
      expect(html, `${file} : confidentialité`).toContain(">Privacy</a>");
      expect(html, `${file} : retour en haut`).toContain(">Back to top</a>");
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

  test("the service worker has an offline fallback that was built", () => {
    expect(read("sw.js")).toContain('const OFFLINE = "./offline/"');
    expect(existsSync(join(dist, "offline", "index.html"))).toBe(true);
  });

  test("the cache is versioned, so an old one cannot outlive a deploy", () => {
    const sw = read("sw.js");
    expect(sw).toMatch(/const VERSION = "wisq-[0-9a-f]+"/);
    expect(sw).toContain("caches.delete");
  });
});

describe("discoverability", () => {
  test("the sitemap lists every page meant to be found, and nothing else", () => {
    const sitemap = read("sitemap.xml");
    const listed = ROUTES.filter((route) => route.listed);
    for (const route of listed) {
      expect(sitemap, `${route.id} absent du sitemap`).toContain(
        route.path ? `${route.path}/</loc>` : "/</loc>",
      );
    }
    expect([...sitemap.matchAll(/<loc>/g)].length).toBe(listed.length);
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
