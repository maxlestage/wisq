/// Every page the site ships, and the one place that knows about them.
///
/// Each route becomes a real directory with its own pre-rendered HTML, rather
/// than a fragment of a client-side router. Three things fall out of that and
/// all three matter here: the page arrives readable in the first response, a
/// search engine sees a real URL, and the service worker can cache a document
/// per address instead of one shell that has to boot before it knows what it
/// is showing.

import type { Lang } from "./content";

/// English is served from the site root and French from `fr/`.
///
/// The alternative — one address per page and the language chosen in the
/// browser — is what this site did first, and it was wrong in a way that only
/// shows once the site is published: the pre-rendered HTML could only be in
/// one language, so a French reader's first paint was English, a shared link
/// opened in the sender's language rather than the reader's, and a search
/// engine indexed half the site. A language a URL cannot express is a language
/// the web cannot see.
export const LANGS: readonly Lang[] = ["en", "fr"];

export function langPrefix(lang: Lang): string {
  return lang === "en" ? "" : "fr/";
}

/// A page is a route in a language. Nothing on the site is addressable without
/// both.
export interface Page {
  route: Route;
  lang: Lang;
}

export type RouteId = "home" | "notFound" | "privacy" | "offline";

export interface Route {
  id: RouteId;
  /// Directory under the site root. Empty for pages that live at the root.
  path: string;
  /// Whether the page belongs in the header navigation and the sitemap.
  listed: boolean;
  /// Where the file goes, when it is not `<path>/index.html`. GitHub Pages
  /// serves 404.html for an unknown address, and only from the site root.
  output?: string;
}

/// One page, and the two the web requires around it.
///
/// The site used to carry a guide, an agent protocol reference, an
/// architecture note, questions, a roadmap and a release history. They are
/// gone on purpose: the site says what wisq is and stops there. Nothing here
/// explains how to run it, and no page invites anyone to try.
export const ROUTES: Route[] = [
  { id: "home", path: "", listed: true },
  // Reachable from the footer rather than the header, where a reader looks for
  // the legal lines.
  { id: "privacy", path: "privacy", listed: false },
  // Shown only when the network is gone and the address was never cached, so
  // it has no place in navigation or in a sitemap.
  { id: "offline", path: "offline", listed: false },
  { id: "notFound", path: "", listed: false, output: "404.html" },
];

/// The address of a page, relative to the site root: `""`, `"docs/"`,
/// `"fr/"`, `"fr/docs/"`.
export function pagePath(route: Route, lang: Lang): string {
  return `${langPrefix(lang)}${route.path ? `${route.path}/` : ""}`;
}

export function outputPath(route: Route, lang: Lang): string {
  return route.output
    ? `${langPrefix(lang)}${route.output}`
    : `${pagePath(route, lang)}index.html`;
}

/// How deep a page sits, which is how many `../` its assets need.
///
/// Everything the pages reference is relative on purpose: the site is served
/// from `/wisq/` on GitHub Pages today, and from the root of a domain the day
/// it moves. A path that starts with `/` would work in exactly one of those.
/// Counted from the file that gets written rather than from the route, because
/// French adds a directory the route does not know about.
export function relativeBase(route: Route, lang: Lang): string {
  const depth = outputPath(route, lang).split("/").length - 1;
  return depth === 0 ? "./" : "../".repeat(depth);
}

/// A link from one page to another, in the same language unless asked
/// otherwise — which is how the language switch reaches its counterpart.
export function routeHref(from: Page, to: Route, lang: Lang = from.lang): string {
  const base = relativeBase(from.route, from.lang);
  const path = pagePath(to, lang);
  return path ? `${base}${path}` : base;
}

export function routeById(id: RouteId): Route {
  const route = ROUTES.find((candidate) => candidate.id === id);
  if (!route) throw new Error(`route inconnue : ${id}`);
  return route;
}
