/// **Le projet Xcode s'appelle « Wisq ‣ », et ce nom porte une espace.**
///
/// Demande de Maxime : renommer le projet iPhone. Le nom vient de la clé
/// `name` de `project.yml` ; XcodeGen en tire le nom du bundle, donc le dossier
/// devient `Wisq ‣.xcodeproj`. La **cible** reste `Wisq` — c'est elle qui donne
/// `PRODUCT_NAME`, `Wisq.app` et `CFBundleName`, et le renommage ne la touche
/// pas : « uniquement le projet ».
///
/// **Ce que ce renommage introduit vraiment, et que ce fichier garde.** Jusqu'ici
/// le nom du bundle était un mot sans espace : onze appels le passaient nu à un
/// shell sans que ça coûte rien. Mesuré avant d'écrire une ligne :
///
/// | fichier | appels nus |
/// |---|---|
/// | `.github/workflows/ci.yml` | 4 |
/// | `.github/workflows/testflight.yml` | 2 |
/// | `.github/workflows/release.yml` | 2 |
/// | `scripts/verify.sh`, `scripts/test-app.sh` | 2 |
/// | `scripts/check-generated-project.sh` | 1, **et c'était une liste délimitée par l'espace** |
///
/// Une espace dans le nom les casse tous les onze, et quatre d'entre eux vivent
/// dans des workflows qui ne tournent qu'en CI. D'où une garde sur la règle
/// plutôt que sur la liste : **le nom du projet n'apparaît jamais nu**.
///
/// Et une note sur la façon dont l'inventaire a été fait, parce qu'elle a
/// failli manquer huit appels : la première recherche n'a rendu aucune ligne de
/// `.github/`, alors que j'y avais lu la veille un `git diff --exit-code --
/// Wisq.xcodeproj/…`. Une absence qu'on sait fausse n'est pas une absence.

import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const read = (path: string) => readFileSync(join(repoRoot, path), "utf8");

/// Le nom du projet, tel que `project.yml` le déclare — la source, pas une copie.
function projectName(): string {
  const found = /^name: (.+)$/m.exec(read("project.yml"));
  expect(found, "project.yml ne déclare plus de clé `name`").not.toBeNull();
  return found![1]!.trim();
}

test("le projet Xcode porte la marque", () => {
  // U+2023, TRIANGULAR BULLET, par son point de code plutôt que collé.
  expect(projectName()).toBe(`Wisq ‣`);
});

test("le bundle suivi par git est celui que project.yml nomme", () => {
  // XcodeGen écrit `<name>.xcodeproj`. Le dépôt suit le seul `project.pbxproj`
  // (voir `.gitignore`), et c'est ce chemin-là qui doit suivre le nom.
  const suivis = readdirSync(repoRoot).filter((entry) => entry.endsWith(".xcodeproj"));
  expect(suivis, "il ne doit y avoir qu'un seul bundle de projet").toEqual([
    `${projectName()}.xcodeproj`,
  ]);
});

/// Les fichiers où une occurrence nue serait *exécutée*. Les `.ts` de cette
/// suite n'y sont pas : une chaîne TypeScript ne part pas dans un shell.
function executables(): string[] {
  const workflows = readdirSync(join(repoRoot, ".github", "workflows"))
    .filter((name) => /\.ya?ml$/.test(name))
    .map((name) => `.github/workflows/${name}`);
  const scripts = readdirSync(join(repoRoot, "scripts"))
    .filter((name) => name.endsWith(".sh"))
    .map((name) => `scripts/${name}`);
  // Les documents aussi : ce sont des commandes qu'un lecteur colle.
  return [...workflows, ...scripts, "README.fr.md", "README.md", "CONTRIBUTING.md"];
}

/// Un commentaire peut nommer le projet sans le passer à un shell. Les `#` de
/// tête sont donc retirés — sauf dans le Markdown, où `#` est un titre.
function sansCommentaires(path: string, body: string): string {
  if (path.endsWith(".md")) return body;
  return body
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");
}

test("le chemin du bundle n'est jamais passé nu à un shell", () => {
  // Le chemin, pas le nom seul : `Wisq` est un préfixe de `WisqVM`, `WisqUI` et
  // six autres identifiants, et chercher le nom nu rendait 181 correspondances
  // dont aucune n'était un appel. Ce qui part dans un shell, c'est le bundle.
  const nom = `${projectName()}.xcodeproj`;
  const nus: string[] = [];
  let vus = 0;
  for (const path of executables()) {
    const body = sansCommentaires(path, read(path));
    for (let at = body.indexOf(nom); at !== -1; at = body.indexOf(nom, at + 1)) {
      vus += 1;
      // Ce qui protège une espace : le guillemet juste avant le nom.
      if (!['"', "'", "`"].includes(body[at - 1] ?? "")) {
        nus.push(`${path} : ${body.slice(Math.max(0, at - 40), at + nom.length)}`);
      }
    }
  }
  expect(
    nus,
    "le nom du projet porte une espace : passé nu, le shell le coupe en deux arguments",
  ).toEqual([]);
  // **Prémisse.** Zéro occurrence satisfait l'assertion ci-dessus sans rien
  // avoir lu — c'est la façon dont cette garde peut mentir. L'inventaire en
  // comptait onze exécutables ; en exiger plus de cinq laisse de la place aux
  // réécritures sans laisser passer un lecteur devenu aveugle.
  expect(vus, "aucune occupation du nom trouvée : le lecteur ne lit plus").toBeGreaterThan(5);
});

/// **Et le tableau, que rien ne tenait.**
///
/// `scripts/check-generated-project.sh` portait sa liste de fichiers engendrés
/// comme une chaîne délimitée par l'espace, parcourue par `for file in
/// $generated`. Avec un bundle qui porte une espace, ce parcours la coupe en
/// `Wisq`, `‣.xcodeproj/project.pbxproj` et `App/Info.plist` — et chacun de ces
/// morceaux est une **sous-chaîne** de la ligne de comparaison que le script
/// cherche. Les trois `case` s'accordent donc, et la garde passe au vert en
/// n'ayant rien comparé de sensé.
///
/// Saboté : remettre la chaîne ne fait tomber **aucun** test. C'est exactement
/// l'assertion satisfaite par un autre chemin que celui qu'elle prétend
/// mesurer, et il fallait donc l'écrire ici.
///
/// **Pourquoi une assertion de forme plutôt que de comportement.** Un test qui
/// distinguerait les deux formes demanderait un workflow fabriqué dont la ligne
/// de comparaison contienne les morceaux sans contenir le chemin entier — un
/// cas qu'on n'écrit que pour faire tomber ce test-là, et qui n'apprend rien.
/// Ce qui compte et se tient est plus simple : la liste est un tableau, et elle
/// se parcourt comme un tableau.
test("la liste des fichiers engendrés survit à une espace", () => {
  const garde = read("scripts/check-generated-project.sh");
  expect(garde, "la liste doit être un tableau bash").toMatch(/^generated=\(/m);
  expect(garde, "et se parcourir sans découpage par l'espace").toContain(
    'for file in "${generated[@]}"',
  );
});
