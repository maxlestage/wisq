import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { LANGS, ROUTES, outputPath, pagePath, routeById } from "../src/routes";
import { PAGES } from "../src/pages";
import { AUTHOR, copy } from "../src/content";
import { siteURL } from "../src/site-url";

/// The built artefact, not the source. `bun run build` must run before this;
/// CI does exactly that.
const dist = join(import.meta.dir, "..", "dist");
const read = (relative: string) => readFileSync(join(dist, relative), "utf8");

/// Every document the build writes: each route, in each language. Tests that
/// used to walk the routes walk this instead, or they check half the site.
const BUILT = LANGS.flatMap((lang) =>
  ROUTES.map((route) => ({ route, lang, file: outputPath(route, lang) })),
);

/// The stylesheet's name is hashed, so tests that read the CSS have to find it
/// rather than assume it.
function styleFile(): string {
  const name = readdirSync(dist).find((entry) => entry.endsWith(".css"));
  if (!name) throw new Error("aucune feuille de style dans dist");
  return name;
}

/// The script's name is hashed too, for the same reason.
function scriptFile(): string {
  const name = readdirSync(dist).find((entry) => entry.endsWith(".js") && entry !== "sw.js");
  if (!name) throw new Error("aucun script dans dist");
  return name;
}

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

  /// React ships two builds behind one import, and the development one is what
  /// you get unless the bundler is told otherwise. It carries every warning,
  /// every key check and every hook invariant: 479 KB against 268 KB, 147 KB
  /// against 88 KB over the wire, and slower on every render. The site was
  /// publishing it, because the deploy job runs `bun run build` with no
  /// environment set and nothing in the build said which build to make.
  ///
  /// These two strings exist only in the development build — the branches that
  /// print them are compiled out of the production one.
  test("the published script is React's production build", () => {
    const script = read(scriptFile());
    for (const marker of ["Each child in a list should have a unique", "captureOwnerStack"]) {
      expect(script.includes(marker), `le bundle contient « ${marker} »`).toBe(false);
    }
  });

  /// The stronger claim, and the one that keeps the budget below honest: React
  /// is not in the shipped script at all.
  ///
  /// The pages are pre-rendered, so React's only remaining job was hydrating
  /// four behaviours — a redirect, a remembered language, the theme switch, the
  /// install banner — for 65 794 bytes gzipped. They are plain DOM code now.
  /// This fails the moment something imports a component into `main.ts`, which
  /// is the one mistake that would silently put all of it back.
  test("the shipped script contains no React", () => {
    const script = read(scriptFile());
    for (const marker of ["createElement", "useState", "react", "React"]) {
      expect(script.includes(marker), `le bundle contient « ${marker} »`).toBe(false);
    }
  });

  /// Not a style rule: a phone on a slow link pays for every one of these
  /// bytes before the page becomes interactive. The ceiling sits a little above
  /// what the bundle weighs today, so ordinary work does not trip it and a
  /// doubling does. Gzip is what a visitor actually downloads; the raw figure
  /// is what their phone has to parse, and both matter.
  test("the script stays within its budget", () => {
    const bytes = readFileSync(join(dist, scriptFile()));
    const gzipped = Bun.gzipSync(bytes).byteLength;
    // The ceiling was 240 000 raw and 80 000 gzipped, which is what a hydrating
    // React bundle needs. With hydration gone the script is 2 350 raw and 1 062
    // gzipped, so a ceiling anywhere near the old one would wave through the
    // regression it exists to catch: re-importing a component into `main.ts`
    // costs sixty-four kilobytes and would have passed. These sit a little above
    // today's figures — room for ordinary work, none for React.
    expect(bytes.byteLength, "script brut").toBeLessThan(8_000);
    expect(gzipped, "script gzippé").toBeLessThan(3_000);
  });

  /// The point of moving the documents into the pages: the shared script is the
  /// site's behaviour, not its prose.
  ///
  /// A reader on the landing page used to download the privacy policy, the FAQ,
  /// the roadmap and the architecture note, in English *and* French — 61 KB raw,
  /// 21.6 KB over the wire, measured. This walks the real documents and fails if
  /// a sentence from any of them is back in the bundle.
  test("the shared script carries no page's prose", () => {
    const script = read(scriptFile());
    for (const lang of LANGS) {
      for (const route of ROUTES) {
        if (route.id === "home") continue;
        const doc = PAGES[lang][route.id as keyof (typeof PAGES)["en"]];
        const sentence = doc.blocks.find(
          (block): block is { kind: "p"; text: string } =>
            block.kind === "p" && block.text.length > 40,
        )?.text;
        if (!sentence) continue;
        expect(
          script.includes(sentence.slice(0, 40)),
          `${route.id}/${lang} : la prose est repartie dans le bundle`,
        ).toBe(false);
      }
    }
  });

  /// The two tests that stood here guarded the JSON copy of each document,
  /// embedded beside the markup because hydration had to read exactly what the
  /// build rendered — one that it round-tripped, one that no `<` in the prose
  /// could end its script element early. Nothing hydrates, so the payload has
  /// no reader and is gone, and with it both hazards.
  ///
  /// What replaces them is the claim the payload existed to support, checked
  /// against the markup that now carries it alone: the words are in the page.
  /// Deleting the two tests without this one would have left the prose
  /// unguarded on the very change that moved it.
  test("every written page carries its prose in its markup", () => {
    for (const { route, lang, file } of BUILT) {
      if (route.id === "home") continue;
      const html = read(file);
      const doc = PAGES[lang][route.id as keyof (typeof PAGES)["en"]];
      const sentence = doc.blocks.find(
        (block): block is { kind: "p"; text: string } =>
          block.kind === "p" && block.text.length > 40,
      )?.text;
      if (!sentence) continue;
      // The prose goes through React's escaper, which turns `'` into `&#x27;`
      // among others — and French prose is full of apostrophes, so the raw
      // sentence is not in the file verbatim. The longest run that contains
      // nothing an escaper touches is, and it is still long enough that no
      // other page could contain it by accident.
      const plain = sentence
        .split(/[<>&"']/)
        .reduce((longest, part) => (part.length > longest.length ? part : longest), "");
      if (plain.length < 20) continue;
      expect(html.includes(plain), `${file} : la prose n'est pas dans le balisage`).toBe(true);
    }
  });

  /// And the payload is really gone, on every page, rather than gone from the
  /// one page someone happened to open.
  test("no page ships a document payload any more", () => {
    for (const { file } of BUILT) {
      expect(
        read(file).includes('<script type="application/json" id="doc">'),
        `${file} : le document JSON est revenu`,
      ).toBe(false);
    }
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
    expect(home).toContain("A real Linux kernel, on the phone");

    const privacy = read("privacy/index.html");
    expect(privacy).toContain("No analytics");
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
  /// Where each size of the mark belongs. The hero lockup — mark plus the name
  /// set large — is the landing page's alone, because no other page has that
  /// room. The footer carries the mark small on every page, beside the
  /// wordmark, so the pair is what a reader sees wherever they end up.
  test("the hero lockup is the landing page's, the footer mark is everywhere", () => {
    for (const { route, file } of BUILT) {
      const html = read(file);
      const hero = html.split('class="hero-logo"').length - 1;
      expect(hero, `${file} : marque du hero`).toBe(route.id === "home" ? 1 : 0);
      expect(
        html.split('class="footer-logo"').length - 1,
        `${file} : marque du pied de page`,
      ).toBe(1);
      expect(html, `${file} : mot-marque`).toContain('class="brand');
    }
  });

  /// Two copies of the same drawing on one page means two elements sharing an
  /// id, which is invalid and resolves to whichever came first. Harmless while
  /// the gradients are identical, and a silent wrong-colour bug the day they
  /// are not.
  test("two marks on a page do not share an id", () => {
    const ids = [...read("index.html").matchAll(/id="(wisq-[^"]+)"/g)].map((m) => m[1]!);
    expect(ids.length, "l'accueil porte deux marques, donc six identifiants").toBe(6);
    expect(new Set(ids).size, "identifiant dupliqué entre les deux marques").toBe(ids.length);
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

describe("theme", () => {
  /// The guard that makes an explicit choice mean anything. Without
  /// `:not([data-theme="light"])` a reader whose system is dark and who asked
  /// for light keeps the media query's colours — the switch appears to work in
  /// one direction and silently fails in the other, which is the kind of
  /// half-working nobody reports.
  test("an explicit choice outranks the system setting, both ways", () => {
    // Read with the quotes optional: the minifier drops them, so asserting the
    // source spelling would test the bundler rather than the behaviour.
    const css = readFileSync(join(dist, styleFile()), "utf8");
    expect(css, "la requête média doit céder à un choix explicite").toMatch(
      /:root:not\(\[data-theme=["']?light["']?\]\)/,
    );
    expect(css, "le choix sombre doit exister hors requête média").toMatch(
      /:root\[data-theme=["']?dark["']?\]/,
    );
    // ...and the dark tokens must really be in both places, not just selected.
    const media = css.slice(css.indexOf("prefers-color-scheme:dark"));
    expect(media, "la requête média doit porter les couleurs sombres").toContain("--bg:#0b0d10");
  });

  /// An effect runs after the page has painted, so the theme cannot come from
  /// React: a reader who chose light on a dark system would see a flash of
  /// dark on every navigation.
  test("the theme is applied before the first paint, on every page", () => {
    for (const { file } of BUILT) {
      const html = read(file);
      const head = html.slice(0, html.indexOf("</head>"));
      expect(head, `${file} : script de thème absent de la tête`).toContain("wisq.theme");
      expect(head, `${file} : le script doit poser data-theme`).toContain("data-theme");
    }
  });

  /// Inline and dependency-free on purpose: it must not wait for the bundle,
  /// and it must not be able to fail to load.
  test("the theme script is inline and cannot fail to load", () => {
    const head = read("index.html").slice(0, read("index.html").indexOf("</head>"));
    const script = head.match(/<script>[^<]*wisq\.theme[\s\S]*?<\/script>/)?.[0];
    expect(script, "le script de thème doit être en ligne").toBeDefined();
    expect(script).not.toContain("src=");
    expect(script, "il doit échouer sans bruit plutôt que casser la page").toContain("catch");
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
      expect(html, `${file} : vie privée`).toContain(
        `>${escape(copy[lang].pages.privacy)}</a>`,
      );
      expect(html, `${file} : retour en haut`).toContain(`>${escape(footer.backToTop)}</a>`);
      expect(html, `${file} : version`).toContain(`${escape(footer.version)} `);
      // These two are here because they were once removed and nothing said
      // so. Taking the licence out of the footer took the end of the version
      // line and one of the three items in the legal row with it, and the
      // build stayed green while the footer visibly thinned. A footer is
      // checked line by line or it is not checked.
      expect(html, `${file} : droits`).toContain(escape(footer.rights));
      expect(html, `${file} : copyright`).toContain(escape(footer.copyright));
    }
  });

  /// The site used to announce a licence in the badge, in the comparison table
  /// and twice in the footer. None had been chosen — it was inherited from a
  /// template and nobody had picked it, which makes it a claim about what
  /// someone may do with this code, published without anyone deciding it.
  ///
  /// So the guard is inverted: naming a licence here has to fail until there
  /// is one to name. When there is, this test is the place that says so, and
  /// changing it is a deliberate act rather than a copy edit.
  test("no page claims a licence for wisq", () => {
    // GPL is allowed: it appears as a fact about QEMU, which is somebody
    // else's project and really is under it.
    //
    // The URL forms are in the list because of where the first one hid: the
    // visible page had been cleaned while the JSON-LD block still carried
    // `"license": "https://www.apache.org/licenses/LICENSE-2.0"` — the
    // machine-readable claim, which is the one a search engine repeats.
    const claims = [
      "Apache-2.0",
      "Apache 2.0",
      "MIT License",
      "Licence MIT",
      "BSD-",
      "apache.org/licenses",
      "opensource.org/licenses",
      "\"license\"",
    ];
    for (const { file } of BUILT) {
      const html = read(file);
      for (const claim of claims) {
        expect(html, `${file} annonce « ${claim} »`).not.toContain(claim);
      }
    }
  });

  /// On every page, in both languages, and naming the same person the
  /// repository's own copyright line names — a site that credits someone the
  /// repository does not is a site making a claim nothing backs.
  ///
  /// It used to read that line out of LICENSE. There is no LICENSE now: none
  /// had been chosen, and a file granting rights nobody decided to grant is
  /// worse than no file. NOTICE still carries the copyright holder, and so
  /// does the README, so the check moved there rather than being dropped —
  /// the claim it guards is about authorship, which did not change.
  test("every page says who made it, and agrees with the repository", () => {
    for (const { lang, file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : ligne d'auteur`).toContain(copy[lang].footer.author);
      expect(html, `${file} : nom de l'auteur`).toContain(`>${AUTHOR}</a>`);
      expect(html, `${file} : meta author`).toContain(`<meta name="author" content="${AUTHOR}" />`);
    }
    const repoRoot = join(dist, "..", "..");
    expect(
      readFileSync(join(repoRoot, "NOTICE"), "utf8"),
      "NOTICE doit nommer le même titulaire",
    ).toContain(`Copyright 2026 ${AUTHOR}`);
    for (const file of ["README.md", "README.fr.md"]) {
      expect(
        readFileSync(join(repoRoot, file), "utf8"),
        `${file} doit nommer le même titulaire`,
      ).toContain(`Copyright 2026 ${AUTHOR}`);
    }
  });

  /// Saying what is mine must not quietly stop saying what is not. The
  /// third-party credit is the thing most easily lost when an author line is
  /// added next to it.
  test("crediting the author does not displace the credit to others", () => {
    // The credited name and work, rather than the sentence around them: the
    // sentence differs per language and its apostrophes come out escaped.
    for (const { file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : auteur crédité`).toContain("Charles Lohr");
      expect(html, `${file} : travail crédité`).toContain("mini-rv32ima");
    }
    const notice = readFileSync(join(dist, "..", "..", "NOTICE"), "utf8");
    expect(notice, "NOTICE doit garder la provenance mini-rv32ima").toContain("Charles Lohr");
    expect(notice, "NOTICE doit garder la mention UTM").toContain("UTM");
  });

  /// The site does not present wisq as open source and does not send anyone to
  /// browse its sources. That is a decision about what is published, not a
  /// detail of wording, so it is checked on the built pages rather than left to
  /// whoever next edits the copy: an "open source" badge or a "Source" link
  /// would come back the moment someone added one, and nothing would object.
  ///
  /// The release download survives on purpose — it is how a reader installs the
  /// thing, not an invitation to read the code.
  test("the site neither claims to be open source nor links to its sources", () => {
    const forbidden = [
      "github.com/maxlestage/wisq/blob/",
      "github.com/maxlestage/wisq/tree/",
      "github.com/maxlestage/wisq/issues",
    ];
    for (const { file } of BUILT) {
      const html = read(file);
      expect(html.toLowerCase(), `${file} : revendication « open source »`).not.toContain(
        "open source",
      );
      for (const link of forbidden) {
        expect(html, `${file} : lien vers les sources`).not.toContain(link);
      }
      expect(html, `${file} : lien « Source » nu vers le dépôt`).not.toContain(
        '"https://github.com/maxlestage/wisq"',
      );
    }
  });

  test("the footer's links stay inside the site", () => {
    const html = read("index.html");
    expect(html, "le pied de page doit mener à la page vie privée").toContain('href="./privacy/"');
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

  /// **These read `sw.js` as text.** That is deliberate and it is not enough:
  /// they check that the built worker names the right files and contains the
  /// right guards, which catches a build that stopped emitting something. What
  /// they cannot see is behaviour — measured, by breaking nine of the worker's
  /// behaviours in ways that left every string below intact, and watching all
  /// nine pass the whole suite. `tests/service-worker.test.ts` runs the worker
  /// instead, and is where a change to what it *does* gets caught.
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
          `${siteURL()}${pagePath(route, lang)}</loc>`,
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
    // And it can still navigate. With one page left, home is the whole of it —
    // a dead end is not a 404 page.
    expect(html).toContain('class="brand"');
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
