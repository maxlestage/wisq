/// Builds the site: one bundle, one pre-rendered document per address, and
/// everything a browser needs to install it.
///
/// A landing page that needs 400 KB of JavaScript before showing a word is the
/// opposite of mobile-first. Rendering at build time means the content paints
/// on the first response; React then hydrates it for the language switch, the
/// install tabs and the Home Screen prompt.
///
/// Every path this emits is relative. That was written when the site was served
/// from /wisq/ on GitHub Pages, against the day it moved to the root of a
/// domain — an absolute /asset.js works in exactly one of those. The day came:
/// it is served from the root on Heroku, and nothing had to be rewritten.

import { renderToString } from "react-dom/server";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { App } from "./src/App";
import { AUTHOR, AUTHOR_URL, copy } from "./src/content";
import { PAGES } from "./src/pages";
import {
  LANGS,
  ROUTES,
  outputPath,
  pagePath,
  relativeBase,
  type Route,
} from "./src/routes";
import type { Lang } from "./src/content";
import { appIcon, socialCard } from "./scripts/icons";
import { siteURL } from "./src/site-url";
import { BAR } from "./src/theme";

const outdir = "dist";
const SITE_URL = siteURL();

await rm(outdir, { recursive: true, force: true });

// Step one: let Bun bundle and hash the script and stylesheet. The HTML it
// emits is thrown away — what is wanted from it is the asset names.
//
// `NODE_ENV` is defined here rather than left to whoever runs the build, and
// that is not a tidiness preference. React ships two builds behind one import:
// the development one carries every warning, every key check and every hook
// invariant, and it is the one you get unless something says otherwise. A
// deploy job that runs `bun run build` with no environment set was publishing
// it — 479 KB against 268 KB, 147 KB against 88 KB over the wire, and slower
// on every render besides. A build that produces a different artefact
// depending on the shell it was started from is a build with a bug, so the
// value is written down here and `assertProductionBundle` below refuses to
// ship anything that still smells of the development build.
const result = await Bun.build({
  entrypoints: ["src/index.html"],
  outdir,
  minify: true,
  publicPath: "./",
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

const bundled = await Bun.file(join(outdir, "index.html")).text();
const scriptName = bundled.match(/<script[^>]+src="\.\/([^"]+)"/)?.[1];
const styleName = bundled.match(/<link[^>]+rel="stylesheet"[^>]+href="\.\/([^"]+)"/)?.[1];
if (!scriptName || !styleName) {
  console.error("le script ou la feuille de style est introuvable dans le HTML construit");
  process.exit(1);
}

// A production React build has no warning text in it, because the branches that
// would print it are compiled out. Two strings that only the development build
// contains, checked against the bundle that is about to be published.
//
// This is here rather than only in the tests because it guards the artefact, not
// the source: the mistake it catches is an environment producing a different
// bundle from the same code, and by the time a test runs, the bundle is already
// whatever it is. The tests check it too — belt and braces on the one thing that
// silently doubles what every visitor downloads.
const DEVELOPMENT_MARKERS = ["Each child in a list should have a unique", "captureOwnerStack"];
const script = await Bun.file(join(outdir, scriptName)).text();
const found = DEVELOPMENT_MARKERS.filter((marker) => script.includes(marker));
if (found.length > 0) {
  console.error(
    `le bundle est celui de développement (${found.join(", ")}) : ` +
      "React n'a pas été compilé en production",
  );
  process.exit(1);
}

