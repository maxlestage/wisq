import { StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import { App } from "./App";
import type { RouteId } from "./routes";
import type { Lang } from "./content";
import type { Doc } from "./doc";

const container = document.getElementById("root");
if (!container) throw new Error("#root introuvable");

// Which page this is, and how far it sits from the site root, are decided at
// build time and written onto the container. The alternative — reading
// location.pathname — would have to know where the site is deployed, and this
// one is served from /wisq/ today and from a domain root tomorrow.
const route = (container.dataset.route ?? "home") as RouteId;
const lang = (container.dataset.lang ?? "en") as Lang;
const base = container.dataset.base ?? "./";

// The written pages' text arrives with the document, not in this script.
//
// Importing the page table here would put every page, in both languages, into
// the bundle every visitor downloads — 61 KB raw, 21.6 KB over the wire, for
// prose almost none of them will read. The build writes this page's own
// document beside the markup instead, so the bundle carries the site's
// behaviour and each page carries its own words.
//
// A missing or unreadable payload is not a reason to fail: the landing page
// has none by design, and a document served from a stale cache would rather
// stay as pre-rendered markup than be replaced by an error.
function embeddedDoc(): Doc | undefined {
  const element = document.getElementById("doc");
  if (!element?.textContent) return undefined;
  try {
    return JSON.parse(element.textContent) as Doc;
  } catch {
    return undefined;
  }
}

// The HTML arrives pre-rendered, so this attaches behaviour to existing markup
// instead of building it: the page is readable before this script even loads.
hydrateRoot(
  container,
  <StrictMode>
    <App route={route} lang={lang} doc={embeddedDoc()} />
  </StrictMode>,
);

// The service worker is what makes the site openable with no network and
// launchable from the Home Screen. It is registered after load so it never
// competes with the page for the first bytes.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register(new URL(`${base}sw.js`, location.href)).catch(() => {
      // A browser that refuses it — private mode, an unsupported context — gets
      // an ordinary website. Nothing here is load-bearing.
    });
  });
}
