/// Builds the site: one pre-rendered document per address, the WebAssembly
/// front that hydrates two islands of it and moves the rest, and everything a
/// browser needs to install it.
///
/// **There is no React here any more, and no JavaScript of the site's own.**
/// Every page is rendered by `crates/wisq-site` — Yew components, server-side
/// rendered by its `wisq-site-prerender` binary — and every behaviour runs in
/// the WebAssembly module the same crate compiles. What is left in this file is
/// the plumbing around them: the stylesheet and its font, the Rust toolchain
/// calls, content-addressed names, and the files a static host and a service
/// worker need.
///
/// Every path this emits is relative. That was written when the site was served
/// from /wisq/ on GitHub Pages, against the day it moved to the root of a
/// domain — an absolute /asset.js works in exactly one of those. The day came:
/// it is served from the root on Heroku, and nothing had to be rewritten.

import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { appIcon, socialCard } from "./scripts/icons";
import { siteURL } from "./src/site-url";

const outdir = "dist";
const SITE_URL = siteURL();

await rm(outdir, { recursive: true, force: true });

// Step one: let Bun bundle and hash the stylesheet. The HTML it emits is thrown
// away — what is wanted from it is the asset's name. `src/index.html` is only
// the entry point that tells Bun where the stylesheet is: it carries no script,
// because the site's behaviour is the WebAssembly module, not a bundle.
const result = await Bun.build({
  entrypoints: ["src/index.html"],
  outdir,
  minify: true,
  publicPath: "./",
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

const bundled = await Bun.file(join(outdir, "index.html")).text();
const styleName = bundled.match(/<link[^>]+rel="stylesheet"[^>]+href="\.\/([^"]+)"/)?.[1];
if (!styleName) {
  console.error("la feuille de style est introuvable dans le HTML construit");
  process.exit(1);
}
// **Aucun script ne doit sortir du bundler**, et c'est une garde, pas un
// constat. Le comportement du site est dans le module wasm ; du JavaScript émis
// ici voudrait dire qu'un script a été rattaché à `src/index.html`, et qu'il
// partirait chez chaque lecteur sans qu'aucune page ne le charge.
//
// Bun émet quand même un `chunk-<empreinte>.js` **vide** pour toute entrée HTML,
// script ou pas — mesuré, 0 octet. Celui-là est retiré ; un seul octet de plus
// est un refus.
for (const output of result.outputs.filter((o) => o.path.endsWith(".js"))) {
  if (output.size > 0) {
    console.error(`le bundler a émis du JavaScript (${output.path}, ${output.size} octets) : rien ne le charge`);
    process.exit(1);
  }
  await rm(output.path);
}

// The variable font travels as its own file, and getting it there takes a
// substitution rather than a flag.
//
// Bun turns every `url()` in a stylesheet into a base64 data URI, and
// `loader: { ".woff2": "file" }` does not change that — tried, measured, the
// data URI came back. For a dev server that is the right behaviour. For the
// published site it is not: the stylesheet is a render-blocking `<link>` in the
// head, so inlining moved 90 KB of font onto the critical path — styles.css
// went from 27 KB to 135 KB — and made `font-display: swap` meaningless,
// because there is nothing to swap when the font arrives inside the thing that
// blocks the paint.
//
// So the one data URI is lifted back out into a content-addressed file, and the
// `url()` is pointed at it. The `url()` is relative to the stylesheet rather
// than to the document, and both sit at the root of the build, so one spelling
// serves every page whatever its depth.
//
// Both halves of that are checked rather than assumed: exactly one font data
// URI must be there, and its bytes must be the font on disk. If Bun ever stops
// inlining — or starts inlining something else — this refuses instead of
// quietly shipping a stylesheet with no font in it and no face to fall back on.
const FONT_SOURCE = "src/archivo-variable-latin.woff2";
const fontBytes = await Bun.file(FONT_SOURCE).bytes();
const fontName = `archivo-variable-latin-${Bun.hash(fontBytes).toString(16)}.woff2`;
const stylePath = join(outdir, styleName);
const styleSource = await Bun.file(stylePath).text();
const inlinedFonts = [...styleSource.matchAll(/url\(data:font\/woff2;base64,([^)]+)\)/g)];
if (inlinedFonts.length !== 1) {
  console.error(
    `la feuille de style porte ${inlinedFonts.length} police en ligne, il en faut exactement une : ` +
      "si Bun a cessé de les intégrer, cette substitution n'a plus d'objet et doit être retirée",
  );
  process.exit(1);
}
if (!Buffer.from(inlinedFonts[0]![1]!, "base64").equals(Buffer.from(fontBytes))) {
  console.error(`la police en ligne n'est pas ${FONT_SOURCE}`);
  process.exit(1);
}
await writeFile(stylePath, styleSource.replace(inlinedFonts[0]![0]!, `url(./${fontName})`));
await writeFile(join(outdir, fontName), fontBytes);

