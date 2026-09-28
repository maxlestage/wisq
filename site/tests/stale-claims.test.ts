/// **Un document qui dit le contraire d'un test qui passe.**
///
/// `docs/DEMARRAGE.md` a pour sujet « ce qui manque pour qu'un noyau démarre ».
/// Son corps est tenu à jour avec soin — chaque chiffre porte sa date et sa
/// commande, et plusieurs paragraphes disent quelle version antérieure ils
/// corrigent. Deux passages, eux, sont restés :
///
/// - la tête annonçait « **deux mécanismes entiers** : la pagination et les
///   interruptions » ;
/// - la section « le mur a un nom » annonçait que les écritures de CR0 et CR3
///   sont **refusées**, et que « soit on marche les tables, soit on ment ».
///
/// Les deux sont faux, et le même fichier le dit cent lignes plus bas : la
/// délivrance d'une faute de page **existe**, `invlpg` vide le tampon, l'IDT est
/// lue, `iretq` est produit. Et `crates/wisq-vm/src/x86_wasm.rs` porte, en tête,
/// que **la forme confinée accepte** ces deux écritures et traverse quatre
/// niveaux de tables — en ajoutant qu'il avait « dit le contraire pendant les
/// deux tranches qui ont suivi celle qui l'a rendu faux ».
///
/// C'est la troisième copie de la même affirmation. #247 a corrigé l'en-tête de
/// l'émetteur et la page du site ; ce document-ci n'a pas été relu. La leçon de
/// #289 mot pour mot : **une garde qui tient deux copies sur trois laisse la
/// troisième dériver**, et personne ne le voit parce que les deux gardées
/// s'accordent.
///
/// **Ce que cette garde ne tient pas** : le reste du document. Elle refuse deux
/// affirmations nommées, chacune parce qu'un test nommé la contredit, et elle
/// vérifie que ce test existe encore — une exception dont le motif a disparu ne
/// garde rien.

import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

/// Le test qui rend l'affirmation fausse doit exister : c'est lui qui donne à
/// l'interdiction son fondement, et non un avis.
///
/// **Sa définition, pas sa mention.** La première version cherchait le nom
/// n'importe où dans un `.rs` ou un `.swift` ; un sabordage qui renommait le test
/// a SURVÉCU, parce que `x86_wasm.rs` cite ce nom deux fois dans ses
/// commentaires. Une garde satisfaite par un commentaire qui parle d'un test
/// disparu ne garde rien — c'est l'assertion satisfaite par un autre chemin, pour
/// la troisième fois en trois tranches.
function definesATest(needle: string): boolean {
  let found = false;
  const walk = (dir: string) => {
    if (found) return;
    for (const entry of readdirSync(dir)) {
      const path = join(dir, entry);
      if (statSync(path).isDirectory()) {
        walk(path);
      } else if (entry.endsWith(".rs") || entry.endsWith(".swift")) {
        const source = readFileSync(path, "utf8");
        if (source.includes(`fn ${needle}(`) || source.includes(`func ${needle}(`)) {
          found = true;
          return;
        }
      }
    }
  };
  for (const root of ["crates", "Tests", "Sources"]) walk(join(repoRoot, root));
  return found;
}

/// Les affirmations refusées, et le test qui les contredit.
const refused = new Map([
  [
    "deux mécanismes entiers",
    {
      document: "docs/DEMARRAGE.md",
      test: "a_page_fault_is_delivered_to_the_guest_and_iretq_resumes_the_faulting_instruction",
      why:
        "la tête du document présentait la pagination et les interruptions comme " +
        "deux mécanismes entièrement absents. La délivrance d'une faute de page " +
        "existe et son test la tient ; le même document la décrit cent lignes " +
        "plus bas.",
    },
  ],
]);

test("aucun document ne porte une affirmation qu'un test nommé contredit", () => {
  for (const [claim, { document, test: named, why }] of refused) {
    expect(
      definesATest(named),
      `l'interdiction de « ${claim} » repose sur ${named}, qui n'existe plus : ` +
        `soit le test a été renommé, soit l'affirmation est redevenue vraie.`,
    ).toBe(true);
    // **Les blancs sont normalisés, et ça n'est pas une commodité.** La
    // première version comparait le texte brut : « deux mécanismes entiers »
    // est coupé par un retour à la ligne dans un document enveloppé à
    // quatre-vingts colonnes, donc l'interdiction ne trouvait rien et passait.
    // Une garde qui ne peut pas échouer, sur la ligne même qu'elle visait.
    const text = readFileSync(join(repoRoot, document), "utf8").replace(/\s+/g, " ");
    expect(text.includes(claim), `${document} : ${why}`).toBe(false);
  }
});

/// **La distinction qui s'était perdue.** Refuser l'écriture de CR0 ou CR3 est
/// vrai de la forme **libre** et faux de la **confinée**, qui est celle que
/// l'application exécute. Un paragraphe qui parle de ces registres et d'un refus
/// — ou d'un mensonge, c'était le mot employé — sans nommer la forme dont il
/// parle est le paragraphe qui a vieilli ici.
test("un paragraphe qui refuse CR0 ou CR3 dit de quelle forme il parle", () => {
  expect(
    definesATest("only_the_confined_form_accepts_the_write_that_drives_paging"),
    "le test qui tient la divergence des deux formes n'existe plus",
  ).toBe(true);

  const document = "docs/DEMARRAGE.md";
  const paragraphs = readFileSync(join(repoRoot, document), "utf8").split(/\n\s*\n/);
  for (const paragraph of paragraphs) {
    const mentionsControl = /\bCR0\b|\bCR3\b/.test(paragraph);
    const mentionsRefusal = /refus|ment\b|mensonge/i.test(paragraph);
    if (!mentionsControl || !mentionsRefusal) continue;
    expect(
      /confinée|libre/i.test(paragraph),
      `${document} : ce paragraphe refuse une écriture de CR0 ou CR3 sans dire ` +
        `de quelle mise en forme il parle. La confinée — celle que ` +
        `l'application exécute — les accepte depuis #247 et traverse quatre ` +
        `niveaux de tables ; seule la forme libre refuse encore.\n\n${paragraph.trim()}`,
    ).toBe(true);
  }
});
