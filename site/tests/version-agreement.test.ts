/// The seven places that state this project's version, read and compared.
///
/// `0.3.0` appears in the changelog, in two Cargo manifests, in the Xcode
/// project's `MARKETING_VERSION`, twice in the site, and in the Homebrew
/// formula's tag. Exactly one of them was held by anything: `build.test.ts`
/// compares the site's footer to the newest dated changelog entry.
///
/// **Measured.** Five of them were set to five *distinct* wrong versions in one
/// pass — `SITE_VERSION` left alone — and the whole suite run against that:
/// green. Swift, Rust, and the 154 site tests. Nothing joined them.
///
/// **And one of the five is already adrift in fact, not just in principle.**
/// The `release: 0.2.0` commit bumped the formula from `v0.1.1` to `v0.2.0`, so
/// the procedure did include it. Later the same day another commit rewrote the
/// formula and wrote `tag: "v0.3.0"` — a version that did not exist yet. The
/// `release: 0.3.0` commit the next day touched the changelog, both manifests,
/// `project.yml` and five site files, and **not the formula**, because the
/// formula already said what it needed to say. It agrees today by coincidence:
/// it was written a release ahead and the release caught up with it.
///
/// Nothing makes the next release remember. `brew install
/// maxlestage/wisq/wisq-agent` would install the previous daemon while the site
/// advertises the new one — and the formula's own comment says "bump the tag
/// here when cutting one", which is a rule living in a comment.
///
/// Each reader below **throws when it matches nothing**, and there is a test
/// that they all find something. That is not ceremony: a reader whose pattern
/// stops matching returns nothing, and comparing nothing to nothing passes.
/// This file exists because of guards that could not fail.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

function read(path: string): string {
  return readFileSync(join(repoRoot, path), "utf8");
}

/// Pulls one version out of one file, and refuses to return nothing.
function stated(path: string, pattern: RegExp): string {
  const found = read(path).match(pattern);
  if (!found?.[1]) {
    throw new Error(
      `${path} n'énonce plus de version là où ce test la lit (${pattern}). ` +
        `Le motif a cessé de correspondre : corrigez-le plutôt que ce test.`,
    );
  }
  return found[1];
}

/// Every dated entry in the changelog, newest first. `[Unreleased]` carries no
/// date and is deliberately not one of them: it is where the next release's
/// notes accumulate, and treating it as a version would make every commit
/// after a release look like a new one.
function releasedVersions(): string[] {
  const found = [...read("CHANGELOG.md").matchAll(/^## \[(\d+\.\d+\.\d+)\] — /gm)].map(
    (match) => match[1]!,
  );
  if (found.length === 0) throw new Error("CHANGELOG.md n'a plus aucune version datée");
  return found;
}

/// Where the version is written, and what breaks when it is the wrong one.
const PLACES: [name: string, path: string, pattern: RegExp, consequence: string][] = [
  [
    "le manifeste du cœur VM",
    "crates/wisq-vm/Cargo.toml",
    /^version = "(\d+\.\d+\.\d+)"$/m,
    "la bibliothèque liée dans l'application",
  ],
  [
    "le manifeste du démon",
    "crates/wisq-agent/Cargo.toml",
    /^version = "(\d+\.\d+\.\d+)"$/m,
    "ce que `wisq-agent --version` répond",
  ],
  [
    "MARKETING_VERSION",
    "project.yml",
    /MARKETING_VERSION: "(\d+\.\d+\.\d+)"/,
    "la version que porte le bundle iOS",
  ],
  [
    "SITE_VERSION",
    "site/src/content.ts",
    /export const SITE_VERSION = "(\d+\.\d+\.\d+)"/,
    "le pied de page du site",
  ],
  [
    "la page des versions",
    "site/src/pages/releases.ts",
    /export const RELEASED_VERSIONS = \["(\d+\.\d+\.\d+)"/,
    "la première entrée de la page des versions",
  ],
  [
    "le tag de la formule Homebrew",
    "Formula/wisq-agent.rb",
    /tag: "v(\d+\.\d+\.\d+)"/,
    "ce que `brew install` récupère",
  ],
];

describe("every place that states the version states the same one", () => {
  test.each(PLACES)("%s agrees with the newest dated changelog entry", (_name, path, pattern, consequence) => {
    const newest = releasedVersions()[0]!;
    expect(
      stated(path, pattern),
      `${path} a dérivé du CHANGELOG. Ce qui en dépend : ${consequence}.`,
    ).toBe(newest);
  });

  /// The page lists every release, not only the newest, and the changelog is
  /// what decides — including the order.
  test("the releases page lists exactly the dated changelog entries, newest first", () => {
    const listed = [
      ...read("site/src/pages/releases.ts").matchAll(/"(\d+\.\d+\.\d+)"/g),
    ].map((match) => match[1]!);
    const declared = listed.slice(0, releasedVersions().length);
    expect(declared).toEqual(releasedVersions());
  });
});

describe("the readers can fail", () => {
  /// The failure this file is most exposed to, and the reason every reader
  /// throws: a pattern that stops matching returns nothing, nothing equals
  /// nothing, and six green assertions would mean six files nobody read.
  test.each(PLACES)("%s is actually found in its file", (_name, path, pattern) => {
    expect(stated(path, pattern)).toMatch(/^\d+\.\d+\.\d+$/);
  });

  test("a reader whose pattern matches nothing throws instead of returning nothing", () => {
    expect(() => stated("CHANGELOG.md", /^version = "(\d+\.\d+\.\d+)"$/m)).toThrow(
      /n'énonce plus de version/,
    );
  });

  /// `[Unreleased]` has no date, and must not be read as a release: every
  /// commit after a release would otherwise look like a new version, and the
  /// six assertions above would demand that all seven files be bumped for it.
  test("the unreleased section is not a version", () => {
    expect(read("CHANGELOG.md")).toContain("## [Unreleased]");
    expect(releasedVersions()).not.toContain("Unreleased");
    for (const version of releasedVersions()) expect(version).toMatch(/^\d+\.\d+\.\d+$/);
  });

  /// And the changelog really does carry more than one, or "newest first"
  /// would be a claim about a list of one.
  test("the changelog has several dated entries, and they descend", () => {
    const versions = releasedVersions();
    expect(versions.length).toBeGreaterThan(1);
    const rank = (v: string) =>
      v.split(".").reduce((total, part) => total * 1000 + Number(part), 0);
    for (let index = 1; index < versions.length; index += 1) {
      expect(
        rank(versions[index - 1]!),
        `${versions[index - 1]} devrait être plus récent que ${versions[index]}`,
      ).toBeGreaterThan(rank(versions[index]!));
    }
  });
});