// ---------------------------------------------------------------------------
// Le front en Yew, compilé deux fois.
//
// Deux sorties pour un seul arbre de composants, `crates/wisq-site` :
//
//   - un binaire natif qui rend toutes les pages en HTML (`ServerRenderer`,
//     drapeau `ssr`) et les décrit dans un catalogue JSON ;
//   - un module wasm qui hydrate deux îlots de ce HTML — les réglages de
//     l'en-tête, l'invite d'installation — et anime le reste (drapeau
//     `hydrate`).
//
// **Le profil `wasm-release` n'est pas un détail.** Le profil `release` du
// workspace est taillé pour l'interpréteur de VM : `opt-level = 3`, pour la
// vitesse. Sur un module que chaque visiteur télécharge, c'est le mauvais
// arbitrage ; `wasm-release` passe à `"z"`. Les profils ne se déclarent qu'à la
// racine d'un workspace, donc ce choix vit dans le `Cargo.toml` du haut.
//
// **Et la construction refuse plutôt que de se replier.** Sans la chaîne Rust,
// elle s'arrête en disant quoi installer : il n'y a plus d'autre rendu vers
// lequel se replier, et c'est voulu.
async function lancer(quoi: string, cmd: string[], aide?: string) {
  const run = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
  if (!run.success) {
    console.error(`${quoi} a échoué (${cmd.join(" ")}) :`);
    console.error(new TextDecoder().decode(run.stderr).trimEnd());
    if (aide) console.error(aide);
    process.exit(1);
  }
  return new TextDecoder().decode(run.stdout);
}

const AIDE_RUST = [
  "",
  "Le front du site est en Yew, donc sa construction demande la chaîne Rust :",
  "",
  "    ./scripts/install-wasm-toolchain.sh   # la cible wasm32 et wasm-bindgen, à la version du verrou",
  "    bun install                           # fournit wasm-opt, par binaryen",
  "",
].join("\n");

await lancer(
  "la construction du pré-rendu",
  ["cargo", "build", "--release", "-p", "wisq-site"],
  AIDE_RUST,
);
await lancer(
  "la construction du wasm",
  [
    "cargo", "build", "--profile", "wasm-release", "--target", "wasm32-unknown-unknown",
    "-p", "wisq-site", "--no-default-features", "--features", "hydrate",
  ],
  AIDE_RUST,
);

// wasm-bindgen écrit le module et sa colle ; `--target web` donne un module ES
// dont l'export par défaut démarre le tout, et qui résout le `.wasm` par
// rapport à sa propre adresse — donc une seule orthographe sert les pages de
// toutes les profondeurs.
const wasmOut = join(outdir, "wasm");
await lancer(
  "wasm-bindgen",
  [
    "wasm-bindgen", "--target", "web", "--no-typescript", "--out-dir", wasmOut,
    "--out-name", "wisq", "../target/wasm32-unknown-unknown/wasm-release/wisq_site.wasm",
  ],
  AIDE_RUST,
);

// `wasm-opt -Oz` : mesuré, 210 334 octets avant, 188 859 après sur la première
// sonde — une passe qui ne change rien au comportement.
const wasmOpt = "node_modules/binaryen/bin/wasm-opt";
await lancer(
  "wasm-opt",
  [wasmOpt, "-Oz", "--enable-bulk-memory", "--enable-nontrapping-float-to-int",
   join(wasmOut, "wisq_bg.wasm"), "-o", join(wasmOut, "wisq_bg.wasm")],
  AIDE_RUST,
);

