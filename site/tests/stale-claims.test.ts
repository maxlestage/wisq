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
import { join, relative } from "node:path";

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
/// **Le bureau refuse quatre endroits et sa prose en compte trois.**
///
/// `LocalDesktop.place` porte, à trois endroits de son propre commentaire, le
/// nombre de refus que le Rust peut rendre :
///
/// - « **Trois endroits sont refusés**, et il n'en tenait qu'un. » ;
/// - « Les **deux autres** sont des régions que la machine se donne à
///   elle-même » — la page zéro et le cadre ;
/// - « **Les trois refus viennent du Rust.** »
///
/// Le `switch` juste en dessous en nomme **cinq**, et `DesktopTranslator`
/// déclare cinq cas de refus. La troisième région, l'archive initramfs, est
/// arrivée avec #313 — dont le titre dit « le bureau n'avait pas de racine » —
/// et la prose d'à côté n'a pas suivi. Le commentaire de `ffi.rs`, lui, a
/// suivi : il disait « l'un des **quatre** » à #312 et dit « l'un des **cinq** »
/// depuis. Deux commentaires sur le même ensemble, et un seul a bougé.
///
/// Le compte était déjà court à sa naissance : à #312 le Rust rendait quatre
/// refus — `ffi.rs` l'écrivait — et `place` en annonçait trois.
///
/// **Les quatre nombres descendent d'une seule source**, l'énumération
/// `Placement`, et aucun ne se recopie :
///
/// - les cas de refus — tous sauf `placeable` et `unknown` — donnent ce que le
///   Rust peut rendre, et `ffi.rs` comme `place` doivent l'annoncer ;
/// - les cas `wouldOverwrite…` donnent les régions que la machine se donne à
///   elle-même ;
/// - les endroits refusés sont ces régions **plus la borne de la RAM**, qui
///   n'est pas une région que la machine se donne : c'est là que s'arrête la
///   mémoire de l'invité.
test("le bureau annonce autant de refus de placement qu'il en déclare", () => {
  const traducteur = readFileSync(
    join(repoRoot, "Sources/WisqVMRust/DesktopTranslator.swift"),
    "utf8",
  );
  const bureau = readFileSync(join(repoRoot, "Sources/WisqVMRust/LocalDesktop.swift"), "utf8");
  const ffi = readFileSync(join(repoRoot, "crates/wisq-vm/src/ffi.rs"), "utf8");

  /// L'énumération, prise entre son accolade ouvrante et la fermante de sa
  /// ligne : la lire en entier ferait entrer les cas des autres types du
  /// fichier, et il y en a.
  const bloc = traducteur.match(/public enum Placement[^{]*\{([\s\S]*?)\n {4}\}/);
  expect(bloc, "`Placement` ne se lit plus dans `DesktopTranslator.swift`").not.toBeNull();
  const cas = [...bloc![1].matchAll(/^ {8}case (\w+)/gm)].map((trouvé) => trouvé[1]);
  expect(cas, "`Placement` a perdu ses cas").toContain("placeable");

  /// **L'échappement est reconnu par sa forme, pas par sa place.** Le seul cas
  /// qui porte une valeur associée est celui qui rend un code inconnu ; le
  /// renommer sans le dire ici le ferait compter comme un refus. L'exclusion
  /// est donc nommée **et** vérifiée.
  const avecValeur = [...bloc![1].matchAll(/^ {8}case (\w+)\(/gm)].map((trouvé) => trouvé[1]);
  expect(avecValeur, "le cas d'échappement de `Placement` n'est plus `unknown`")
    .toEqual(["unknown"]);

  const refus = cas.filter((nom) => nom !== "placeable" && nom !== "unknown");
  const régions = cas.filter((nom) => nom.startsWith("wouldOverwrite"));
  /// Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
  expect(régions.length, "aucune région refusée : le lecteur ne lit plus rien").toBeGreaterThan(1);
  expect(refus.length, "moins de refus que de régions").toBeGreaterThanOrEqual(régions.length);

  const MOTS = [
    "zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit",
    "neuf", "dix", "onze", "douze",
  ];
  const nombre = (mot: string): number => MOTS.indexOf(mot.toLowerCase());

  /// Chaque phrase est tenue par sa **forme** autant que par son nombre : si
  /// l'une est réécrite, le contrôle le dit au lieu de passer sur une phrase
  /// qu'il ne lit plus.
  const annonces: [string, string, RegExp, number][] = [
    [
      "Sources/WisqVMRust/LocalDesktop.swift",
      bureau,
      /\*\*(\p{L}+) endroits sont refusés/u,
      régions.length + 1,
    ],
    [
      "Sources/WisqVMRust/LocalDesktop.swift",
      bureau,
      /Les \*\*(\p{L}+) autres\*\* sont des régions que la machine se donne/u,
      régions.length,
    ],
    [
      "Sources/WisqVMRust/LocalDesktop.swift",
      bureau,
      /Les (\p{L}+) autres refus sont au-dedans de cette borne/u,
      régions.length,
    ],
    [
      "Sources/WisqVMRust/LocalDesktop.swift",
      bureau,
      /\*\*Les (\p{L}+) refus viennent du Rust\*\*/u,
      refus.length,
    ],
    [
      "crates/wisq-vm/src/ffi.rs",
      ffi,
      /les ranger sous l'un des (\p{L}+)/u,
      refus.length,
    ],
  ];

  for (const [fichier, texte, motif, attendu] of annonces) {
    const plat = texte.replace(/^[ \t]*(\/\/\/?|#)[ \t]?/gm, "").replace(/\s+/g, " ");
    const dit = plat.match(motif);
    expect(dit, `${fichier} ne porte plus la phrase ${motif}`).not.toBeNull();
    expect(
      nombre(dit![1]),
      `${fichier} annonce « ${dit![1]} » là où \`Placement\` en déclare ${attendu} ` +
        `(${refus.length} refus, dont ${régions.length} régions)`,
    ).toBe(attendu);
  }
});
/// **Chaque corpus matériel dit sa taille, et quatre des cinq se trompaient.**
///
/// Le dépôt écrit la taille d'un corpus juste après son nom, toujours de la
/// même façon — le fichier, un deux-points, une virgule ou un tiret, puis les
/// comptes :
///
/// - le flottant, dans le cœur : 46 formes, 4 554 cas ;
/// - le SSE2 entier, dans le cœur : 108 formes et 3 240 cas ;
/// - la pile x87, dans le cœur : 67 formes, 3 618 cas ;
/// - le SSE2 entier, dans son test : 4 560 cas ;
/// - l'arithmétique, dans `docs/ARCHITECTURE.md` : 13 388 cas.
///
/// La dernière est juste. Les quatre autres sont le compte du jour où elles
/// ont été écrites : le corpus flottant porte **119 formes et 12 852 cas**,
/// le SSE2 entier **228 et 8 892**, la pile x87 **93 et 5 580**. Et les deux
/// phrases qui décrivent le **même** fichier — celle du cœur et celle du
/// test — ne s'accordaient même pas entre elles : 108 formes contre 152.
///
/// **Cette garde se lit elle-même**, comme celle de #355, et c'est pour ça que
/// les cinq phrases ci-dessus sont citées **sans** leur nom de fichier collé
/// devant : citer la faute dans la forme que la garde refuse serait la
/// commettre. Aucune exclusion n'est posée pour ce fichier — une exclusion
/// est une affirmation de plus, et celle-là n'avait pas lieu d'être.
///
/// **La forme distingue le présent du passé, et c'est voulu.** Un nombre collé
/// au nom du fichier dit ce que le fichier **porte** ; il n'y a donc pas
/// d'exception datée ici, parce qu'un relevé daté ne s'écrit pas comme ça — il
/// s'écrit « il en portait 46 au moment de #NNN », et le mot qui suit le tiret
/// n'est alors pas un chiffre. La garde ne lit que la forme du présent.
test("chaque corpus matériel annonce la taille qu'il a", () => {
  const dossier = join(repoRoot, "Tests/Fixtures");
  /// Les lignes d'un corpus portent leur sorte en première colonne : `instr`
  /// pour une forme, `cas` pour un cas jugé, `état` pour un état d'entrée.
  const UNITÉS: Record<string, string> = { formes: "instr", cas: "cas", états: "état" };
  const corpus = new Map<string, Record<string, number>>();
  for (const entrée of readdirSync(dossier)) {
    if (!entrée.endsWith("-oracle.tsv")) continue;
    const compte: Record<string, number> = {};
    for (const ligne of readFileSync(join(dossier, entrée), "utf8").split("\n")) {
      if (ligne.startsWith("#") || ligne.trim() === "") continue;
      const sorte = ligne.split("\t")[0]!;
      compte[sorte] = (compte[sorte] ?? 0) + 1;
    }
    corpus.set(entrée, compte);
  }
  expect(corpus.size, "aucun corpus matériel lu : le lecteur ne lit plus rien").toBeGreaterThan(5);

  const SKIP = new Set([".git", "node_modules", "dist", "target", ".build", ".heroku-bun"]);
  /// Le journal **cite** les phrases fausses, le `CHANGELOG` et la feuille de
  /// route portent des relevés datés par leur section : ce sont les trois
  /// exclusions que #317 et #359 ont déjà établies, pour la même raison.
  const EXCLUS = new Set(["JOURNAL.md", "ROADMAP.md", "CHANGELOG.md"]);
  const nombre = (brut: string): number =>
    Number.parseInt(brut.replace(/[   ]/g, ""), 10);

  const annonces: Array<{ fichier: string; corpus: string; unité: string; dit: number }> = [];
  const parcourir = (dossier: string) => {
    for (const entrée of readdirSync(dossier)) {
      if (SKIP.has(entrée) || EXCLUS.has(entrée)) continue;
      const chemin = join(dossier, entrée);
      if (statSync(chemin).isDirectory()) {
        parcourir(chemin);
        continue;
      }
      if (!/\.(swift|rs|ts|md|py)$/.test(entrée)) continue;
      let texte: string;
      try {
        texte = readFileSync(chemin, "utf8");
      } catch {
        continue;
      }
      if (!texte.includes("-oracle.tsv")) continue;
      /// Les marqueurs de commentaire partent **avant** l'écrasement des
      /// blancs : un nombre en fin de ligne et son unité au début de la
      /// suivante ne doivent pas échapper au lecteur. `X86Float.swift` écrit
      /// exactement ça — « 46 formes, 4 554 » puis « cas » à la ligne.
      const plat = texte
        .replace(/^[ \t]*(\/\/\/?|\*|#(?!\d)|>|!)[ \t]?/gm, "")
        .replace(/\s+/g, " ");
      const motif = /`?(?:Tests\/Fixtures\/)?(x86[\w-]*-oracle\.tsv)`?/g;
      for (const trouvé of plat.matchAll(motif)) {
        const nom = trouvé[1]!;
        if (!corpus.has(nom)) continue;
        const suite = plat.slice(trouvé.index! + trouvé[0].length);
        const série = suite.match(
          /^\s*[:,—–]\s*((?:\d[\d   ]*?\s*(?:formes|cas|états)(?:\s*(?:,|et)\s*)?)+)/u,
        );
        if (série === null) continue;
        for (const dit of série[1]!.matchAll(/(\d[\d   ]*?)\s*(formes|cas|états)/gu)) {
          annonces.push({
            fichier: relative(repoRoot, chemin),
            corpus: nom,
            unité: dit[2]!,
            dit: nombre(dit[1]!),
          });
        }
      }
    }
  };
  for (const racine of ["Sources", "Tests", "crates", "docs", "scripts", "site"]) {
    parcourir(join(repoRoot, racine));
  }

  /// Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
  expect(
    annonces.length,
    "aucune phrase n'annonce la taille d'un corpus juste après son nom : " +
      "la forme a disparu, et la garde ne tient plus rien",
  ).toBeGreaterThan(3);

  for (const { fichier, corpus: nom, unité, dit } of annonces) {
    const vrai = corpus.get(nom)![UNITÉS[unité]!] ?? 0;
    expect(
      dit,
      `${fichier} annonce « ${dit} ${unité} » pour ${nom}, qui en porte ${vrai}`,
    ).toBe(vrai);
  }
});
