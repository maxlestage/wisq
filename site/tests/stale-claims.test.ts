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
/// **Ce que cette garde ne tient pas** : le reste du document. Elle refuse
/// **quatre** affirmations nommées, chacune parce qu'un test nommé la contredit,
/// et elle vérifie que ce test existe encore — une exception dont le motif a
/// disparu ne garde rien.
///
/// **Ce chiffre disait « deux » alors qu'il y en avait trois**, et le même
/// chiffre est faux dans `docs/ROADMAP.md`. Une garde contre les affirmations
/// périmées qui compte mal les siennes est précisément sa propre matière : rien
/// ne tient ce nombre, il se compte à la main, et il est écrit à deux endroits
/// — la forme exacte de #289.

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
  [
    "la délivrance d'une **interruption de matériel** | n'existe pas",
    {
      document: "docs/DEMARRAGE.md",
      test: "a_timer_interrupt_wakes_a_halted_guest_once_until_it_is_acknowledged",
      why:
        "la dernière ligne du tableau des interruptions disait que la " +
        "délivrance d'une interruption de matériel n'existe pas. Le canal zéro " +
        "du 8254 lève IRQ0, le 8259 la route, la boucle hôte l'injecte, et " +
        "cinq tests le tiennent.",
    },
  ],
  [
    "l'hôte ne modélise du 16550 que l'émission à scrutation",
    {
      document: "docs/DEMARRAGE.md",
      test: "the_host_answers_the_probe_the_eight_two_fifty_driver_makes",
      why:
        "le tableau disait que l'hôte ne tient du port série que l'émission " +
        "à scrutation de `printk`, et en concluait que le −EIO du premier " +
        "`write` était une frontière et non un défaut. Les huit registres y " +
        "sont depuis #305, `DLAB` compris, et la ligne quatre monte : le " +
        "noyau imprime « ttyS0 at I/O 0x3f8 (irq = 4, base_baud = 115200) " +
        "is a 16550A ».",
    },
  ],
  [
    "Reste **la délivrance d'une interruption de matériel**",
    {
      document: "docs/DEMARRAGE.md",
      test: "a_halt_waits_for_a_tick_that_has_not_come_yet",
      why:
        "la liste des quatre étapes gardait celle-ci « en partie ». Elle est " +
        "faite, et un `hlt` que le matériel peut réveiller attend au lieu de " +
        "se figer.",
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

/// **La constante a triplé, et la prose du test d'à côté est restée à douze.**
///
/// `X86LegacyDevices.instructionsPerTick` dit combien d'instructions retirées
/// valent un battement du 8253 — donc la vitesse que l'invité croit à son
/// processeur. Elle valait douze ; les tranches qui ont mené Fedora 44 jusqu'au
/// shell l'ont portée à trente-six, parce que les délais de systemd se comptent
/// en temps de l'invité et qu'à douze ils n'y tenaient pas.
///
/// La constante a été changée, et son propre commentaire avec — il contraste
/// même les deux valeurs, exprès. `X86GuestClockTests` ne l'a pas été : son
/// en-tête annonçait l'étalonnage du noyau comme « douze fois le 8253 » avec la
/// ligne de démarrage qui va avec, et le **message d'échec** de sa dernière
/// assertion disait « une fois par douze cycles du TSC ». L'assertion, elle,
/// divisait bien par la constante : elle était juste, et son explication
/// mentait. Un message d'échec faux est pire que pas de message — il envoie
/// chercher un facteur douze qui n'existe plus.
///
/// C'est #313 à la lettre : une phrase qu'on recopie emporte ses nombres et pas
/// leur sens. La défense est la même — faire compter la phrase par ce qu'elle
/// décrit.
///
/// **Ce que cette garde tient, et rien de plus.** Les deux tournures qui
/// énoncent le rapport *d'aujourd'hui* : « N fois le 8253 » et « N cycles du
/// TSC ». Elle ne lit pas « N instructions par battement », et c'est délibéré :
/// le commentaire de la constante oppose les douze d'hier aux trente-six
/// d'aujourd'hui sous cette tournure-là, et une garde qui interdirait le
/// contraste interdirait l'explication. Elle n'ajoute pas non plus une
/// cinquième affirmation nommée à la table ci-dessus — elle dérive son nombre
/// au lieu de le lister, et les quatre restent quatre.
test("le rapport du 8253 écrit en prose est celui de la constante", () => {
  const declaration = readFileSync(
    join(repoRoot, "Sources/WisqVM/X86LegacyDevices.swift"),
    "utf8",
  ).match(/instructionsPerTick:\s*UInt64\s*=\s*(\d+)/);
  expect(
    declaration,
    "`X86LegacyDevices` ne déclare plus `instructionsPerTick` là où ce test le lit",
  ).not.toBeNull();
  const rapport = Number(declaration![1]);
  expect(rapport, "le rapport lu vaut zéro : le motif a cessé de lire le nombre").toBeGreaterThan(0);

  const EN_LETTRES = new Map<string, number>([
    ["un", 1], ["deux", 2], ["trois", 3], ["quatre", 4], ["cinq", 5],
    ["six", 6], ["sept", 7], ["huit", 8], ["neuf", 9], ["dix", 10],
    ["onze", 11], ["douze", 12], ["treize", 13], ["quatorze", 14],
    ["quinze", 15], ["seize", 16], ["dix-sept", 17], ["dix-huit", 18],
    ["dix-neuf", 19], ["vingt", 20], ["vingt-quatre", 24], ["trente", 30],
    ["trente-deux", 32], ["trente-six", 36], ["quarante", 40],
    ["quarante-huit", 48], ["soixante", 60], ["soixante-douze", 72],
  ]);
  const valeur = (jeton: string): number | undefined =>
    /^\d+$/.test(jeton) ? Number(jeton) : EN_LETTRES.get(jeton.toLowerCase());

  /// Les marqueurs de commentaire partent avant que les blancs ne soient
  /// repliés : sans ça, une tournure coupée par un retour à la ligne porte un
  /// `///` au milieu, et le motif ne trouve rien — la garde qui ne peut pas
  /// échouer, sur la ligne même qu'elle vise.
  const aplati = (texte: string) =>
    texte.replace(/^[ \t]*\/\/\/?/gm, " ").replace(/\s+/g, " ");

  const TOURNURE = /([\p{L}\d-]+) (fois le 8253|cycles du TSC)/giu;
  const dits: { fichier: string; phrase: string; n: number }[] = [];
  const parcourir = (dossier: string) => {
    for (const entree of readdirSync(dossier)) {
      const chemin = join(dossier, entree);
      if (statSync(chemin).isDirectory()) {
        parcourir(chemin);
      } else if (entree.endsWith(".swift")) {
        for (const trouve of aplati(readFileSync(chemin, "utf8")).matchAll(TOURNURE)) {
          const n = valeur(trouve[1]!);
          if (n !== undefined) {
            dits.push({
              fichier: chemin.slice(repoRoot.length + 1),
              phrase: trouve[0]!.trim(),
              n,
            });
          }
        }
      }
    }
  };
  for (const racine of ["Sources", "Tests"]) parcourir(join(repoRoot, racine));

  expect(
    dits.length,
    "aucune phrase Swift n'énonce le rapport du 8253 : le motif ne lit plus " +
      "rien, ou la tournure a disparu du dépôt",
  ).toBeGreaterThan(0);

  for (const { fichier, phrase, n } of dits) {
    expect(
      n,
      `${fichier} : « ${phrase} », et \`instructionsPerTick\` vaut ${rapport}`,
    ).toBe(rapport);
  }
});