// Les deux fichiers prennent un nom adressé par leur contenu, comme la feuille
// de style, et entrent dans la liste des immuables : un nom qui change avec les
// octets ne peut pas être périmé.
const wasmBytes = await Bun.file(join(wasmOut, "wisq_bg.wasm")).bytes();
const glueSource = await Bun.file(join(wasmOut, "wisq.js")).text();
const wasmName = `wisq-${Bun.hash(wasmBytes).toString(16)}.wasm`;
// La colle nomme le `.wasm` qu'elle charge, donc son propre nom doit dépendre
// des deux : sinon un changement de wasm laisserait une colle au nom inchangé
// pointant sur un fichier disparu, et le cache d'un visiteur servirait une
// colle orpheline.
const glue = glueSource.replace("wisq_bg.wasm", wasmName);
const glueName = `wisq-${Bun.hash(glue).toString(16)}.js`;
await writeFile(join(outdir, wasmName), wasmBytes);
await writeFile(join(outdir, glueName), glue);
await rm(wasmOut, { recursive: true, force: true });

// ---------------------------------------------------------------------------
// Le catalogue : toutes les pages, et tout ce qu'il faut savoir pour les
// écrire, en un seul processus.
//
// Ce que ce fichier lisait autrefois dans `src/routes.ts`, `src/content.ts`,
// `src/pages/*.ts` et `src/theme.ts` — la liste des routes, les titres, les
// descriptions, les couleurs de barre, l'auteur — vient maintenant du crate qui
// rend les pages. C'était déjà une copie de ce qu'il déclarait.
interface Route {
  id: string;
  path: string;
  listed: boolean;
  output: string | null;
}
interface Rendered {
  route: string;
  lang: string;
  file: string;
  path: string;
  base: string;
  title: string;
  description: string;
  markup: string;
}
interface Catalogue {
  langs: string[];
  bar: { light: string; dark: string };
  author: string;
  authorUrl: string;
  routes: Route[];
  copy: Record<string, { hero: { lede: string } }>;
  pages: Rendered[];
}
const catalogue: Catalogue = JSON.parse(
  await lancer("le pré-rendu", ["../target/release/wisq-site-prerender"], AIDE_RUST),
);
const { langs: LANGS, bar: BAR, author: AUTHOR, authorUrl: AUTHOR_URL, routes: ROUTES } = catalogue;
if (catalogue.pages.length !== ROUTES.length * LANGS.length) {
  console.error(
    `le pré-rendu a rendu ${catalogue.pages.length} pages pour ${ROUTES.length} routes ` +
      `en ${LANGS.length} langues : il en manque`,
  );
  process.exit(1);
}
const pathOf = (route: Route, lang: string) =>
  catalogue.pages.find((p) => p.route === route.id && p.lang === lang)!.path;

// Les noms que cette construction a tirés d'une empreinte de contenu, écrits
// pour l'hôte. C'est ici qu'on sait lesquels le sont — c'est ici que les noms
// sont composés —, donc c'est ici que la liste s'écrit, et `scripts/serve.ts`
// la lit sur le disque.
const immutable = [styleName, fontName, wasmName, glueName];
await writeFile(
  join(outdir, "immutable.txt"),
  `# Les actifs que cette construction a nommés d'après leur contenu.\n` +
    `# Lu par scripts/serve.ts, qui les sert en « immutable ».\n` +
    `${immutable.join("\n")}\n`,
);

// Assets that every page references, plus the ones only the browser asks for.
const ICONS = [
  { file: "icon-192.png", size: 192, maskable: false },
  { file: "icon-512.png", size: 512, maskable: false },
  { file: "icon-maskable-512.png", size: 512, maskable: true },
  { file: "apple-touch-icon.png", size: 180, maskable: false },
];

for (const icon of ICONS) {
  await writeFile(join(outdir, icon.file), appIcon(icon.size, icon.maskable));
}
await writeFile(join(outdir, "social-card.png"), socialCard());

