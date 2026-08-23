/// Every page the site ships, and the one place that knows about them.
///
/// Each route becomes a real directory with its own pre-rendered HTML, rather
/// than a fragment of a client-side router. Three things fall out of that and
/// all three matter here: the page arrives readable in the first response, a
/// search engine sees a real URL, and the service worker can cache a document
/// per address instead of one shell that has to boot before it knows what it
/// is showing.

export type RouteId =
  | "home"
  | "notFound"
  | "docs"
  | "protocol"
  | "architecture"
  | "faq"
  | "roadmap"
  | "releases"
  | "offline";

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

export const ROUTES: Route[] = [
  { id: "home", path: "", listed: true },
  { id: "docs", path: "docs", listed: true },
  { id: "protocol", path: "protocol", listed: true },
  { id: "architecture", path: "architecture", listed: true },
  { id: "faq", path: "faq", listed: true },
  { id: "roadmap", path: "roadmap", listed: true },
  { id: "releases", path: "releases", listed: true },
  // Shown only when the network is gone and the address was never cached, so
  // it has no place in navigation or in a sitemap.
  { id: "offline", path: "offline", listed: false },
  { id: "notFound", path: "", listed: false, output: "404.html" },
];

/// How deep a route sits, which is how many `../` its assets need.
///
/// Everything the pages reference is relative on purpose: the site is served
/// from `/wisq/` on GitHub Pages today, and from the root of a domain the day
/// it moves. A path that starts with `/` would work in exactly one of those.
export function relativeBase(route: Route): string {
  return route.path === "" ? "./" : "../";
}

export function outputPath(route: Route): string {
  return route.output ?? (route.path === "" ? "index.html" : `${route.path}/index.html`);
}

export function routeHref(from: Route, to: Route): string {
  const base = relativeBase(from);
  return to.path === "" ? base : `${base}${to.path}/`;
}

export function routeById(id: RouteId): Route {
  const route = ROUTES.find((candidate) => candidate.id === id);
  if (!route) throw new Error(`route inconnue : ${id}`);
  return route;
}
