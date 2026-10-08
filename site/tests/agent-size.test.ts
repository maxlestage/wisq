/// **Huit textes annoncent la taille du démon ; un seul binaire la décide.**
///
/// Le 28 septembre 2026 ils en donnaient **trois** : 1,7 Mo au document du
/// protocole et aux deux README, 582 Ko sur la page du site — dans les deux
/// langues — et dans le guide de contribution, 454 Ko dans le commentaire de
/// `Package.swift`. Les deux derniers avaient été vrais, avant que le démon
/// n'apprenne le TLS puis l'appairage ; le document avait été corrigé le
/// 2 septembre, le reste ne l'avait pas appris.
///
/// **Le nombre était pourtant produit à chaque exécution de la CI.** Le job
/// Rust construit ce binaire et en imprime la taille par un `ls -l` que
/// personne ne lit. `scripts/check-agent-size.sh` est le fil entre l'instrument
/// et les textes ; ce fichier-ci le regarde refuser, parce qu'une garde qui n'a
/// jamais refusé est une garde que personne n'a vérifiée.
///
/// **Le binaire est fabriqué ici, pas construit.** La garde ne lit du fichier
/// que sa taille en octets : un fichier de la longueur voulue pose exactement
/// la question qu'elle pose, sans demander une chaîne musl à une suite qui doit
/// tourner partout. Ce que ça ne teste pas — que le binaire construit soit bien
/// celui de la release — est tenu ailleurs, par le workflow qui le construit.

import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const guard = join(repoRoot, "scripts", "check-agent-size.sh");

/// Les fichiers que la garde lit, et rien d'autre.
const texts = [
  "site/src/pages/protocol.ts",
  "docs/AGENT-PROTOCOL.md",
  "Package.swift",
  ".github/workflows/release.yml",
  "README.md",
  "README.fr.md",
  "CONTRIBUTING.md",
];

function run(root: string): { code: number; out: string; err: string } {
  const result = Bun.spawnSync([guard, root], { stdout: "pipe", stderr: "pipe" });
  const decoder = new TextDecoder();
  return {
    code: result.exitCode ?? -1,
    out: decoder.decode(result.stdout),
    err: decoder.decode(result.stderr),
  };
}

/// Une copie du vrai dépôt réduite aux huit textes, plus un binaire de la
/// taille demandée. Les vrais textes plutôt que des textes fabriqués : un
/// paragraphe écrit pour l'occasion ne testerait que lui-même.
function copy(bytes: number): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-agent-size-"));
  for (const path of texts) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), readFileSync(join(repoRoot, path)));
  }
  const directory = join(root, "target/x86_64-unknown-linux-musl/release");
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "wisq-agent"), Buffer.alloc(bytes));
  return root;
}

function rewrite(root: string, path: string, from: string, to: string) {
  const full = join(root, path);
  const text = readFileSync(full, "utf8");
  expect(text.includes(from), `« ${from} » absent de ${path}`).toBe(true);
  writeFileSync(full, text.replace(from, to));
}

/// Les huit motifs, écrits une deuxième fois ici — dans l'autre langage, comme
/// le débordement `largeur × hauteur × 4` qui est sorti de cette habitude-là.
const patterns: [string, string, RegExp][] = [
  ["le site, en anglais", "site/src/pages/protocol.ts", /it is now (\d+[.,]\d+) MB/g],
  ["le site, en français", "site/src/pages/protocol.ts", /il en fait (\d+[.,]\d+) Mo/g],
  [
    "le document du protocole",
    "docs/AGENT-PROTOCOL.md",
    /il en fait aujourd'hui \*\*(\d+[.,]\d+) Mo\*\*/g,
  ],
  ["le manifeste du paquet", "Package.swift", /it is now (\d+[.,]\d+) MB/g],
  [
    "le workflow de release",
    ".github/workflows/release.yml",
    /(\d+[.,]\d+) MB on x86_64/g,
  ],
  ["le README anglais", "README.md", /from 58 MB to (\d+[.,]\d+) MB/g],
  ["le README français", "README.fr.md", /de 58 Mo à (\d+[.,]\d+) Mo/g],
  ["le guide de contribution", "CONTRIBUTING.md", /from 58 MB to (\d+[.,]\d+) MB/g],
];

function announcedIn(root: string): Map<string, string> {
  const found = new Map<string, string>();
  for (const [label, path, pattern] of patterns) {
    const matches = [...readFileSync(join(root, path), "utf8").matchAll(pattern)];
    expect(matches.length, `${label} : ${matches.length} occurrence(s) dans ${path}`).toBe(1);
    found.set(label, matches[0][1].replace(",", "."));
  }
  return found;
}

