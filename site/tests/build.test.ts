import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/// The built artefact, not the source. `bun run build` must run before this;
/// CI does exactly that.
const dist = join(import.meta.dir, "..", "dist");
const indexPath = join(dist, "index.html");

describe("built output", () => {
  const html = existsSync(indexPath) ? readFileSync(indexPath, "utf8") : "";

  test("the build ran", () => {
    expect(existsSync(indexPath), "dist/index.html manquant : lancez `bun run build`").toBe(true);
  });

  test("the page is readable before any JavaScript loads", () => {
    // The whole point of pre-rendering: content in the first response.
    expect(html).toContain("Virtual machines on your iPhone.");
    expect(html).toContain("How pairing works");
  });

  test("assets are referenced relatively, so a subdirectory deploy works", () => {
    // GitHub Pages serves project sites from /<repo>/; absolute /asset.js would
    // 404 there.
    const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((match) => match[1]);
    const local = refs.filter((ref) => ref.endsWith(".js") || ref.endsWith(".css"));
    expect(local.length).toBeGreaterThan(0);
    for (const ref of local) {
      expect(ref.startsWith("./"), `chemin non relatif : ${ref}`).toBe(true);
    }
  });

  test("the mobile viewport is declared", () => {
    expect(html).toContain("width=device-width");
    expect(html).toContain("viewport-fit=cover");
  });
});
