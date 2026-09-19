/// The eight places that state this project's version, read and compared.
///
/// **The eighth was found drifted, not in principle.** `docs/TESTER-UBUNTU.md`
/// is the page someone follows to install wisq, and it announced `v0.3.0` as
/// the newest release for the fortnight after `v0.4.0` shipped. It was never
/// in this list because this file was written about the *release procedure*,
/// and a guide is not part of it — which is exactly how it drifted: nothing
/// bumps a document that the procedure does not touch.
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
    "le guide d'installation",
    "docs/TESTER-UBUNTU.md",
    /la dernière\s+release[^.]*?v(\d+\.\d+\.\d+)/,
    "la release que quelqu'un ira chercher pour installer l'application",
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
  /// nothing, and seven green assertions would mean seven files nobody read.
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
  /// seven assertions above would demand that all eight files be bumped for it.
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

/// **Le guide n'énonce pas qu'un numéro : il énonce une date, et il peut
/// nommer la version plus d'une fois.** Les deux ont dérivé ensemble — « la
/// dernière release, v0.3.0, est du 24 août » quand le CHANGELOG disait
/// 0.4.0 du 5 septembre, et un second « v0.3.0 » quinze lignes plus bas que
/// la première entrée de `PLACES` n'aurait pas vu.
///
/// La règle est donc plus large qu'une place : **aucun numéro de release
/// nommé dans le guide n'a le droit d'être un autre que le plus récent.** Le
/// jour où le guide aura une raison d'en nommer un ancien, ce test le dira,
/// et c'est là qu'on décidera — pas en silence.
describe("le guide d'installation ne nomme que la release du jour", () => {
  /// Les mois en toutes lettres, parce que c'est ainsi qu'un guide écrit une
  /// date, et que `2026-09-05` dans une phrase française serait le genre de
  /// concession qu'un lecteur paie pour qu'un test soit plus facile à écrire.
  const MONTHS = [
    "janvier", "février", "mars", "avril", "mai", "juin",
    "juillet", "août", "septembre", "octobre", "novembre", "décembre",
  ];

  /// La date du CHANGELOG pour une version donnée, dite comme le guide la dit.
  function dateOf(version: string): string {
    const escaped = version.replace(/\./g, "\\.");
    const found = read("CHANGELOG.md").match(
      new RegExp(`^## \\[${escaped}\\] — (\\d{4})-(\\d{2})-(\\d{2})`, "m"),
    );
    if (!found) throw new Error(`CHANGELOG.md ne date plus la ${version}`);
    const day = Number(found[3]);
    return `${day === 1 ? "1er" : day} ${MONTHS[Number(found[2]) - 1]}`;
  }

  /// Tous les numéros de release que le guide nomme, et un refus si aucun :
  /// un lecteur qui ne trouve rien compare rien à rien et passe.
  function versionsNamed(): string[] {
    const found = [...read("docs/TESTER-UBUNTU.md").matchAll(/v(\d+\.\d+\.\d+)/g)].map(
      (match) => match[1]!,
    );
    if (found.length === 0) {
      throw new Error(
        "docs/TESTER-UBUNTU.md ne nomme plus aucune release. Si c'est voulu, " +
          "c'est ce test qu'il faut retirer — pas le laisser ne rien garder.",
      );
    }
    return found;
  }

  test("chaque version nommée dans le guide est la plus récente", () => {
    const newest = releasedVersions()[0]!;
    for (const version of versionsNamed()) {
      expect(
        version,
        `docs/TESTER-UBUNTU.md nomme la v${version} alors que la dernière ` +
          `release est la v${newest}. C'est le document qu'on suit pour ` +
          `installer wisq : il envoie chercher la mauvaise.`,
      ).toBe(newest);
    }
  });

  test("le guide date cette release comme le CHANGELOG la date", () => {
    const newest = releasedVersions()[0]!;
    const said = dateOf(newest);
    expect(
      read("docs/TESTER-UBUNTU.md"),
      `le guide ne dit pas « ${said} », la date que le CHANGELOG donne à la ` +
        `v${newest}. Une release datée d'un autre jour que le sien se lit ` +
        `comme un avertissement sur la fraîcheur de ce qu'on installe.`,
    ).toContain(said);
  });

  /// Les deux lecteurs ci-dessus peuvent tomber, et on le montre plutôt que
  /// de l'affirmer : c'est la règle de ce fichier.
  test("le lecteur de dates refuse une version que le CHANGELOG ne date pas", () => {
    expect(() => dateOf("9.9.9")).toThrow(/ne date plus la 9\.9\.9/);
  });

  test("le guide nomme bien au moins une release", () => {
    expect(versionsNamed().length).toBeGreaterThan(0);
  });
});