// The variable font travels as its own file, and getting it there takes a
// substitution rather than a flag.
//
// Bun 1.3.11 turns every `url()` in a stylesheet into a base64 data URI, and
// `loader: { ".woff2": "file" }` does not change that — tried, measured, the
// data URI came back. For the dev server that is the right behaviour and
// nothing has to be done. For the published site it is not: the stylesheet is
// a render-blocking `<link>` in the head, so inlining moved 90 KB of font onto
// the critical path — styles.css went from 27 KB to 135 KB — and made
// `font-display: swap` meaningless, because there is nothing to swap when the
// font arrives inside the thing that blocks the paint.
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
// Le front en Yew, compilé en WebAssembly.
//
// Deux sorties pour un seul arbre de composants, `crates/wisq-site` :
//
//   - un binaire natif qui rend les pages en HTML (`ServerRenderer`, drapeau
//     `ssr`), exactement ce que `renderToString` fait pour React juste en bas ;
//   - un module wasm qui reprend ce HTML dans le navigateur et lui rattache les
//     comportements (drapeau `hydrate`).
//
// **Le profil `wasm-release` n'est pas un détail.** Le profil `release` du
// workspace est taillé pour l'interpréteur de VM : `opt-level = 3`, pour la
// vitesse. Sur un bundle que chaque visiteur télécharge, c'est le mauvais
// arbitrage ; `wasm-release` passe à `"z"`. Les profils ne se déclarent qu'à la
// racine d'un workspace, donc ce choix vit dans le `Cargo.toml` du haut.
//
// **Ce que ça coûte, mesuré.** 188 859 octets de wasm après `wasm-opt -Oz`,
// soit 80 196 gzippés, plus 6 163 gzippés de colle. Le code DOM de `main.ts`
// en coûtait 1 062. Le chiffre est dans `tests/build.test.ts`, avec son
// plafond, pour qu'une dérive se voie.
//
// **Et la construction refuse plutôt que de se replier.** Sans la chaîne Rust,
// elle s'arrête en disant quoi installer. Se replier sur React en silence
// publierait un site qui a l'air de marcher et qui n'est pas celui qu'on
// croyait construire — le défaut de conception que ce dépôt refuse par-dessus
// tout.
const FRONT = "../crates/wisq-site";

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
  "    rustup target add wasm32-unknown-unknown",
  "    cargo install wasm-bindgen-cli --version 0.2.129   # ou le binaire préconstruit",
  "    bun add --dev binaryen                             # fournit wasm-opt",
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

// `wasm-opt -Oz` : mesuré, 210 334 octets avant, 188 859 après — 21 475 de
// moins pour une passe qui ne change rien au comportement.
const wasmOpt = "node_modules/binaryen/bin/wasm-opt";
await lancer(
  "wasm-opt",
  [wasmOpt, "-Oz", "--enable-bulk-memory", "--enable-nontrapping-float-to-int",
   join(wasmOut, "wisq_bg.wasm"), "-o", join(wasmOut, "wisq_bg.wasm")],
  AIDE_RUST,
);

// Les deux fichiers prennent un nom adressé par leur contenu, comme le script et
// la feuille de style, et entrent dans la liste des immuables : un nom qui
// change avec les octets ne peut pas être périmé.
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

// Le pré-rendu, en un seul processus pour toutes les pages portées.
const rendus: Record<string, string> = JSON.parse(
  await lancer("le pré-rendu", ["../target/release/wisq-site-prerender"], AIDE_RUST),
);
const PORTEES = new Set(Object.keys(rendus).map((cle) => cle.split("/")[1]!));
if (PORTEES.size === 0) {
  console.error("le pré-rendu Yew n'a rendu aucune page : la liste des routes portées est vide");
  process.exit(1);
}

