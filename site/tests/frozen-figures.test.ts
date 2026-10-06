/// **Un instrument qui grave une mesure dans ce qu'il imprime.**
///
/// `Sources/wisq-bench/main.swift` imprimait, une ligne sous le débit qu'il
/// venait de calculer : « les 161 MIPS ci-dessus sont ceux du cœur rv32 en
/// Rust ». Deux erreurs en une phrase. Le nombre était gelé — le banc en
/// mesurait un autre à chaque exécution — et l'attribution était fausse : ce
/// banc-là ne dépend que de `WisqVM`, donc il mesure le cœur **Swift**. Le cœur
/// Rust a son propre banc, `wisq-bench-rs`, et personne ne le lançait.
///
/// C'est le mode que le JOURNAL a nommé : « un banc qui mesure deux termes et
/// en grave un troisième publie un nombre dont personne ne vérifiera jamais la
/// provenance : il sort de la même ligne que les vrais, dans la même unité,
/// avec la même autorité. » La consigne qui en sortait était de chercher les
/// constantes numériques **dans le code des instruments**, pas seulement dans
/// leur prose. Voici la garde qui le fait.
///
/// **Ce qu'elle ne tient pas.** Les unités listées ci-dessous, et rien d'autre :
/// un débit gravé en « instructions par seconde » écrit en mots lui échappe.
/// Elle ne lit que les lignes **imprimées** — un commentaire d'en-tête qui cite
/// un chiffre historique est légitime et courant dans ce dépôt, c'est même
/// comme ça qu'un banc explique pourquoi il existe.

import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const roots = ["Sources", "crates", "Tests", "scripts", "web"];
const extensions = [".swift", ".rs", ".ts", ".js", ".mjs", ".py", ".sh"];

/// Une ligne qui sort du programme, pas un commentaire — dans les cinq
/// langages où ce dépôt écrit des instruments.
const printed = /\b(print|println!|eprintln!|write!|writeln!|console\.log)\(|^\s*echo\b/;

/// Un nombre collé à une unité de mesure. Les formats (`%.1f MIPS`,
/// `{mips:.1} MIPS`) ne correspondent pas : ce qui précède l'unité y est une
/// lettre ou une accolade, pas un chiffre.
const frozen = /[0-9][0-9   ,.]*\s*(MIPS|ms|ns|Mio|Mo|MB|Ko|KB)\b/;

/// Un rapport n'a pas d'unité, donc le motif ci-dessus ne le voit pas.
/// Diviser ou multiplier par un littéral **fractionnaire**, dans une ligne
/// imprimée, c'est publier une mesure d'un autre jour sous forme dérivée.
const derived = /[/*]\s*[0-9]+[.,][0-9]/;

type Hit = { file: string; line: number; text: string };

function scan(): { hits: Hit[]; files: number } {
  const hits: Hit[] = [];
  let files = 0;
  const walk = (directory: string) => {
    for (const entry of readdirSync(directory)) {
      const path = join(directory, entry);
      if (statSync(path).isDirectory()) {
        walk(path);
      } else if (extensions.some((suffix) => entry.endsWith(suffix))) {
        files += 1;
        const lines = readFileSync(path, "utf8").split("\n");
        lines.forEach((text, index) => {
          if (printed.test(text) && (frozen.test(text) || derived.test(text))) {
            hits.push({
              file: path.slice(repoRoot.length + 1),
              line: index + 1,
              text: text.trim(),
            });
          }
        });
      }
    }
  };
  for (const root of roots) walk(join(repoRoot, root));
  return { hits, files };
}

/// Les lignes gelées **voulues**, et pourquoi. Même discipline que `notHeld`
/// dans `claims.test.ts` : une exception porte sa raison, ou elle n'existe pas.
const deliberate = new Map([
  [
    "println!(\"  charge de la machine : ce banc a rendu de 125 à 190 ns pour la forme hôte\");",
    "l'inverse d'un nombre gelé : le banc avertit que ses valeurs absolues " +
      "bougent de 125 à 190 ns selon les jours, pour qu'on lise le rapport et " +
      "pas les nanosecondes. Retirer la fourchette retirerait l'avertissement.",
  ],
  [
    "println!(\"version précédente citait 247 MIPS écrits en dur, relevés un autre jour sur\");",
    "l'histoire de ce défaut-ci, dite par l'instrument qui en a été guéri : " +
      "la ligne raconte qu'un 247 était gravé et pourquoi il ne l'est plus.",
  ],
]);

test("aucun instrument n'imprime une mesure gelée sans que ce soit voulu et dit", () => {
  const { hits } = scan();
  for (const hit of hits) {
    expect(
      deliberate.has(hit.text),
      `${hit.file}:${hit.line} imprime un chiffre gelé :\n    ${hit.text}\n` +
        `Un instrument dit ce qu'il a mesuré, pas ce qu'il a mesuré un autre ` +
        `jour. Calcule-le, ou inscris la ligne dans « deliberate » avec sa raison.`,
    ).toBe(true);
  }
});

test("rien ne subsiste dans la liste des exceptions pour une ligne qui a disparu", () => {
  const { hits } = scan();
  const present = new Set(hits.map((hit) => hit.text));
  for (const text of deliberate.keys()) {
    expect(present.has(text), `la ligne n'est plus imprimée nulle part :\n    ${text}`).toBe(
      true,
    );
  }
});

/// **Le lecteur qui ne lit rien ressemble au lecteur qui lit la bonne chose**
/// tant que les deux côtés de la comparaison sont vides. Si l'un des deux
/// motifs cessait de correspondre — une ligne reformatée, une unité renommée —
/// le test ci-dessus passerait en n'ayant rien examiné. Il faut donc que le
/// balayage trouve les fichiers, et qu'il trouve encore les deux lignes voulues.
test("le balayage lit vraiment les sources, et son motif correspond encore", () => {
  const { hits, files } = scan();
  expect(files).toBeGreaterThan(100);
  expect(hits.length).toBeGreaterThanOrEqual(deliberate.size);
});
