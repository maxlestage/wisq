/// Builds the site: one bundle, one pre-rendered document per address, and
/// everything a browser needs to install it.
///
/// A landing page that needs 400 KB of JavaScript before showing a word is the
/// opposite of mobile-first. Rendering at build time means the content paints
/// on the first response; React then hydrates it for the language switch, the
/// install tabs and the Home Screen prompt.
///
/// Every path this emits is relative. The site is served from /wisq/ on GitHub
/// Pages today and from the root of a domain the day it moves, and an absolute
/// /asset.js works in exactly one of those.

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

const outdir = "dist";
const SITE_URL = (process.env.SITE_URL ?? "https://maxlestage.github.io/wisq/").replace(
  /\/?$/,
  "/",
);

await rm(outdir, { recursive: true, force: true });

// Step one: let Bun bundle and hash the script and stylesheet. The HTML it
// emits is thrown away — what is wanted from it is the asset names.
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
const scriptName = bundled.match(/<script[^>]+src="\.\/([^"]+)"/)?.[1];
const styleName = bundled.match(/<link[^>]+rel="stylesheet"[^>]+href="\.\/([^"]+)"/)?.[1];
if (!scriptName || !styleName) {
  console.error("le script ou la feuille de style est introuvable dans le HTML construit");
  process.exit(1);
}

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
  background_color: "#0b0d10",
  theme_color: "#0b0d10",
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
const THEME_SCRIPT = `<script>(function(){try{var t=localStorage.getItem("wisq.theme");if(t!=="light"&&t!=="dark")return;document.documentElement.setAttribute("data-theme",t);var c=t==="dark"?"#0b0d10":"#ffffff";var m=document.querySelectorAll('meta[name="theme-color"]');for(var i=0;i<m.length;i++){m[i].content=c;}}catch(e){}})();</script>`;

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

  const markup = renderToString(<App route={route.id} lang={lang} />);

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
        license: "https://www.apache.org/licenses/LICENSE-2.0",
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
    <meta name="theme-color" content="#0b0d10" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />
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
    <div id="root" data-route="${route.id}" data-lang="${lang}" data-base="${base}">${markup}</div>
    <script type="module" src="${base}${scriptName}"></script>
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