// Les noms que cette construction a tirés d'une empreinte de contenu, écrits
// pour l'hôte.
//
// `scripts/serve.ts` reconnaissait `chunk-<hash>.(js|css)` par une expression
// rationnelle, alors que l'en-tête de sa politique de cache énonce une
// propriété et non une orthographe. La police ci-dessus a la propriété et pas
// l'orthographe, donc 90 Kio repartaient en `no-cache` à chaque navigation.
// C'est ici qu'on sait lesquels sont adressés par leur contenu — c'est ici que
// les noms sont composés —, donc c'est ici que la liste s'écrit. Un actif de
// plus entre dans la politique en entrant dans ce tableau.
//
// Hors du précache : le service worker n'en a aucun usage, c'est une question
// d'en-têtes HTTP, et le serveur le lit sur le disque.
const immutable = [scriptName, styleName, fontName, wasmName, glueName];
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
  description: copy.en.hero.lede,
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
/// This has to be an inline, blocking script in the head, and it has to be
/// here rather than in the React bundle: an effect runs after the page has
/// painted, so a reader who chose light on a dark system would see a flash of
/// dark on every navigation. Twelve lines in the head buys that away.
///
/// Kept deliberately dumb — no bundler, no module, no dependency on anything
/// that could fail to load. If it throws, the page is simply on the system
/// theme, which is where it was before this feature existed.
const THEME_SCRIPT = `<script>(function(){try{var t=localStorage.getItem("wisq.theme");if(t!=="light"&&t!=="dark")return;document.documentElement.setAttribute("data-theme",t);var c=t==="dark"?"${BAR.dark}":"${BAR.light}";var m=document.querySelectorAll('meta[name="theme-color"]');for(var i=0;i<m.length;i++){m[i].content=c;}}catch(e){}})();</script>`;

const HOME_TITLE: Record<Lang, string> = {
  en: "wisq — virtual machines on your iPhone",
  fr: "wisq — des machines virtuelles sur votre iPhone",
};

