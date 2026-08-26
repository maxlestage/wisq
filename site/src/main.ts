/// Everything this site does in a browser.
///
/// It used to be `hydrateRoot`. The pages were already pre-rendered, so React
/// arrived to attach four behaviours to markup that was complete without it:
/// a redirect on the English home page, the memory of a language choice, the
/// theme switch, and the install banner. Measured, that cost **65 794 bytes
/// gzipped**; the same four behaviours written against the DOM cost about a
/// kilobyte. `tests/build.test.ts` holds the new figure to a budget so it
/// cannot quietly grow back.
///
/// The trade is real and worth naming: authoring stays in React — every page
/// is still a component, still rendered by `renderToString` at build time —
/// and only the *delivery* changes. What is lost is the ability to add
/// interactive components by writing JSX. Anything genuinely interactive that
/// arrives later belongs here, in plain DOM code, or it belongs behind a
/// dynamic import that only the pages needing it pay for.
///
/// Nothing below is load-bearing. Every branch is wrapped or guarded so that a
/// browser refusing storage, an absent element, or a stale cached page leaves
/// an ordinary, readable website rather than an error.

import { applyTheme, rememberTheme, storedTheme, type Theme } from "./theme";

const LANG_KEY = "wisq.lang";
const INSTALL_DISMISSED_KEY = "wisq.install.dismissed";

const root = document.getElementById("root");
const base = root?.dataset.base ?? "./";
const route = root?.dataset.route ?? "home";
const lang = root?.dataset.lang ?? "en";

function stored(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    // Private mode, or storage the browser refuses. Not a reason to fail.
    return null;
  }
}

function remember(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* the feature simply does not outlive this page */
  }
}

// --- the language ------------------------------------------------------------
//
// The links are real addresses and work without any of this. All that is added
// is the memory of having chosen, which feeds exactly one decision below.
for (const link of document.querySelectorAll<HTMLAnchorElement>(".lang-switch a[hreflang]")) {
  link.addEventListener("click", () => remember(LANG_KEY, link.hreflang));
}

/// Sends a French-speaking reader from the English home page to the French one.
///
/// Only from the home page, and only when they have never chosen: a redirect on
/// every page would break a deep link someone deliberately shared in English,
/// which is worse than a reader clicking FR once.
if (route === "home" && lang === "en" && !stored(LANG_KEY)) {
  if (navigator.language?.toLowerCase().startsWith("fr")) {
    location.replace(new URL("./fr/", location.href).href);
  }
}

// --- the theme ---------------------------------------------------------------
//
// The colours were already applied before the first paint, by the inline script
// in the head — that is what stops a reader who chose light on a dark system
// from seeing a flash of dark on every navigation. What is left here is the
// pressed state, which nobody sees flash, and the buttons themselves.
const themeButtons = document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]");

function showTheme(theme: Theme) {
  for (const button of themeButtons) {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme));
  }
}

if (themeButtons.length > 0) {
  showTheme(storedTheme());
  for (const button of themeButtons) {
    button.addEventListener("click", () => {
      const choice = button.dataset.themeChoice as Theme;
      applyTheme(choice);
      rememberTheme(choice);
      showTheme(choice);
    });
  }
}

// --- the install banner ------------------------------------------------------
//
// Both wordings are already in the page, hidden. This decides which one applies
// and reveals it; the words themselves never travel through this script.

interface InstallEvent extends Event {
  prompt(): Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

function isStandalone(): boolean {
  if (window.matchMedia?.("(display-mode: standalone)").matches) return true;
  // Safari on iOS predates display-mode and reports this instead.
  return (navigator as unknown as { standalone?: boolean }).standalone === true;
}

function isIOS(): boolean {
  const ua = navigator.userAgent;
  if (/iPad|iPhone|iPod/.test(ua)) return true;
  // iPadOS reports itself as a Mac; the touch points give it away.
  return ua.includes("Macintosh") && navigator.maxTouchPoints > 1;
}

const banner = document.querySelector<HTMLElement>("[data-install]");

if (banner && !isStandalone() && stored(INSTALL_DISMISSED_KEY) !== "1") {
  const show = (variant: "prompt" | "ios") => {
    banner.querySelector<HTMLElement>(`[data-install-variant="${variant}"]`)?.removeAttribute(
      "hidden",
    );
    banner.removeAttribute("hidden");
  };

  const hide = () => {
    banner.setAttribute("hidden", "");
    remember(INSTALL_DISMISSED_KEY, "1");
  };

  banner.querySelector("[data-install-dismiss]")?.addEventListener("click", hide);

  if (isIOS()) {
    show("ios");
  } else {
    window.addEventListener("beforeinstallprompt", (raw: Event) => {
      // Keeping the event is the whole point: the browser only lets the prompt
      // be shown in response to a gesture, so it has to be held until a tap.
      raw.preventDefault();
      const event = raw as InstallEvent;
      const accept = banner.querySelector<HTMLButtonElement>("[data-install-accept]");
      accept?.removeAttribute("hidden");
      accept?.addEventListener(
        "click",
        async () => {
          await event.prompt();
          await event.userChoice;
          hide();
        },
        { once: true },
      );
      show("prompt");
    });
  }
}

// --- the service worker ------------------------------------------------------
//
// What makes the site openable with no network and launchable from the Home
// Screen. Registered after load so it never competes with the page for the
// first bytes.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register(new URL(`${base}sw.js`, location.href)).catch(() => {
      // A browser that refuses it — private mode, an unsupported context — gets
      // an ordinary website. Nothing here is load-bearing.
    });
  });
}
