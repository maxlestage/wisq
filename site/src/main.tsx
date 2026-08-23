import { StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import { App } from "./App";
import type { RouteId } from "./routes";
import type { Lang } from "./content";

const container = document.getElementById("root");
if (!container) throw new Error("#root introuvable");

// Which page this is, and how far it sits from the site root, are decided at
// build time and written onto the container. The alternative — reading
// location.pathname — would have to know where the site is deployed, and this
// one is served from /wisq/ today and from a domain root tomorrow.
const route = (container.dataset.route ?? "home") as RouteId;
const lang = (container.dataset.lang ?? "en") as Lang;
const base = container.dataset.base ?? "./";

// The HTML arrives pre-rendered, so this attaches behaviour to existing markup
// instead of building it: the page is readable before this script even loads.
hydrateRoot(
  container,
  <StrictMode>
    <App route={route} lang={lang} />
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