/// Le chiffre publié, et les phrases qui le portent, **lus** plutôt qu'écrits.
///
/// Les quatre sabordages plus bas les écrivaient à la main — `copy(1_778_384)`,
/// `"it is now 1.8 MB"`, `"il en fait 1,8 Mo"` — pendant que les deux premiers
/// tests du même fichier dérivaient déjà de `announcedIn`. La chaîne Rust du
/// coureur a bougé, le démon a maigri de 1,8 à 1,7 Mo, les huit textes l'ont
/// appris et ces quatre tests sont tombés : ils gardaient leur propre copie
/// d'une mesure qui n'est pas la leur.
///
/// Le second chiffre est voisin d'un dixième, pas constant : il doit seulement
/// **différer** de celui qui est publié, et une valeur en dur redeviendrait
/// égale le jour où le démon atteindrait cette taille-là.
const PUBLIÉ = [...announcedIn(repoRoot).values()][0]!;
const OCTETS = Math.round(Number(PUBLIÉ) * 1_000_000);
const VOISIN = (Number(PUBLIÉ) + 0.1).toFixed(1);
const DÉCIMALE = (figure: string) => figure.replace(".", ",");

/// **Hermétique exprès.** Le job « Build site » ne construit pas le démon, donc
/// la suite du site ne peut pas exiger le binaire — c'est `verify.sh` et le job
/// Rust qui confrontent les textes à sa taille réelle, là où il vient d'être
/// construit. Ce que ce test-ci tient est l'autre moitié, et c'est le défaut qui
/// s'est produit : les huit textes qui se contredisent entre eux.
test("les huit textes du dépôt annoncent un seul et même nombre", () => {
  const announced = announcedIn(repoRoot);
  expect([...new Set(announced.values())], [...announced].join(" · ")).toHaveLength(1);
});

test("sur un arbre dont le binaire s'accorde, la garde passe et dit ce qu'elle a mesuré", () => {
  const figure = [...announcedIn(repoRoot).values()][0];
  const root = copy(Math.round(Number(figure) * 1_000_000));
  const { code, out, err } = run(root);
  expect(err).toBe("");
  expect(code, out + err).toBe(0);
  // Une garde qui compare sans jamais dire ce qu'elle a mesuré est la onzième
  // façon de se tromper consignée au JOURNAL : elle connaît la réponse et la
  // jette.
  expect(out).toContain(`soit ${figure} Mo`);
});

test("un démon qui grossit d'un dixième de mégaoctet fait rougir les huit textes", () => {
  // 1,9 Mo : au-dessus de ce que les textes annoncent, et d'un cran seulement.
  const { code, err } = run(copy(1_900_000));
  expect(code).toBe(1);
  for (const label of [
    "le site, en anglais",
    "le site, en français",
    "le document du protocole",
    "le manifeste du paquet",
    "le workflow de release",
    "le README anglais",
    "le README français",
    "le guide de contribution",
  ]) {
    expect(err, `${label} n'est pas accusé`).toContain(label);
  }
});

test("un seul texte périmé suffit à faire rougir, et lui seul est nommé", () => {
  const root = copy(OCTETS);
  rewrite(root, "Package.swift", `it is now ${PUBLIÉ} MB`, `it is now ${VOISIN} MB`);
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("le manifeste du paquet");
  expect(err).not.toContain("le document du protocole");
});

test("les deux langues de la même page sont lues séparément", () => {
  const root = copy(OCTETS);
  rewrite(
    root,
    "site/src/pages/protocol.ts",
    `il en fait ${DÉCIMALE(PUBLIÉ)} Mo`,
    `il en fait ${DÉCIMALE(VOISIN)} Mo`,
  );
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("le site, en français");
  expect(err).not.toContain("le site, en anglais");
});

/// **Le motif qui ne trouve rien ne doit pas ressembler à un accord.** C'est le
/// trou mesuré sur la garde des versions : un lecteur qui ne lit rien et un
/// lecteur qui lit la bonne chose se ressemblent tant que les deux côtés de la
/// comparaison sont vides.
test("une phrase qui change de forme est refusée, pas ignorée", () => {
  const root = copy(OCTETS);
  rewrite(
    root,
    "docs/AGENT-PROTOCOL.md",
    `il en fait aujourd'hui **${DÉCIMALE(PUBLIÉ)} Mo**`,
    `il pèse **${DÉCIMALE(PUBLIÉ)} Mo**`,
  );
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("le motif trouve 0 occurrence(s)");
});

test("une deuxième occurrence du motif est refusée aussi : la comparaison deviendrait ambiguë", () => {
  const root = copy(OCTETS);
  rewrite(
    root,
    "Package.swift",
    `// routes, and it is now ${PUBLIÉ} MB.`,
    `// routes, and it is now ${PUBLIÉ} MB. Ailleurs it is now ${PUBLIÉ} MB.`,
  );
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("le motif trouve 2 occurrence(s)");
});

test("sans binaire, la garde refuse et dit comment le construire", () => {
  const root = mkdtempSync(join(tmpdir(), "wisq-agent-size-vide-"));
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("rustup target add x86_64-unknown-linux-musl");
});
