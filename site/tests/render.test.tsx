import { describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { App } from "../src/App";
import { copy, type Lang } from "../src/content";
import { documentStrings } from "../src/doc";
import { PAGES } from "../src/pages";
import { ROUTES } from "../src/routes";

/// React escapes text as it renders, so a comparison against the source string
/// has to undo that first — otherwise every assertion about a sentence with an
/// apostrophe in it fails for the wrong reason.
function text(html: string): string {
  return html
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

/// Server-rendering every page is the cheapest honest check that they work: if
/// a component throws, a hook is misused or a translation is missing, this
/// fails rather than shipping a blank page.
describe("page rendering", () => {
  test("every route renders in both languages", () => {
    for (const route of ROUTES) {
      for (const lang of ["en", "fr"] as Lang[]) {
        const html = renderToString(<App route={route.id} lang={lang} />);
        expect(html.length, `${route.id}/${lang} : rendu vide`).toBeGreaterThan(500);
        // The header is on every page, so its absence means the shell broke.
        expect(html, `${route.id}/${lang} : en-tête`).toContain("site-header");
      }
    }
  });

  test("each written page shows its own title", () => {
    for (const route of ROUTES) {
      if (route.id === "home") continue;
      for (const lang of ["en", "fr"] as Lang[]) {
        const doc = PAGES[lang][route.id as keyof (typeof PAGES)["en"]];
        const html = renderToString(<App route={route.id} lang={lang} />);
        expect(text(html), `${route.id}/${lang}`).toContain(doc.title);
      }
    }
  });

  test("renders the English landing page with its load-bearing content", () => {
    const html = renderToString(<App lang="en" />);
    expect(html).toContain("Virtual machines on your iPhone.");
    expect(html).toContain("A real Linux kernel, on the phone");
  });

  test("renders the French landing page, with no English left in it", () => {
    const html = renderToString(<App lang="fr" />);
    expect(html).toContain("Des machines virtuelles sur votre iPhone.");
    expect(html).toContain("Un vrai noyau Linux, sur le téléphone");
    expect(html).not.toContain("Virtual machines on your iPhone.");
  });

  /// The site explains what wisq is and how it fits together. What it does not
  /// do is tell anyone how to install it — no clone, no tap, no script to
  /// pipe into a shell, no download link.
  ///
  /// The distinction matters, and this test used to blur it: it forbade the
  /// pairing section along with the install commands, on the reasoning that
  /// both were "how to run the project". They are not the same thing. A
  /// reader deciding whether this is for them needs to know that an agent
  /// prints a link and the phone scans it; none of that hands them a build.
  ///
  /// So the list here is commands and download paths only. Everything else on
  /// these pages describes the thing rather than distributing it.
  test("no page hands out a way to install the project", () => {
    for (const lang of ["en", "fr"] as Lang[]) {
      for (const route of ROUTES) {
        const html = renderToString(<App route={route.id} lang={lang} />);
        for (const trace of [
          "install-ios.sh",
          "install.sh",
          "brew tap",
          "brew install",
          "git clone",
          "cargo run",
          "cargo build",
          "xcodegen",
          "wisq-agent --",
          "githubusercontent",
          'id="install"',
          "releases/latest",
          ".ipa",
        ]) {
          expect(html, `${lang}/${route.id} : mode d'emploi (${trace})`).not.toContain(trace);
        }
      }
    }
  });

  /// Whatever else the site sheds, every page has to lead back to the one
  /// page that is left.
  test("every page leads home", () => {
    for (const route of ROUTES) {
      const html = renderToString(<App route={route.id} lang="en" />);
      expect(html, `${route.id} ne mène pas à l'accueil`).toContain('class="brand"');
    }
  });

  /// The install banner decides what to show from the browser, so rendering it
  /// on the server would hand hydration markup that cannot match.
  test("the install prompt renders nothing on the server", () => {
    for (const lang of ["en", "fr"] as Lang[]) {
      const html = renderToString(<App lang={lang} />);
      expect(html).not.toContain("install-banner");
      expect(html).not.toContain(copy[lang].pwa.iosTitle);
    }
  });
});

describe("content integrity", () => {
  test("both languages fill every slot of every page", () => {
    // A missing translation is a type error at build time; this catches the
    // other half — a key that exists but was left empty.
    for (const lang of ["en", "fr"] as Lang[]) {
      for (const [id, doc] of Object.entries(PAGES[lang])) {
        for (const value of documentStrings(doc)) {
          expect(value.trim().length, `chaîne vide : ${lang}/${id}`).toBeGreaterThan(0);
        }
      }
    }
  });

  test("the two languages carry the same pages, block for block", () => {
    for (const id of Object.keys(PAGES.en) as (keyof (typeof PAGES)["en"])[]) {
      const en = PAGES.en[id];
      const fr = PAGES.fr[id];
      expect(fr.blocks.map((block) => block.kind), `structure : ${id}`).toEqual(
        en.blocks.map((block) => block.kind),
      );
    }
  });

  test("no written page is a stub", () => {
    for (const lang of ["en", "fr"] as Lang[]) {
      for (const [id, doc] of Object.entries(PAGES[lang])) {
        if (id === "offline" || id === "notFound") continue;
        const words = documentStrings(doc).join(" ").split(/\s+/).length;
        expect(words, `${lang}/${id} est trop court pour être une page`).toBeGreaterThan(200);
      }
    }
  });
});