const MANIFEST = {
  name: "wisq — virtual machines on your iPhone",
  short_name: "wisq",
  description: catalogue.copy.en!.hero.lede,
  // Relative, and resolved against the manifest's own address, so the site
  // stays movable.
  start_url: "./",
  scope: "./",
  display: "standalone",
  orientation: "any",
  // La couleur de l'écran de lancement et celle de la barre : celle du thème
  // sombre, parce que c'est elle que l'icône porte.
  background_color: BAR.dark,
  theme_color: BAR.dark,
  lang: "en",
  categories: ["developer", "utilities"],
  icons: [
    { src: "./icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
    { src: "./icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
    {
      src: "./icon-maskable-512.png",
      sizes: "512x512",
      type: "image/png",
      purpose: "maskable",
    },
  ],
};
await writeFile(join(outdir, "manifest.webmanifest"), JSON.stringify(MANIFEST, null, 2));

function escapeHTML(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/// Applies a stored theme before the first paint.
///
/// This has to be an inline, blocking script in the head: the module arrives
/// after the page has painted, so a reader who chose light on a dark system
/// would see a flash of dark on every navigation. Twelve lines in the head buy
/// that away.
///
/// Kept deliberately dumb — no bundler, no module, no dependency on anything
/// that could fail to load. If it throws, the page is simply on the system
/// theme, which is where it was before this feature existed.
const THEME_SCRIPT = `<script>(function(){try{var t=localStorage.getItem("wisq.theme");if(t!=="light"&&t!=="dark")return;document.documentElement.setAttribute("data-theme",t);var c=t==="dark"?"${BAR.dark}":"${BAR.light}";var m=document.querySelectorAll('meta[name="theme-color"]');for(var i=0;i<m.length;i++){m[i].content=c;}}catch(e){}})();</script>`;

/// **L'entrée et le rideau, décidés avant le premier pixel.**
///
/// Deux classes sur `<html>`, et c'est la seule chose que la page fasse avant
/// que le module n'arrive :
///
///   - `entree` : le titre de l'accueil monte mot par mot, puis l'accroche. Ce
///     sont des animations CSS qui **s'achèvent d'elles-mêmes** — un module qui
///     n'arrive jamais ne laisse rien de caché —, donc elles peuvent partir dès
///     la première peinture, ce que le module, qui arrive après elle, ne peut
///     pas faire sans un éclair : le titre peint, puis masqué, puis rejoué.
///   - `rideau` : une fois par session, la page s'ouvre derrière un rideau qui
///     porte la marque, comme celle de la référence. Un pseudo-élément, pas un
///     nœud : rien à ajouter au DOM. Décidé ici, parce qu'un rideau posé plus
///     tard laisserait d'abord voir la page qu'il est censé cacher.
///
/// Ni l'une ni l'autre si la personne a demandé moins d'animation. Et comme le
/// script du thème : un refus du stockage, une erreur, et la page est
/// simplement immobile.
const ENTREE_SCRIPT = `<script>(function(){try{if(matchMedia("(prefers-reduced-motion: reduce)").matches)return;var d=document.documentElement;d.classList.add("entree");if(!sessionStorage.getItem("wisq.rideau")){sessionStorage.setItem("wisq.rideau","1");d.classList.add("rideau");}}catch(e){}})();</script>`;

function documentFor(page: Rendered): string {
  const { base, lang } = page;
  const isHome = page.route === "home";
  const canonical = `${SITE_URL}${page.path}`;
  const route = ROUTES.find((r) => r.id === page.route)!;

  // Every page says where its other language lives, and which one a reader
  // with no preference should get. Without this a search engine treats the two
  // as unrelated documents and picks one of them to show everybody.
  const alternates = [
    ...LANGS.map(
      (code) =>
        `\n    <link rel="alternate" hreflang="${code}" href="${SITE_URL}${pathOf(route, code)}" />`,
    ),
    `\n    <link rel="alternate" hreflang="x-default" href="${SITE_URL}${pathOf(route, "en")}" />`,
  ].join("");

  // Structured data on the landing pages only: repeating it on every document
  // tells a search engine there are seven applications rather than one.
  const jsonLd = isHome
    ? `\n    <script type="application/ld+json">${JSON.stringify({
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        name: "wisq",
        applicationCategory: "DeveloperApplication",
        operatingSystem: "iOS 17+",
        description: page.description,
        url: canonical,
        inLanguage: lang,
        author: { "@type": "Person", name: AUTHOR, url: AUTHOR_URL },
        // No `license` key: schema.org's is the machine-readable version of
        // the claim, the one a search engine reads and repeats, and there is
        // no licence to declare. It goes back when one is chosen.
        isAccessibleForFree: true,
        offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      })}</script>`
    : "";

  // **Le module est demandé tôt.** La colle et le wasm ont des noms adressés
  // par leur contenu, donc la page peut les nommer dans sa tête : le
  // navigateur les cherche pendant qu'il analyse le corps, au lieu d'attendre
  // que la colle s'exécute pour découvrir le wasm. `crossorigin` sur le
  // préchargement du wasm, parce que la colle le demande par `fetch` en mode
  // `cors` ; sans lui, le navigateur jette le préchargement et recommence.
  return `<!doctype html>
<html lang="${lang}">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <title>${escapeHTML(page.title)}</title>
    <meta name="description" content="${escapeHTML(page.description)}" />
    <meta name="author" content="${escapeHTML(AUTHOR)}" />
    <link rel="canonical" href="${canonical}" />${alternates}
    <meta name="theme-color" content="${BAR.dark}" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="${BAR.light}" media="(prefers-color-scheme: light)" />
    <meta property="og:title" content="${escapeHTML(page.title)}" />
    <meta property="og:description" content="${escapeHTML(page.description)}" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="${canonical}" />
    <meta property="og:image" content="${SITE_URL}social-card.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <link rel="manifest" href="${base}manifest.webmanifest" />
    <link rel="apple-touch-icon" href="${base}apple-touch-icon.png" />
    <meta name="apple-mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-title" content="wisq" />
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>▚</text></svg>" />
    <link rel="stylesheet" href="${base}${styleName}" />
    <link rel="modulepreload" href="${base}${glueName}" />
    <link rel="preload" href="${base}${wasmName}" as="fetch" type="application/wasm" crossorigin />${jsonLd}
    ${THEME_SCRIPT}
    ${ENTREE_SCRIPT}
  </head>
  <body>
    <div id="root" data-route="${page.route}" data-lang="${lang}" data-base="${base}">${page.markup}</div>
    <script type="module">import demarrer from "${base}${glueName}";demarrer();</script>
  </body>
</html>
`;
}

const written: string[] = [];
for (const page of catalogue.pages) {
  const target = join(outdir, page.file);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, documentFor(page));
  written.push(page.file);
}

// The service worker precaches exactly what this build produced. Hashed asset
// names mean the list changes only when the content does, which is also what
// makes the cache version below stable across rebuilds of the same source.
const precache = [
  // Both languages: a reader who installed the French site and lost the
  // network should get the French site back, not an English fallback.
  ...LANGS.flatMap((lang) =>
    ROUTES.filter((route) => !route.output).map((route) => `./${pathOf(route, lang)}`),
  ),
  `./${styleName}`,
  // The font is in the list for the same reason the stylesheet is: a reader
  // offline would otherwise get the page in the fallback sans, which is a
  // different design.
  `./${fontName}`,
  // Le front, et **la garde l'a nommé avant un lecteur** quand il est arrivé :
  // hors ligne, une page se serait affichée depuis le cache, puis n'aurait
  // jamais hydraté ses îlots, faute de pouvoir chercher son module. Une page
  // qui s'affiche et ne répond plus est pire qu'une page absente, parce que
  // rien ne la signale.
  `./${wasmName}`,
  `./${glueName}`,
  "./manifest.webmanifest",
  ...ICONS.map((icon) => `./${icon.file}`),
];
const version = Bun.hash(precache.join("|")).toString(16);

const offline = ROUTES.find((r) => r.id === "offline")!;
const serviceWorker = `/// Makes the site openable with no network, and launchable from a Home Screen.
///
/// Two strategies, chosen by what the request is for. A navigation goes to the
/// network first: documentation that is quietly a week stale is worse than a
/// spinner. Everything else — the hashed module, the stylesheet, the icons —
/// comes from the cache first, because a hashed name can never be stale.
const VERSION = "wisq-${version}";
const PRECACHE = ${JSON.stringify(precache, null, 2)};
const OFFLINE = { en: "./${pathOf(offline, "en")}", fr: "./${pathOf(offline, "fr")}" };

/// The offline page in the language of the address that failed, so a reader
/// browsing in French does not fall out of French the moment the network goes.
function offlineFor(url) {
  return new URL(url).pathname.includes("/fr/") ? OFFLINE.fr : OFFLINE.en;
}

self.addEventListener("install", (event) => {
  // Deduplicated: addAll rejects the whole list if two entries resolve to the
  // same URL, and the offline document is also a precached page. A rejected
  // install leaves no worker at all — the site keeps working and simply stops
  // being installable, which is the kind of failure nobody notices.
  const wanted = [...new Set([...PRECACHE, OFFLINE.en, OFFLINE.fr])];
  event.waitUntil(
    caches.open(VERSION).then((cache) => cache.addAll(wanted)).then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== VERSION).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  if (new URL(request.url).origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((response) => {
          // Only a page that actually loaded. Caching whatever came back means
          // a 404 from a mistyped link, or a 500 from a bad deploy, is kept and
          // served from the cache afterwards — including once the site is fine
          // again. The asset branch below has always checked this; navigations
          // did not.
          if (response.ok) {
            const copy = response.clone();
            caches.open(VERSION).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() =>
          caches
            .match(request)
            .then((cached) => cached || caches.match(offlineFor(request.url)))
            .then((fallback) => fallback || Response.error()),
        ),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then(
      (cached) =>
        cached ||
        fetch(request).then((response) => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(VERSION).then((cache) => cache.put(request, copy));
          }
          return response;
        }),
    ),
  );
});
`;
await writeFile(join(outdir, "sw.js"), serviceWorker);

const listed = ROUTES.filter((route) => route.listed);
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${LANGS.flatMap((lang) =>
  listed.map(
    (route) =>
      `  <url><loc>${SITE_URL}${pathOf(route, lang)}</loc>` +
      LANGS.map(
        (other) =>
          `<xhtml:link rel="alternate" hreflang="${other}" href="${SITE_URL}${pathOf(route, other)}"/>`,
      ).join("") +
      `</url>`,
  ),
).join("\n")}
</urlset>
`;
await writeFile(join(outdir, "sitemap.xml"), sitemap);
await writeFile(
  join(outdir, "robots.txt"),
  `User-agent: *\nAllow: /\nSitemap: ${SITE_URL}sitemap.xml\n`,
);

const homeBytes = (await Bun.file(join(outdir, "index.html")).text()).length;
console.log(
  `site construit : ${written.length} pages pré-rendues, accueil ${(homeBytes / 1024).toFixed(1)} Kio`,
);
console.log(`  ${written.join(", ")}`);
console.log(`  PWA : manifest, ${ICONS.length} icônes, service worker ${version}`);
console.log(`  langues : ${LANGS.join(", ")} — ${written.length / LANGS.length} pages chacune`);
// **Les quatre chiffres, pas deux — et c'est ce qui manquait.**
//
// Le budget de `tests/build.test.ts` tient quatre bornes : le module et la
// colle, brut et gzippé. Cette ligne n'en imprimait qu'une, et les trois autres
// n'étaient lisibles que sur la machine qui construit. #339 a mesuré **308
// octets d'écart** sur le module entre le coureur de la CI et un conteneur, aux
// deux commits essayés — et n'a rien pu dire de la colle, dont les deux bornes
// ont pourtant la plus petite marge (1 131 et 1 237 octets). Le chiffre existait
// ici, à cet instant ; le jeter obligeait à deviner.
//
// C'est la onzième façon de se tromper du JOURNAL, celle que l'en-tête de
// `check-agent-size.sh` nomme pour le démon : un instrument qui connaît la
// réponse à une question que le dépôt pose ailleurs, sans savoir qu'il la pose.
//
// **Et la version de Bun est imprimée avec, parce que le chiffre gzip en
// dépend.** Mesuré, le même fichier et le même appel `Bun.gzipSync` :
// **118 716 octets sous Bun 1.4.2, 117 620 sous 1.3.11** — 1 096 octets qui
// viennent de l'outil et pas de l'entrée. Le `gzip -9` du système en donne un
// troisième, 117 213. Un chiffre gzip sans son outil n'est donc pas comparable à
// un autre chiffre gzip, et c'est exactement l'erreur que #339 a commise : deux
// `bun` sur un même PATH, et un écart de compresseur lu comme un écart de
// machine.
//
// **Ce n'est pas une garde**, et la suite n'en fait pas une : elle ne peut
// asserter que des bornes, puisqu'un chiffre exact serait rouge sur une machine
// ou sur l'autre. C'est une mesure, déposée dans le journal du coureur pour
// qu'on puisse l'y lire — et qui se nomme assez pour être comparable.
const gzip = (octets: Uint8Array) => Bun.gzipSync(octets).byteLength;
const glueBytes = new TextEncoder().encode(glue);
console.log(
  `  front : ${wasmName} (${wasmBytes.byteLength} octets, ${gzip(wasmBytes)} gzip)`
    + `, ${glueName} (${glueBytes.byteLength} octets, ${gzip(glueBytes)} gzip)`
    + ` — gzip de Bun ${Bun.version}`,
);
