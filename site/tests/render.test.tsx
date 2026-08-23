import { describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { App } from "../src/App";
import { copy, REPO } from "../src/content";

/// Server-rendering the page is the cheapest honest check that it works: if a
/// component throws, a hook is misused or a translation key is missing, this
/// fails rather than shipping a blank page.
describe("page rendering", () => {
  test("renders the English page with its load-bearing content", () => {
    const html = renderToString(<App lang="en" />);
    expect(html).toContain("Virtual machines on your iPhone.");
    expect(html).toContain("A real Linux kernel, on the phone");
    expect(html).toContain(REPO);
  });

  test("renders the French page, with no English left in it", () => {
    const html = renderToString(<App lang="fr" />);
    expect(html).toContain("Des machines virtuelles sur votre iPhone.");
    expect(html).toContain("Un vrai noyau Linux, sur le téléphone");
    // The English tagline must not survive anywhere in the French render.
    expect(html).not.toContain("Virtual machines on your iPhone.");
  });

  test("the install section defaults to iPhone", () => {
    const html = renderToString(<App lang="en" />);
    expect(html).toContain('id="panel-iphone"');
    expect(html).toContain("./scripts/install-ios.sh");
  });
});

describe("content integrity", () => {
  test("both languages fill every slot", () => {
    // A missing translation is a type error at build time; this catches the
    // other half — a key that exists but was left empty.
    const walk = (value: unknown, path: string): void => {
      if (typeof value === "string") {
        expect(value.trim().length, `chaîne vide : ${path}`).toBeGreaterThan(0);
        return;
      }
      if (Array.isArray(value)) {
        expect(value.length, `tableau vide : ${path}`).toBeGreaterThan(0);
        value.forEach((item, index) => walk(item, `${path}[${index}]`));
        return;
      }
      if (value && typeof value === "object") {
        for (const [key, child] of Object.entries(value)) walk(child, `${path}.${key}`);
      }
    };
    walk(copy.en, "en");
    walk(copy.fr, "fr");
  });

  test("the comparison table is rectangular in both languages", () => {
    for (const lang of ["en", "fr"] as const) {
      const { columns, rows } = copy[lang].compare;
      for (const row of rows) {
        expect(row.length, `${lang}: ligne de largeur inattendue`).toBe(columns.length);
      }
    }
  });

  test("every install command carries something runnable", () => {
    for (const lang of ["en", "fr"] as const) {
      const platforms = [copy[lang].install.iphone, copy[lang].install.mac, copy[lang].install.linux];
      for (const platform of platforms) {
        expect(platform.commands.length).toBeGreaterThan(0);
        for (const command of platform.commands) {
          expect(command.code.trim().length).toBeGreaterThan(0);
          // No placeholder URLs shipped by accident.
          expect(command.code).not.toContain("example.com");
        }
      }
    }
  });
});
