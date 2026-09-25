/// **La spec déclare des fichiers, le projet engendré en référence : les deux
/// listes doivent s'accorder.**
///
/// `Wisq ‣.xcodeproj/project.pbxproj` est écrit par `xcodegen generate` et
/// commité. Ajoutez un fichier de test à l'application sans régénérer, et il
/// n'est dans aucune cible : le projet est périmé. Rien en local ne le voyait.
/// `check-generated-project.sh` porte un autre sujet malgré son nom — que tout
/// workflow qui régénère compare aussi — et ne régénère rien lui-même.
///
/// Mesuré plutôt que craint : le 25 septembre, `IsoDeletionTests.swift` est
/// entré dans `Tests/WisqUITests` et « App iOS » a rendu « les fichiers
/// engendrés par xcodegen ne sont pas ceux du dépôt ». Un cycle de CI complet
/// pour une comparaison que le coureur Linux fait en un dixième de seconde,
/// **sans XcodeGen** : les noms sous les `sources:` de la spec contre les
/// `path = …` du projet.
///
/// **Ce que la garde ne tient pas est écrit dans la garde**, et tenu ici : le
/// projet référence par nom de base, donc deux fichiers déclarés qui
/// porteraient le même nom rendraient la comparaison ambiguë — et sont refusés
/// pour ça. Elle ne remplace pas la régénération de la CI, qui compare octet
/// pour octet.

import { expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const guard = join(repoRoot, "scripts", "check-project-sources.sh");
const bundle = "Wisq ‣.xcodeproj";

function run(root: string): { code: number; out: string; err: string } {
  const result = Bun.spawnSync([guard, root], { stdout: "pipe", stderr: "pipe" });
  const decoder = new TextDecoder();
  return {
    code: result.exitCode ?? -1,
    out: decoder.decode(result.stdout),
    err: decoder.decode(result.stderr),
  };
}

/// Une copie du vrai dépôt, réduite à ce que la garde lit : la spec, le projet
/// engendré, et les répertoires de sources. Le vrai projet plutôt qu'un projet
/// fabriqué — un pbxproj écrit pour l'occasion ne testerait que lui-même.
function copy(): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-sources-"));
  writeFileSync(join(root, "project.yml"), readFileSync(join(repoRoot, "project.yml")));
  mkdirSync(join(root, bundle), { recursive: true });
  cpSync(
    join(repoRoot, bundle, "project.pbxproj"),
    join(root, bundle, "project.pbxproj"),
  );
  for (const source of ["App", "Tests/WisqUITests", "Tests/WisqHostedTests"]) {
    cpSync(join(repoRoot, source), join(root, source), { recursive: true });
  }
  return root;
}

test("le dépôt tel qu'il est passe", () => {
  const { code, out } = run(repoRoot);
  expect(code).toBe(0);
  // **Prémisse.** « Zéro fichier déclaré, zéro manquant » satisfait la garde
  // sans rien avoir lu. Le relevé dit donc combien il a comparé, et ce nombre
  // est regardé.
  const compte = /Sources du projet : (\d+) fichiers/.exec(out);
  expect(compte, "le relevé doit dire combien de fichiers il a comparés").not.toBeNull();
  expect(Number(compte![1])).toBeGreaterThan(5);
});

test("un fichier ajouté sans régénérer est refusé, et nommé", () => {
  const root = copy();
  writeFileSync(join(root, "Tests", "WisqUITests", "ToutNeufTests.swift"), "// rien\n");
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("ToutNeufTests.swift");
  expect(err).toContain("absent du projet engendré");
  // Et il dit quoi faire : un refus qui laisse chercher coûte plus que le défaut.
  expect(err).toContain("xcodegen generate");
});

test("un fichier supprimé sans régénérer est refusé aussi", () => {
  const root = copy();
  rmSync(join(root, "Tests", "WisqUITests", "DiskLibraryTests.swift"));
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("DiskLibraryTests.swift");
  expect(err).toContain("n'existe plus");
});

test("deux fichiers de même nom rendent la comparaison ambiguë, donc elle refuse", () => {
  const root = copy();
  // Le même nom de base sous deux racines déclarées. Le projet les référence
  // par ce nom : la question « celui-ci est-il référencé ? » n'a plus de
  // réponse unique, et une garde ambiguë ne garde rien.
  cpSync(
    join(root, "Tests", "WisqUITests", "DiskLibraryTests.swift"),
    join(root, "Tests", "WisqHostedTests", "DiskLibraryTests.swift"),
  );
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("s'appellent « DiskLibraryTests.swift »");
});

test("une spec sans racine de sources est refusée, pas acquittée", () => {
  const root = copy();
  const spec = readFileSync(join(root, "project.yml"), "utf8").replace(
    /^ *sources:$/gm,
    "    sourcesRetirees:",
  );
  writeFileSync(join(root, "project.yml"), spec);
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("cette garde ne garderait rien");
});

test("une racine déclarée qui n'existe pas est refusée", () => {
  const root = copy();
  rmSync(join(root, "Tests", "WisqHostedTests"), { recursive: true });
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("Tests/WisqHostedTests");
});

test("le nom du bundle est lu de la spec, jamais écrit en dur", () => {
  // Renommer le projet dans la spec doit déplacer ce que la garde lit. Sans
  // cela elle continuerait de juger l'ancien bundle — verte sur un dépôt
  // renommé, et aveugle.
  const root = copy();
  const spec = readFileSync(join(root, "project.yml"), "utf8").replace(
    /^name: .+$/m,
    "name: Autre",
  );
  writeFileSync(join(root, "project.yml"), spec);
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("Autre.xcodeproj");
});
