/// The four things the site does in a browser, run in one.
///
/// These exist because of what this slice removed. React used to hydrate the
/// pre-rendered pages, and hydration was the mechanism behind a redirect, a
/// remembered language, the theme switch and the install banner. Replacing it
/// with plain DOM code cut 65 794 bytes gzipped down to about a thousand — and
/// every other test added alongside it checks the *bundle*, not the behaviour.
/// A script that weighs nothing and does nothing would pass all of them.
///
/// So this loads the actual built page, runs the actual shipped module against
/// it, and presses the buttons. `main.ts` runs its work at import time, which
/// is why each test re-imports it with a cache-busting query after arranging
/// the document — importing once and calling nothing would test an empty file.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const dist = join(import.meta.dir, "..", "dist");

/// A counter, so every `import` below is a fresh module evaluation rather than
/// the cached one from the previous test.
let run = 0;

async function runScript() {
  await import(`../src/main.ts?run=${(run += 1)}`);
}

/// The real page, with its `<script>` and `<link rel=stylesheet>` stripped.
///
/// The module is imported by the test rather than fetched by the document, and
/// the stylesheet is dropped because a DOM that tries to fetch it reaches for
/// the network — which fails on a CI runner with no route out and buries the
/// results in DNS errors. Nothing here depends on a single declared style: the
/// banner is hidden by the `hidden` attribute, which is an attribute, and every
/// assertion below reads attributes rather than computed styles.
function load(page: string) {
  const html = readFileSync(join(dist, page), "utf8")
    .replace(/<script[\s\S]*?<\/script>/g, "")
    .replace(/<link[^>]+rel="stylesheet"[^>]*>/g, "");
  document.documentElement.innerHTML = html.replace(/[\s\S]*<html[^>]*>/, "").replace(
    /<\/html>[\s\S]*/,
    "",
  );
}

beforeEach(() => {
  GlobalRegistrator.register({ url: "https://example.test/" });
  localStorage.clear();
});

afterEach(async () => {
  await GlobalRegistrator.unregister();
});

describe("the theme switch", () => {
  test("a stored choice is what shows as pressed", async () => {
    load("index.html");
    localStorage.setItem("wisq.theme", "dark");
    await runScript();

    const pressed = [...document.querySelectorAll("[data-theme-choice]")]
      .filter((button) => button.getAttribute("aria-pressed") === "true")
      .map((button) => (button as HTMLElement).dataset.themeChoice);
    expect(pressed).toEqual(["dark"]);
  });

  test("clicking a theme applies it, stores it, and moves the pressed state", async () => {
    load("index.html");
    await runScript();

    const light = document.querySelector<HTMLButtonElement>('[data-theme-choice="light"]')!;
    light.click();

    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(localStorage.getItem("wisq.theme")).toBe("light");
    expect(light.getAttribute("aria-pressed")).toBe("true");
    expect(
      document
        .querySelector('[data-theme-choice="auto"]')!
        .getAttribute("aria-pressed"),
    ).toBe("false");
  });

  /// `auto` is the absence of a choice, not a third stored value — otherwise a
  /// reader who went back to `auto` would be pinned to whatever the system was
  /// on the day they did it.
  test("choosing auto removes the stored value rather than storing 'auto'", async () => {
    load("index.html");
    localStorage.setItem("wisq.theme", "dark");
    await runScript();

    document.querySelector<HTMLButtonElement>('[data-theme-choice="auto"]')!.click();

    expect(localStorage.getItem("wisq.theme")).toBeNull();
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
  });
});

describe("the language", () => {
  test("following a language link records the choice", async () => {
    load("index.html");
    await runScript();

    document.querySelector<HTMLAnchorElement>('.lang-switch a[hreflang="fr"]')!.click();
    expect(localStorage.getItem("wisq.lang")).toBe("fr");
  });

  /// The redirect is the one behaviour here that can annoy a reader, so its
  /// three guards are worth checking one at a time: only the home page, only
  /// when nothing was ever chosen, only for a French-speaking browser.
  test("a French browser on the English home page is sent to the French one", async () => {
    load("index.html");
    Object.defineProperty(navigator, "language", { value: "fr-FR", configurable: true });
    let replaced: string | undefined;
    Object.defineProperty(location, "replace", {
      value: (href: string) => {
        replaced = href;
      },
      configurable: true,
    });

    await runScript();
    expect(replaced).toContain("/fr/");
  });

  test("a reader who has already chosen English is left alone", async () => {
    load("index.html");
    localStorage.setItem("wisq.lang", "en");
    Object.defineProperty(navigator, "language", { value: "fr-FR", configurable: true });
    let replaced: string | undefined;
    Object.defineProperty(location, "replace", {
      value: (href: string) => {
        replaced = href;
      },
      configurable: true,
    });

    await runScript();
    expect(replaced).toBeUndefined();
  });

  test("a deep link shared in English is not redirected", async () => {
    load("docs/index.html");
    Object.defineProperty(navigator, "language", { value: "fr-FR", configurable: true });
    let replaced: string | undefined;
    Object.defineProperty(location, "replace", {
      value: (href: string) => {
        replaced = href;
      },
      configurable: true,
    });

    await runScript();
    expect(replaced).toBeUndefined();
  });
});

describe("the install banner", () => {
  test("nothing is revealed on a browser that never offers to install", async () => {
    load("index.html");
    await runScript();

    expect(document.querySelector("[data-install]")!.hasAttribute("hidden")).toBe(true);
  });

  test("beforeinstallprompt reveals the banner, its wording and its button", async () => {
    load("index.html");
    await runScript();

    const event = new Event("beforeinstallprompt") as Event & {
      prompt: () => Promise<void>;
      userChoice: Promise<{ outcome: string }>;
    };
    event.prompt = async () => {};
    event.userChoice = Promise.resolve({ outcome: "accepted" });
    window.dispatchEvent(event);

    expect(document.querySelector("[data-install]")!.hasAttribute("hidden")).toBe(false);
    expect(
      document.querySelector('[data-install-variant="prompt"]')!.hasAttribute("hidden"),
    ).toBe(false);
    expect(
      document.querySelector("[data-install-accept]")!.hasAttribute("hidden"),
    ).toBe(false);
    // The iOS wording stays hidden: this reader is not on iOS, and telling them
    // to tap a Share button they do not have is worse than saying nothing.
    expect(
      document.querySelector('[data-install-variant="ios"]')!.hasAttribute("hidden"),
    ).toBe(true);
  });

  test("dismissing hides it and it does not come back", async () => {
    load("index.html");
    await runScript();

    const event = new Event("beforeinstallprompt") as Event & { prompt: () => Promise<void> };
    event.prompt = async () => {};
    window.dispatchEvent(event);
    document.querySelector<HTMLButtonElement>("[data-install-dismiss]")!.click();

    expect(document.querySelector("[data-install]")!.hasAttribute("hidden")).toBe(true);
    expect(localStorage.getItem("wisq.install.dismissed")).toBe("1");

    // A second visit: the same page, the same event, and still no banner.
    load("index.html");
    await runScript();
    window.dispatchEvent(event);
    expect(document.querySelector("[data-install]")!.hasAttribute("hidden")).toBe(true);
  });
});