function documentFor(route: Route, lang: Lang): { html: string; title: string } {
  const base = relativeBase(route, lang);
  const isHome = route.id === "home";
  const doc = isHome ? null : PAGES[lang][route.id as keyof (typeof PAGES)["en"]];

  const title = isHome ? HOME_TITLE[lang] : `${doc!.title} — wisq`;
  const description = isHome ? copy[lang].hero.lede : doc!.lede;
  const canonical = `${SITE_URL}${pagePath(route, lang)}`;

  // Le balisage vient de Yew pour les routes déjà portées, de React pour les
  // autres. **La bascule se lit dans ce que le pré-rendu a rendu**, pas dans une
  // liste écrite ici : `crates/wisq-site/src/pages.rs` déclare ce qu'il sait
  // rendre, et une seconde liste de ce côté serait une copie à tenir à jour.
  const cle = `${lang}/${route.id}`;
  const enYew = PORTEES.has(route.id);
  if (enYew && !(cle in rendus)) {
    console.error(`${cle} : route portée en Yew mais absente du pré-rendu`);
    process.exit(1);
  }
  const markup = enYew
    ? rendus[cle]!
    : renderToString(<App route={route.id} lang={lang} doc={doc ?? undefined} />);

  // The document used to travel twice: once as markup, and once as JSON beside
  // it, because hydration had to read exactly what the build rendered. Nothing
  // hydrates any more, so the second copy has no reader and is gone. It was
  // cheap over the wire — the two copies sat inside gzip's window, so the
  // duplicate was mostly back-references — but a payload nobody parses is
  // still bytes, and still something a reader of this file has to account for.

  // Every page says where its other language lives, and which one a reader
  // with no preference should get. Without this a search engine treats the two
  // as unrelated documents and picks one of them to show everybody.
  const alternates = [
    ...LANGS.map(
      (code) =>
        `\n    <link rel="alternate" hreflang="${code}" href="${SITE_URL}${pagePath(route, code)}" />`,
    ),
    `\n    <link rel="alternate" hreflang="x-default" href="${SITE_URL}${pagePath(route, "en")}" />`,
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
        description: copy[lang].hero.lede,
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

  const html = `<!doctype html>
<html lang="${lang}">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <title>${escapeHTML(title)}</title>
    <meta name="description" content="${escapeHTML(description)}" />
    <meta name="author" content="${escapeHTML(AUTHOR)}" />
    <link rel="canonical" href="${canonical}" />${alternates}
    <meta name="theme-color" content="${BAR.dark}" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="${BAR.light}" media="(prefers-color-scheme: light)" />
    <meta property="og:title" content="${escapeHTML(title)}" />
    <meta property="og:description" content="${escapeHTML(description)}" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="${canonical}" />
    <meta property="og:image" content="${SITE_URL}social-card.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <link rel="manifest" href="${base}manifest.webmanifest" />
    <link rel="apple-touch-icon" href="${base}apple-touch-icon.png" />
    <meta name="apple-mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-title" content="wisq" />
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>▚</text></svg>" />
    <link rel="stylesheet" href="${base}${styleName}" />${jsonLd}
    ${THEME_SCRIPT}
  </head>
  <body>
    <div id="root" data-route="${route.id}" data-lang="${lang}" data-base="${base}"${
      // **La marque, et pourquoi elle est sur le document plutôt que devinée.**
      // Sur une page portée en Yew, c'est le wasm qui tient les comportements ;
      // `main.ts` doit s'effacer, sinon les deux rattachent des gestionnaires au
      // même DOM et le thème se met à répondre deux fois à un clic. Le script
      // DOM le lit sur `#root` au lieu de déduire la route : une liste de routes
      // portées de son côté serait une seconde copie de ce que
      // `crates/wisq-site/src/pages.rs` déclare déjà.
      enYew ? ' data-hydrate="yew"' : ""
    }>${markup}</div>
    <script type="module" src="${base}${scriptName}"></script>${
      // La colle de wasm-bindgen est un module ES dont l'export par défaut
      // démarre le module. En ligne et non `src=`, pour que le wasm ne soit
      // demandé que par les pages qui l'hydratent — tant que toutes ne le sont
      // pas, une page React n'a aucune raison de payer 80 Kio.
      enYew
        ? `\n    <script type="module">import demarrer from "${base}${glueName}";demarrer();</script>`
        : ""
    }
  </body>
</html>
`;
  return { html, title };
}

const written: string[] = [];
for (const lang of LANGS) {
  for (const route of ROUTES) {
    const file = outputPath(route, lang);
    const target = join(outdir, file);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, documentFor(route, lang).html);
    written.push(file);
  }
}

// The service worker precaches exactly what this build produced. Hashed asset
// names mean the list changes only when the content does, which is also what
// makes the cache version below stable across rebuilds of the same source.
const precache = [
  // Both languages: a reader who installed the French site and lost the
  // network should get the French site back, not an English fallback.
  ...LANGS.flatMap((lang) =>
    ROUTES.filter((route) => !route.output).map((route) => `./${pagePath(route, lang)}`),
  ),
  `./${scriptName}`,
  `./${styleName}`,
  // The font is in the list for the same reason the stylesheet is: a reader
  // offline would otherwise get the page in the fallback sans, which is a
  // different design.
  `./${fontName}`,
  // Le front en Yew, et **la garde l'a nommé avant un lecteur**. Les deux
  // fichiers étaient dans `immutable.txt` — la liste des en-têtes de cache — et
  // pas ici : hors ligne, une page portée se serait affichée depuis le cache,
  // puis n'aurait jamais hydraté, faute de pouvoir chercher son module. Une
  // page qui s'affiche et ne répond plus est pire qu'une page absente, parce
  // que rien ne la signale. Deux listes, deux objets, et il fallait les deux.
  `./${wasmName}`,
  `./${glueName}`,
  "./manifest.webmanifest",
  ...ICONS.map((icon) => `./${icon.file}`),
];
const version = Bun.hash(precache.join("|")).toString(16);

const serviceWorker = `/// Makes the site openable with no network, and launchable from a Home Screen.
///
/// Two strategies, chosen by what the request is for. A navigation goes to the
/// network first: documentation that is quietly a week stale is worse than a
/// spinner. Everything else — the hashed script, the stylesheet, the icons —
/// comes from the cache first, because a hashed name can never be stale.
const VERSION = "wisq-${version}";
const PRECACHE = ${JSON.stringify(precache, null, 2).replace(/\n/g, "\n")};
const OFFLINE = { en: "./offline/", fr: "./fr/offline/" };

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
      `  <url><loc>${SITE_URL}${pagePath(route, lang)}</loc>` +
      LANGS.map(
        (other) =>
          `<xhtml:link rel="alternate" hreflang="${other}" href="${SITE_URL}${pagePath(route, other)}"/>`,
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
