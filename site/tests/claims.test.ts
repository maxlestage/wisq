import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { catalogue } from "./catalogue";

/// The site advertises numbers about the codebase. Numbers on a landing page
/// rot silently, so this reads the repository and fails when a claim stops
/// being true — the same discipline as the protocol guard rails.
const repoRoot = join(import.meta.dir, "..", "..");

/// Both languages: the daemon and the VM core are Rust, and a count that only
/// saw Swift would advertise a smaller number than the repository actually
/// carries — the exact kind of quiet rot this file exists to prevent.
///
/// Counted once and remembered. Three tests below ask for it, and the walk
/// reads every Swift file under `Tests/` and every Rust file under `crates/` —
/// 146 files. Warm that is 16 ms and doing it three times costs nothing worth
/// naming; **cold it is 5 798 ms**, measured on the first read after a
/// container restart, or about 40 ms a file on storage that is not local. That
/// single figure sits above bun's 5 000 ms default, which is how this test
/// timed out once for a reason that had nothing to do with what it checks.
///
/// Memoising takes three cold walks down to one. It does not make the first
/// one fast, and no amount of caching would: the bytes have to arrive. The
/// deliberate non-fix is the timeout — raising it to thirty seconds would end
/// the spurious red and would also stop this test from ever noticing a genuine
/// tenfold slowdown, which is the same blindness as a guard that cannot fail.
/// A rare red with a known cause, written down here, is the better trade.
let counted: number | undefined;

function testCount(): number {
  if (counted !== undefined) return counted;
  let total = 0;
  const walk = (dir: string, extension: string, pattern: RegExp) => {
    for (const entry of readdirSync(dir)) {
      const path = join(dir, entry);
      if (statSync(path).isDirectory()) {
        walk(path, extension, pattern);
      } else if (entry.endsWith(extension)) {
        total += readFileSync(path, "utf8").match(pattern)?.length ?? 0;
      }
    }
  };
  walk(join(repoRoot, "Tests"), ".swift", /^\s*func test[A-Z_]/gm);
  walk(join(repoRoot, "crates"), ".rs", /^\s*#\[test\]/gm);
  counted = total;
  return total;
}

/// Les chiffres que l'accueil publie, tels que le pré-rendu les rend : la copie
/// est dans `crates/wisq-site/src/content.rs` depuis que le front est en Rust,
/// et le catalogue du pré-rendu est sa seule lecture (`tests/catalogue.ts`).
const facts = () => catalogue().copy.en!.facts;

function claimedValue(label: RegExp): number {
  const item = facts().find((entry) => label.test(entry.label));
  if (!item) throw new Error(`aucun chiffre annoncé ne correspond à ${label}`);
  return Number(item.value);
}

/// Les nombres écrits en lettres, dans les deux langues. Hissés au module
/// parce que deux gardes les lisent : le compteur d'inventaire des corpus
/// matériels, et le balayage qui vérifie ce qui vit hors de son périmètre.
/// Recopier une liste de nombres dans un fichier qui garde des nombres
/// recopiés serait une plaisanterie coûteuse.
const FRENCH_NUMBERS = [
  "zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit",
  "neuf", "dix", "onze", "douze", "treize", "quatorze",
];
const ENGLISH_NUMBERS = [
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
  "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
];

describe("advertised claims match the repository", () => {
  test("the test count is the real one", () => {
    expect(claimedValue(/tests/)).toBe(testCount());
  });

  /// The same number is printed in both READMEs, and nothing was watching
  /// them: they sat at 178 while the repository had grown past 200. A claim
  /// with no guard behind it is a claim that will be wrong, so the two files
  /// that state it are read here rather than trusted.
  test.each([
    ["README.md", /tested \((\d+) tests across Swift and Rust\)/],
    ["README.fr.md", /\((\d+) avec ceux du Rust\)/],
  ])("%s states the real test count", (file, pattern) => {
    const text = readFileSync(join(repoRoot, file), "utf8");
    const found = text.match(pattern);
    if (!found) throw new Error(`${file} n'annonce plus de nombre de tests`);
    expect(Number(found[1])).toBe(testCount());
  });

  /// **Le corpus matériel est compté par le fichier, pas par la mémoire.**
  ///
  /// `docs/ARCHITECTURE.md` est le document qu'on lit pour savoir ce qui
  /// existe, et il annonce la taille de `Tests/Fixtures/x86-oracle.tsv`. Ce
  /// nombre grandit à chaque tranche qui pose des formes : il valait 13 220
  /// quand #265 en a ajouté 168, et le document est resté derrière. Rien ne le
  /// surveillait — `claims.test.ts` lisait les deux READMEs et `content.ts`,
  /// jamais celui-là.
  ///
  /// L'ancre est le fichier lui-même, qui se compte tout seul, donc cette garde
  /// ne peut pas prendre de retard. Ce qu'elle ne tient pas : le reste de la
  /// phrase. Elle vérifie le nombre, pas ce qu'on en dit.
  /// **La couture entre le Swift et le Rust, comptée plutôt que citée.**
  ///
  /// `site/src/pages/architecture.ts` annonçait « un C ABI de **sept**
  /// fonctions ». `crates/wisq-vm/src/ffi.rs` en exporte trente et une : la
  /// couture a grossi avec le disque, les instantanés, l'ISO, le bureau et
  /// l'émetteur x86, et la phrase est restée à la poignée du début.
  ///
  /// **Et la garde des chiffres ne pouvait pas le voir** : elle compte les
  /// nombres écrits en **chiffres**, et celui-ci était écrit en lettres. Une
  /// règle générale sur les nombres en lettres ne tient pas — en français « un »
  /// et « une » sont des articles avant d'être des nombres, et ils sont sur
  /// toutes les pages. Ce qui tient, c'est une garde nommée pour une
  /// affirmation nommée, comme celle du compte de tests juste au-dessus. La
  /// page écrit donc le nombre en chiffres, et ce test le compare au code.
  function exportedCFunctions(): { names: string[]; files: string[] } {
    const names = new Set<string>();
    const files = new Set<string>();
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir)) {
        const path = join(dir, entry);
        if (statSync(path).isDirectory()) {
          walk(path);
        } else if (entry.endsWith(".rs")) {
          for (const found of readFileSync(path, "utf8").matchAll(
            /pub (?:unsafe )?extern "C" fn (\w+)/g,
          )) {
            names.add(found[1]);
            files.add(path);
          }
        }
      }
    };
    walk(join(repoRoot, "crates"));
    return { names: [...names].sort(), files: [...files].sort() };
  }

  test("la page d'architecture annonce le vrai nombre de fonctions du C ABI", () => {
    const { names: exported, files } = exportedCFunctions();
    // Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
    expect(exported.length, "aucune fonction `extern \"C\"` trouvée").toBeGreaterThan(5);
    // La page dit aussi « dans un seul fichier », et c'est vérifiable.
    expect(
      files.length,
      `la page dit « dans un seul fichier » et l'ABI est exportée depuis ${files.length} : ` +
        `${files.join(", ")}`,
    ).toBe(1);

    const page = readFileSync(join(pagesDirectory, "architecture.rs"), "utf8");
    for (const [language, pattern] of [
      ["en", /a C ABI of (\d+) functions/],
      ["fr", /une ABI C de (\d+) fonctions/],
    ] as const) {
      const found = page.match(pattern);
      expect(found, `la moitié ${language} n'annonce plus le compte du C ABI`).not.toBeNull();
      expect(
        Number(found![1]),
        `la moitié ${language} annonce ${found![1]} fonctions et `
          + `crates/ en exporte ${exported.length} : ${exported.join(", ")}`,
      ).toBe(exported.length);
    }
  });

  test("ARCHITECTURE.md annonce le vrai nombre de cas de l'oracle", () => {
    const fixture = readFileSync(
      join(repoRoot, "Tests/Fixtures/x86-oracle.tsv"),
      "utf8",
    );
    const cases = fixture.split("\n").filter((line) => line.startsWith("cas\t")).length;
    expect(cases).toBeGreaterThan(1000);
    const text = readFileSync(join(repoRoot, "docs/ARCHITECTURE.md"), "utf8");
    // Le français groupe les milliers par une espace — « 13 388 ». On aplatit
    // les blancs puis on recolle les groupes, pour que la garde juge le nombre
    // et pas la typographie ni la coupure de ligne.
    const flat = text.replace(/\s+/g, " ").replace(/(\d) (?=\d{3}\b)/g, "$1");
    const at = flat.indexOf("cas relevés");
    if (at < 0) {
      throw new Error("ARCHITECTURE.md ne porte plus la phrase du corpus matériel");
    }
    expect(flat.slice(Math.max(0, at - 24), at)).toContain(String(cases));
  });

  /// **Combien de corpus matériels tiennent le cœur — et le nombre est écrit
  /// en mots, donc invisible au compteur de nombres.**
  ///
  /// Trois pages l'annoncent, dans les deux langues, et les **six** copies
  /// disaient « neuf » alors que `Tests/Fixtures/` en porte **dix**. Le
  /// dixième — l'arrondi x87 — est arrivé onze heures après la phrase, le jour
  /// même, et il est **dans** la version 0.4.0 que la note annonce : la note
  /// est donc fausse sur la version qu'elle décrit, et pas seulement périmée.
  ///
  /// **Pourquoi aucune garde ne l'a vu.** Le compteur de ce fichier compte les
  /// *chiffres* et exige une provenance pour chacun ; un nombre écrit en
  /// lettres n'en est pas un pour lui. Même angle mort que la clef de `Map` en
  /// double de #312 : la garde existait, et ne pouvait pas voir ça.
  ///
  /// **Ce que cette garde ne tient pas, et pourquoi.** La même note dit
  /// « assez rare pour survivre à neuf corpus », et « survive nine corpora » :
  /// celles-là **datent un défaut** au lieu d'inventorier les corpus — neuf
  /// était le compte le jour où ce défaut a survécu. Pour celles-là, c'est bien
  /// leur forme qui les écarte : elles ne disent pas « corpus matériels ».
  ///
  /// **Mais la forme n'est pas ce qui définit ce périmètre, et l'écrire était
  /// faux.** Ce qui le définit est la liste de dossiers construite plus bas.
  /// Six constats de `Sources/WisqVM` et de leurs suites écrivent « Cinq
  /// corpus matériels ont épuisé le jeu d'instructions » — la phrase exacte —
  /// et n'étaient dehors que par leur **place**. Un inventaire qui dériverait
  /// là serait resté invisible. Le describe « la phrase des corpus matériels
  /// ne dérive pas là où la garde ne regardait pas » balaie l'arbre entier et
  /// exige de chaque copie hors périmètre qu'elle soit un constat daté, ou
  /// qu'elle n'annonce aucun nombre.

  /// Les oracles matériels, comptés par le répertoire et non par la mémoire.
  ///
  /// **Deux conditions, pas une.** Un fichier nommé « oracle » qui ne viendrait
  /// pas d'un processeur gonflerait le compte : l'en-tête doit nommer le
  /// silicium comme référence, et le script qui l'a fabriqué doit exister, sous
  /// le nom du fichier. Les dix en ont un chacun.
  function hardwareOracles(): string[] {
    const dir = join(repoRoot, "Tests/Fixtures");
    const found: string[] = [];
    for (const entry of readdirSync(dir).sort()) {
      if (!entry.endsWith("-oracle.tsv")) continue;
      const head = readFileSync(join(dir, entry), "utf8").slice(0, 200);
      expect(
        head,
        `${entry} ne nomme pas le processeur comme référence : ce n'est pas un oracle matériel`,
      ).toContain("le vrai processeur");
      const builder = join(repoRoot, "scripts", `build-${entry.replace(/\.tsv$/, "")}.py`);
      expect(existsSync(builder), `${entry} n'a pas de fabricant : ${builder}`).toBe(true);
      found.push(entry);
    }
    return found;
  }

  test("les pages annoncent le vrai nombre de corpus matériels, dans les deux langues", () => {
    const oracles = hardwareOracles();
    // Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
    expect(oracles.length, "aucun oracle matériel trouvé").toBeGreaterThan(5);

    // **Les copies ET leur source.** La page des versions est « tirée du
    // journal des modifications » : corriger le site sans corriger
    // `CHANGELOG.md` laisse la faute à l'endroit d'où elle revient. C'est la
    // forme de #289 dans l'autre sens — tenir les copies et pas l'original.
    //
    // **`docs/JOURNAL.md` est exclu, et par son sujet** : il *cite* les six
    // phrases fausses dans le tableau de la tranche qui les a corrigées. Une
    // garde qui refuserait au journal de dire ce qui était faux lui
    // interdirait de tenir le registre.
    // Le front et sa copie : `crates/wisq-site/src`, depuis que le site n'a
    // plus de source TypeScript. Le périmètre a suivi le contenu, et le compte
    // final — sept — n'a pas bougé, ce qui est la preuve qu'il l'a suivi.
    const sources: string[] = [];
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir)) {
        const path = join(dir, entry);
        if (statSync(path).isDirectory()) walk(path);
        else if (entry.endsWith(".rs")) sources.push(path);
      }
    };
    walk(join(repoRoot, "crates", "wisq-site", "src"));
    for (const entry of readdirSync(join(repoRoot, "docs"))) {
      if (entry.endsWith(".md") && entry !== "JOURNAL.md") {
        sources.push(join(repoRoot, "docs", entry));
      }
    }
    for (const entry of ["CHANGELOG.md", "README.md", "README.fr.md"]) {
      sources.push(join(repoRoot, entry));
    }

    let seen = 0;
    for (const path of sources) {
      const text = readFileSync(path, "utf8");
      for (const [words, pattern] of [
        [FRENCH_NUMBERS, /([\p{L}]+) corpus matériels/gu],
        [ENGLISH_NUMBERS, /([\p{L}]+) hardware corpora/giu],
      ] as const) {
        for (const found of text.matchAll(pattern)) {
          seen += 1;
          const said = found[1].toLowerCase();
          expect(
            words.indexOf(said),
            `${path} écrit « ${found[0]} », un mot qui n'est pas un nombre de cette liste`,
          ).toBeGreaterThanOrEqual(0);
          expect(
            said,
            `${path} annonce « ${found[0]} » et Tests/Fixtures/ en porte ` +
              `${oracles.length} : ${oracles.join(", ")}`,
          ).toBe(words[oracles.length]);
        }
      }
    }
    // **Et la garde se garde elle-même.** Si les pages cessaient de dire la
    // phrase, cette boucle ne vérifierait plus rien en silence — c'est
    // exactement comment ce nombre a dérivé un mois durant.
    expect(seen, "plus aucune page n'annonce le nombre de corpus matériels").toBe(7);
  });

  /// **Le même tableau, dans deux langues, et une seule des deux à jour.**
  ///
  /// Les deux READMEs portent le tableau de comparaison avec UTM SE. Le
  /// contenu d'une cellule ne se compare pas d'une langue à l'autre — mais le
  /// NOMBRE DE LIGNES, oui, et c'est l'invariant le moins cher qui aurait
  /// attrapé ce qui s'est passé : le tableau anglais a gagné le mode local et
  /// le français est resté à l'époque où wisq ne faisait que du distant, avec
  /// en plus une ligne « Autonomie » que l'anglais n'a jamais eue. Quatre
  /// lignes contre cinq, et les deux fichiers se contredisaient.
  ///
  /// Ce que cette garde ne tient pas, et il faut le dire : elle ne lit pas ce
  /// que les cellules affirment. Deux tableaux de même hauteur peuvent mentir
  /// chacun de son côté. Elle tient qu'une ligne ajoutée ou retirée d'un seul
  /// côté rougisse, ce que rien ne tenait.
  test("les deux READMEs portent un tableau de comparaison de même hauteur", () => {
    const rows = (file: string) => {
      const text = readFileSync(join(repoRoot, file), "utf8");
      const table = text.match(/^\| \| UTM SE.*?(?=\n\n)/ms);
      if (!table) throw new Error(`${file} ne porte plus de tableau UTM SE`);
      return table[0]
        .split("\n")
        .filter((line) => line.startsWith("|") && !/^\|\s*\|/.test(line) && !/^\|-/.test(line));
    };
    const english = rows("README.md");
    const french = rows("README.fr.md");
    expect(english.length).toBeGreaterThan(3);
    expect(french.length).toBe(english.length);
  });

  // Two tests lived here, both about the releases page: that every version it
  // listed had a dated changelog entry, and that it carried a section for
  // each. The page is gone, and with it the restated content that could rot.
  // What the site still claims about a version — the one in the footer — is
  // checked against the changelog in build.test.ts.

  /// **Une porte est une porte, quel que soit le fichier qui la pose.**
  ///
  /// Cette garde ne lisait que `ci.yml`, et ajoutait un pour GitGuardian. Elle
  /// comptait donc cinq jobs plus un, soit six, et le site annonçait six :
  /// vert des deux côtés. Mais une pull request en porte **sept** — `site.yml`
  /// se déclenche sur `pull_request` sans filtre de chemin, et pose « Build
  /// site ». Personne ne le comptait.
  ///
  /// L'ironie vaut d'être écrite plutôt que tue : ce test-ci **tourne dans le
  /// job qu'il oubliait**. `site.yml` est l'endroit où `bun test` s'exécute, et
  /// c'est le seul des deux fichiers que la garde ne regardait pas.
  ///
  /// D'où la forme : on ne nomme plus un fichier, on cherche **tous** ceux qui
  /// se déclenchent sur `pull_request`. Ajouter un workflow qui garde une
  /// PR — ou en retirer un — fait bouger le compte tout seul. Le `+ 1` reste
  /// GitGuardian, qui ne vient d'aucun fichier d'ici.
  test("the CI gate count matches every workflow that gates a pull request", () => {
    const directory = join(repoRoot, ".github/workflows");
    let jobs = 0;
    const gating: string[] = [];
    for (const name of readdirSync(directory).filter((f) => /\.ya?ml$/.test(f))) {
      const workflow = readFileSync(join(directory, name), "utf8");
      // Le bloc `on:` seul : d'une ligne `on:` en colonne zéro jusqu'à la
      // prochaine clé de premier niveau. Chercher « pull_request » dans le
      // fichier entier compterait un workflow qui n'en parle qu'en commentaire.
      const opens = workflow.match(/^on:\n(?:[ \t].*\n|\n)*/m);
      if (!opens || !/^\s+pull_request:?\s*$/m.test(opens[0])) continue;
      gating.push(name);
      // Count two-space keys only after the `jobs:` line — `on:` has children
      // at the same indentation and would otherwise be counted as jobs.
      const jobsSection = workflow.slice(workflow.indexOf("\njobs:"));
      jobs += jobsSection.match(/^ {2}[a-z][\w-]*:$/gm)?.length ?? 0;
    }
    // Une garde qui ne trouverait aucun workflow passerait en comparant zéro à
    // zéro le jour où le format change. Elle doit en trouver, et les nommer.
    expect(gating.length, "aucun workflow ne se déclenche sur pull_request").toBeGreaterThan(0);
    expect(jobs, `jobs comptés dans ${gating.join(", ") || "aucun fichier"}`).toBeGreaterThan(0);
    // The site counts GitGuardian alongside our own jobs.
    expect(claimedValue(/gates|portes/)).toBe(jobs + 1);
  });

  /// **Les chiffres que ce fichier ne tient pas, nommés plutôt que tus.**
  ///
  /// Ce fichier vérifie deux des quatre chiffres publiés. Un lecteur — et
  /// l'auteur de ces lignes le premier — en conclut raisonnablement que les
  /// quatre le sont : rien ici ne dit le contraire, et le commentaire de
  /// `content.ts` promet que la garde « échoue quand un chiffre cesse d'être
  /// vrai ».
  ///
  /// **Le silence est le défaut**, pas la décision qui manque. Ce qui suit ne
  /// prétend pas tenir ces deux chiffres : ça tient une autre propriété, et
  /// elle est réelle — **aucun chiffre publié n'échappe à l'examen sans qu'on
  /// l'ait écrit**. Un cinquième chiffre ajouté au site fait rougir ce test
  /// jusqu'à ce que quelqu'un décide de quel côté il tombe.
  ///
  /// Pourquoi ces deux-là ne sont pas tenus, et pourquoi le remède n'est pas
  /// d'ici :
  ///
  /// - « 0 avertissement, concurrence stricte » — le mécanisme existe
  ///   (`SWIFT_STRICT_CONCURRENCY: complete` à trois endroits de `project.yml`,
  ///   `swift-tools-version 6.0`), mais **aucun `-warnings-as-errors` nulle
  ///   part**. Un avertissement apparaîtrait sans rougir la CI. L'ajouter est
  ///   une décision de politique : elle rendrait rouge un dépôt qui compile.
  /// - « 1 vrai noyau démarré par exécution CI » — l'étape le récupère en
  ///   « best effort » (`|| true`) et saute avec un `::warning::` s'il manque,
  ///   ce que le commentaire de l'étape énonce, donc délibérément. Une
  ///   exécution peut démarrer zéro noyau et rester verte. Rendre ça rouge est
  ///   la même nature de décision : une panne d'un téléchargement tiers
  ///   rougirait le dépôt.
  ///
  /// Une garde qui se contenterait de vérifier que l'étape *existe* serait
  /// « une assertion qui a l'air d'une garde » : elle tiendrait le mécanisme,
  /// pas le nombre. Aucun des deux chiffres n'est établi comme faux
  /// aujourd'hui ; ils sont **non tenus**, et c'est ça qui est écrit.
  const notHeld = new Map([
    [
      "warnings, strict concurrency",
      "aucun -warnings-as-errors nulle part : un avertissement n'ouvre aucune porte",
    ],
    [
      "real kernel booted per CI run",
      "l'étape récupère l'image en best effort et saute si elle manque",
    ],
  ]);

  test("every advertised figure is either checked here or named as unheld", () => {
    const checked = [/tests/, /gates|portes/];
    for (const item of facts()) {
      const held = checked.some((pattern) => pattern.test(item.label));
      const named = notHeld.has(item.label);
      expect(
        held || named,
        `le site publie « ${item.value} ${item.label} » et rien ici ne le ` +
          `vérifie ni ne dit pourquoi. Ajoute une vérification, ou inscris-le ` +
          `dans notHeld avec sa raison — un chiffre publié ne passe pas en silence.`,
      ).toBe(true);
      // **Et pas les deux.** Un chiffre qui serait à la fois vérifié et
      // déclaré non tenu laisserait une entrée périmée derrière une garde qui
      // marche, jusqu'à ce que quelqu'un lise la liste et la croie.
      expect(
        held && named,
        `« ${item.label} » est vérifié ici *et* inscrit comme non tenu ; ` +
          `l'entrée de notHeld est périmée.`,
      ).toBe(false);
    }
  });

  /// La liste ne doit pas survivre à ce qu'elle décrit : une raison écrite pour
  /// un chiffre que le site n'affiche plus est une explication sans objet, et
  /// elle se lit comme une lacune qui n'existe pas.
  test("nothing lingers in the unheld list for a figure the site no longer shows", () => {
    const published = new Set(facts().map((item) => item.label));
    for (const label of notHeld.keys()) {
      expect(published.has(label), `« ${label} » n'est plus publié`).toBe(true);
    }
  });
});

/// **La page publique ne vit pas dans `content.ts`, et la garde d'à côté n'y
/// regardait pas.**
///
/// Le test précédent tient une invariante réelle — aucun chiffre du bloc
/// `facts` n'échappe à l'examen — et elle a été lue comme si elle valait pour
/// le site. Elle ne vaut que pour quatre nombres. `src/pages/roadmap.ts`
/// décrit le travail en cours **au présent**, et en portait cinq autres que
/// rien ne regardait : deux étaient faux, un était faux dans le sens
/// défavorable au projet, et un cinquième n'avait plus de sens depuis que le
/// banc s'était scindé.
///
/// **Un balayage par unité les aurait manqués.** Chercher « un nombre suivi de
/// MIPS, de `ns`, de `%` » laisse passer « ISO 9660 » — ce qui est heureux ici,
/// puisque ce n'en est pas un — mais laisserait passer tout autant un chiffre
/// écrit sans son unité. Ce test compte donc **les nombres**, et demande pour
/// chacun une ligne qui dit d'où il vient. La justification est le produit :
/// une liste de commandes relançables, et un refus net dès qu'un nombre
/// apparaît sans la sienne.
///
/// **Et la garde écrite ce jour-là ne disait pas non plus où elle ne regardait
/// pas.** Le signe à retenir de cette tranche tenait pourtant en une phrase :
/// « une garde devrait dire non seulement ce qu'elle ne vérifie pas, mais **où
/// elle ne regarde pas** ». Elle lisait une page sur neuf, et les huit autres
/// ont continué de publier des chiffres que rien ne relisait. L'une d'elles,
/// `protocol.ts`, annonçait un démon de **582 Ko** dans les deux langues : le
/// binaire musl que la release publie en fait **1 778 384 octets**, soit trois
/// fois plus. Le nombre avait été vrai — avant que le démon n'apprenne le TLS
/// et l'appairage — et `docs/AGENT-PROTOCOL.md` avait été corrigé le
/// 2 septembre 2026 sur exactement ce point. La page du site ne l'avait pas
/// appris, parce que personne ne la lisait.
///
/// Le périmètre est donc énoncé ici, page par page, et il ne peut plus croître
/// en silence. Toute page de `src/pages/` est dans **une** des trois listes :
/// tenue — chacun de ses nombres porte une ligne qui dit d'où il vient —,
/// avouée non tenue avec la liste exacte des chiffres qu'elle publie, ou
/// nommée hors sujet avec la garde qui s'en occupe, et la garde en question
/// doit vraiment lire le fichier. Une page ajoutée n'est dans aucune des
/// trois, et elle est refusée ; un chiffre ajouté à une page avouée change sa
/// liste, et il est refusé aussi. L'aveu n'est pas une vérification : c'est
/// une dette, tenue à jour de force.
///
/// **Ce que rien ici ne tient, et il faut le dire : la prose autour du
/// nombre.** « 64 Mo de RAM » est resté juste comme chiffre et faux comme
/// phrase le jour où la taille de la machine est devenue un réglage — aucun
/// compteur de nombres ne voit ça, et ce n'est pas un compteur qui l'a trouvé.
/// **Les pages sont des fichiers Rust depuis que le front est en Yew**, un par
/// page comme avant : `docs.rs` au lieu de `docs.ts`, `mod.rs` au lieu de
/// `index.ts`. Le compteur lit le fichier entier, code compris ; les pages ne
/// portent que des données, donc les seuls nombres qu'il y trouve sont ceux
/// que le site publie — et c'est pourquoi les gardes du contenu vivent dans
/// `crates/wisq-site/src/contenu_tests.rs` et non à côté des pages.
const pagesDirectory = join(repoRoot, "crates", "wisq-site", "src", "pages");

/// Un nombre, éventuellement à espaces ou à virgule, qui n'est pas collé à un
/// mot ni à un trait d'union : « x86-64 » et « rv32ima » ne sont pas des
/// chiffres publiés, « 10 116 » en est un.
const publishedNumber = /(?<![-\w])\d[\d   ]*(?:[.,]\d+)?(?![\w])/g;

function pageFiles(): string[] {
  return readdirSync(pagesDirectory)
    .filter((name) => name.endsWith(".rs"))
    .sort();
}

function figuresOn(page: string): string[] {
  const text = readFileSync(join(pagesDirectory, page), "utf8");
  return [
    ...new Set((text.match(publishedNumber) ?? []).map((raw) => raw.trim())),
  ].sort();
}

/// **Une `Map` construite d'un littéral avale ses doublons en silence**, et ce
/// dépôt l'a payé : la provenance du compte du C ABI et celle de la borne basse
/// de « construction 33–194 ms » portaient toutes deux la clé `"33"`, parce que
/// la couture faisait alors trente-trois fonctions. La seconde effaçait la
/// première, et les deux tests ci-dessous passaient quand même — l'un parce que
/// la page porte bien ce nombre, l'autre parce qu'une seule entrée restait.
/// Vu en portant la couture à trente-quatre, pas en relisant.
///
/// Les doublons sont **collectés plutôt que levés** : une exception à
/// l'importation ferait rougir tout le fichier sans nommer la cause, et
/// « quelle garde tombe » est la question qu'on se posera.
const duplicated: string[] = [];

function provenanceOf(entries: [string, string][]): Map<string, string> {
  const held = new Map<string, string>();
  for (const [number, why] of entries) {
    if (held.has(number)) duplicated.push(number);
    held.set(number, why);
  }
  return held;
}

/// Les pages tenues. Chaque entrée dit **comment on refait le nombre**, ou
/// pourquoi ce n'est pas une mesure. Une entrée qui ne saurait dire ni l'un ni
/// l'autre n'a rien à faire sur une page qui parle au présent.
const accounted = new Map<string, Map<string, string>>([
  [
    "roadmap.rs",
    provenanceOf([
      [
        "10 116",
        "les régions d'entrée atteintes par un `call` du noyau Alpine : " +
          "`cargo run -p wisq-vm --release --example coverage -- <noyau>`. " +
          "Pas tenu par la CI — l'étape récupère l'image en best effort.",
      ],
      [
        "9660",
        "ce n'est pas une mesure : c'est le numéro de la norme ISO des " +
          "systèmes de fichiers de disque optique.",
      ],
      [
        "3.8",
        "ce n'est pas une mesure : la version du protocole RFB que parle le client VNC — README.md, « RFB 3.8 client: handshake, DES auth… », et `docs/ROADMAP.md`, lot 1, « client VNC RFB 3.8 ».",
      ],
      [
        "4.7",
        "ce n'est pas une mesure : le numéro de la règle de l'App Store que README.md cite (« grey area, rule 4.7 ») et que `docs/ROADMAP.md` écarte dans « Contraintes à garder en tête ».",
      ],
      [
        "16",
        "ce n'est pas une mesure : le plafond de mémoire de la machine PC, 16 Gio — `Sources/WisqVM/GuestArchitecture.swift`, `case .x86_64: return 16 << 30`, le choix de l'auteur que #283 a posé dans `docs/ROADMAP.md`.",
      ],
      [
        "2",
        "ce n'est pas une mesure : deux bornes de 2 Gio, toutes deux écrites dans le code — la limite d'adressage du rv32 (`LinuxMachine.maximumRAMSize = 2 * 1024 * 1024 * 1024`) et la part que l'application laisse à l'appareil (`KernelMemory.leftToTheDevice = 2 << 30`).",
      ],
      [
        "32",
        "ce n'est pas une mesure : la largeur de la machine rv32, la première des trois raisons du passage à x86-64 — `docs/ROADMAP.md`, lot 7, « la machine est en **32 bits** ».",
      ],
      [
        "264",
        "ce n'est pas une mesure : le nom du codec vidéo H.264, que `docs/ROADMAP.md` (lot 3, « Ce qui reste ») range avec RemoteFX parmi ce qui manque à RDP.",
      ],
    ]),
  ],
  [
    "protocol.rs",
    provenanceOf([
      [
        "0.1",
        "ce n'est pas une mesure : la seconde moitié de l'adresse de bouclage " +
          "127.0.0.1, que le découpage en nombres sépare de la première.",
      ],
      [
        "127.0",
        "ce n'est pas une mesure : la première moitié de la même adresse de " +
          "bouclage, celle que le démon refuse d'annoncer dans un lien.",
      ],
      [
        "1.1",
        "ce n'est pas une mesure : la version de HTTP que le démon parle — " +
          "`crates/wisq-agent/src/http.rs`, « A minimal HTTP/1.1 server on the " +
          "standard library ».",
      ],
      [
        "13",
        "ce n'est pas une mesure : le `13` de `debian-13`, la VM que sert le " +
          "backend de démonstration — `crates/wisq-agent/src/backend.rs`, " +
          "`Vm::new(\"debian-13\", \"Debian 13\", State::Stopped)`.",
      ],
      [
        "404",
        "ce n'est pas une mesure : le code que `Service::handle` rend pour un " +
          "identifiant inconnu ou invalide — `crates/wisq-agent/src/service.rs`.",
      ],
      [
        "426",
        "ce n'est pas une mesure : `426 Upgrade Required`, ce que le démon " +
          "répond à un client en HTTP clair — `crates/wisq-agent/src/http.rs`, " +
          "et `assert!(reply.starts_with(\"HTTP/1.1 426\"))` dans le même fichier.",
      ],
      [
        "5901",
        "ce n'est pas une mesure : le port de console de la VM de " +
          "démonstration (`running_port: 5901` dans `backend.rs`), qui est " +
          "aussi l'écran VNC :1, soit 5900 + 1.",
      ],
      [
        "7442",
        "ce n'est pas une mesure : le port par défaut du démon — " +
          "`crates/wisq-agent/src/main.rs`, `let mut port: u16 = 7442`.",
      ],
      [
        "58",
        "historique, et non relançable : le démon d'avant, lié statiquement au " +
          "runtime Swift, pesait 58 Mo. Ce binaire n'existe plus — le nombre " +
          "est daté, consigné au CHANGELOG, et il est publié comme un avant.",
      ],
      [
        "1.7",
        "tenu, pas seulement mesuré : `scripts/check-agent-size.sh` compare " +
          "cette phrase au binaire que la CI construit déjà dans son job Rust " +
          "(`cargo build --release --target x86_64-unknown-linux-musl " +
          "-p wisq-agent`), avec les sept autres textes qui annoncent la même " +
          "taille. 1 749 840 octets le 8 octobre 2026 sous rustc 1.99, soit " +
          "1,7 Mo décimaux ; 1 778 384 octets le 28 septembre 2026 sous la " +
          "chaîne d'alors, soit 1,8. Le démon maigrit et grossit avec son " +
          "compilateur sans que personne ne commette rien, et c'est justement " +
          "pour ça que la phrase est tenue plutôt que datée.",
      ],
      [
        "1,7",
        "le même nombre dans l'autre langue : la page est écrite deux fois, et " +
          "la virgule décimale en fait un jeton distinct. Tenu par la même " +
          "garde, qui lit les deux phrases séparément.",
      ],
      [
        "0",
        "ce n'est pas une mesure : le port que `--port 0` demande pour laisser le système choisir — `crates/wisq-agent/src/http.rs`, `Server::bind` (« pass 0 for an ephemeral one »), ce que `Tests/WisqAgentTests/RustAgentProcess.swift` passe.",
      ],
      [
        "0.0",
        "ce n'est pas une mesure : les deux moitiés de 0.0.0.0, que le découpage en nombres sépare — l'adresse de toutes les interfaces IPv4 où le démon écoute (`http.rs`, `TcpListener::bind((\"0.0.0.0\", port))`), et celle où `wisq-agent bureau` fait écouter SPICE par défaut (`main.rs`).",
      ],
      [
        "0.3",
        "ce n'est pas une mesure : la version qui a apporté TLS au démon — CHANGELOG, section [0.3.0], et l'aide de `wisq-agent --help` (« pour un client d'avant 0.3 », `crates/wisq-agent/src/main.rs`).",
      ],
      [
        "0600",
        "ce n'est pas une mesure : le mode des fichiers secrets, `.mode(0o600)` dans `write_owner_only` — `main.rs` pour le jeton, `tls.rs` pour le certificat et la clé.",
      ],
      [
        "0644",
        "ce n'est pas une mesure : le mode qu'avait le jeton avant la correction, sous l'umask habituel — commentaire de `resolve_stored_token`, `crates/wisq-agent/src/main.rs` (« 0644 under the usual umask … Measured: 644, then 600 »).",
      ],
      [
        "0700",
        "ce n'est pas une mesure : le mode du répertoire d'état, `Permissions::from_mode(0o700)` — `set_owner_only_directory` dans `main.rs`, `owner_only_directory` dans `tls.rs`.",
      ],
      [
        "1",
        "ce n'est pas une mesure : la borne basse des ports qu'accepte l'application, `(1...65535).contains(port)` dans `Validation.validatedPort` (`Sources/WisqCore/Validation.swift`).",
      ],
      [
        "65535",
        "ce n'est pas une mesure : la borne haute de la même plage, même fichier ; c'est aussi le plus grand `u16`, le type du port côté démon (« --port attend un nombre entre 1 et 65535 », `main.rs`).",
      ],
      [
        "100",
        "ce n'est pas une mesure : le nombre de tours du test qui observe l'écriture d'un secret, `for _ in 0..100` dans `a_secret_is_never_world_readable_even_for_an_instant` (`crates/wisq-agent/src/tls.rs`), celui sur lequel le relevé de 747 a été fait.",
      ],
      [
        "747",
        "historique, et non relançable tel quel : les observations d'un mode autre que 0600 en 100 tours contre l'ancienne forme « écrire puis restreindre », relevées avant la correction — commentaire de `a_secret_is_never_world_readable_even_for_an_instant` (`tls.rs`) et CHANGELOG, section 0.4.0. L'ancienne forme n'existe plus ; le test tourne à chaque `cargo test` et exige zéro.",
      ],
      [
        "11",
        "ce n'est pas une mesure : le `11` de « Windows 11 », la seconde VM du backend de démonstration — `crates/wisq-agent/src/backend.rs`, `Vm::new(\"win11\", \"Windows 11\", State::Stopped)`.",
      ],
      [
        "120",
        "relevé, pas une performance : la longueur en octets du corps JSON montré dans le même bloc, que le démon écrit dans `Content-Length`. Refaire : `cargo run -p wisq-agent -- --demo --no-tls --token t`, puis `curl -si -H 'Authorization: Bearer t' http://127.0.0.1:7442/v1/vms/debian-13`.",
      ],
      [
        "92",
        "relevé de la même façon : la longueur du corps de la réponse 426, le message écrit dans `handle_connection` (`crates/wisq-agent/src/http.rs`), le é de « ré-appairez » comptant deux octets. Refaire : `cargo run -p wisq-agent -- --demo` (TLS par défaut), puis `curl -si http://127.0.0.1:7442/v1/vms`.",
      ],
      [
        "15",
        "ce n'est pas une mesure : `request.timeoutInterval = 15` dans `AgentClient.send` (`Sources/WisqRemote/Agent/AgentClient.swift`).",
      ],
      [
        "16",
        "ce n'est pas une mesure : `MAX_HEADER_BYTES = 16 * 1024` dans `crates/wisq-agent/src/http.rs`.",
      ],
      [
        "64",
        "ce n'est pas une mesure : trois constantes du code — `MAX_BODY_BYTES = 64 * 1024` (`http.rs`), les 64 caractères hexadécimaux d'un SHA-256 (`assert_eq!(hex.len(), 64)` dans `tls.rs` et `pairing.rs`), et le disque par défaut de `wisq-agent bureau` (`let mut disk_gib: u32 = 64`, `main.rs`).",
      ],
      [
        "2",
        "ce n'est pas une mesure : l'intervalle de sondage par défaut de l'application (`pollInterval: Duration = .seconds(2)` dans `AgentClient.waitUntilRunning`, `ConsoleResolver.resolve` et `VMPower.shutDown`), les 2 Gio de la VM Debian de démonstration (`backend.rs`), et le code de sortie de `fail` (`std::process::exit(2)`, `main.rs`).",
      ],
      [
        "20",
        "ce n'est pas une mesure : l'échéance des sockets, `Duration::from_secs(20)` dans `handle_connection` (`http.rs`), et la longueur du mot de passe SPICE de `wisq-agent bureau`, `[0u8; 20]` dans `generate_password` (`crates/wisq-agent/src/domain.rs`).",
      ],
      [
        "200",
        "ce n'est pas une mesure : le statut de succès, `Response::json(200, …)` dans `crates/wisq-agent/src/service.rs`.",
      ],
      [
        "2097152",
        "ce n'est pas une mesure : `2 * 1024 * 1024` Kio, la mémoire courante et maximale de la VM Debian de démonstration (`backend.rs`) ; c'est ce que `wisq-agent --demo` écrit, et `testTheMemoryFiguresCrossTheLanguageBoundary` le relit.",
      ],
      [
        "4194304",
        "ce n'est pas une mesure : `4 * 1024 * 1024` Kio, la mémoire courante de la VM Windows de démonstration — `backend.rs`.",
      ],
      [
        "8388608",
        "ce n'est pas une mesure : `8 * 1024 * 1024` Kio, le maximum de la même VM — `backend.rs`.",
      ],
      [
        "4",
        "ce n'est pas une mesure : les 4 Gio courants de la VM Windows de démonstration (`backend.rs`) et les 4 processeurs par défaut de `wisq-agent bureau` (`let mut cpus: u32 = 4`, `main.rs`).",
      ],
      [
        "8",
        "ce n'est pas une mesure : les 8 Gio de maximum de la VM Windows de démonstration — `backend.rs`.",
      ],
      [
        "4096",
        "ce n'est pas une mesure : la mémoire par défaut de `wisq-agent bureau`, `let mut memory_mib: u32 = 4096` (`main.rs`).",
      ],
      [
        "255",
        "ce n'est pas une mesure : la longueur maximale d'un identifiant de VM, `id.len() <= 255` dans `is_plausible_domain_name` (`service.rs`) et `id.utf8.count <= 255` dans `Validation.validatedVMIdentifier`.",
      ],
      [
        "3",
        "ce n'est pas une mesure : l'écran VNC de l'exemple `vnc://localhost:3`, relevé sur libvirt et repris du commentaire de `parse_domdisplay` (`backend.rs`) et du tableau de `docs/AGENT-PROTOCOL.md`.",
      ],
      [
        "5903",
        "ce n'est pas une mesure : le port que le démon déduit de cet écran, 5900 + 3 — même commentaire, et `a_vnc_domain_still_publishes_its_console_through_domdisplay` qui l'exige.",
      ],
      [
        "5900",
        "ce n'est pas une mesure : la base des ports VNC, `5900u16.checked_add(…)` dans `parse_display_uri` et `parse_vnc_display` (`backend.rs`).",
      ],
      [
        "5907",
        "ce n'est pas une mesure : le `tls-port=5907` de l'exemple d'un SPICE en TLS seul, relevé sur libvirt — commentaire de `parse_domdisplay` (`backend.rs`) et tableau de `docs/AGENT-PROTOCOL.md`.",
      ],
      [
        "5902",
        "ce n'est pas une mesure : le port de console de la VM Windows de démonstration, `running_port: 5902` dans `backend.rs`.",
      ],
      [
        "32",
        "ce n'est pas une mesure : la longueur du jeton généré (`[0u8; 32]` dans `generate_token`, `main.rs`) et celle d'une empreinte en octets (`AgentPairing.fingerprintByteCount = 32`, `Sources/WisqCore/AgentPairing.swift`).",
      ],
      [
        "400",
        "ce n'est pas une mesure : le statut d'une requête mal formée, `Response::error(400, …)` dans `read_request` (`crates/wisq-agent/src/http.rs`) — ligne de requête incomplète, Content-Length invalide ou répété.",
      ],
      [
        "401",
        "ce n'est pas une mesure : `Response::error(401, \"jeton manquant ou invalide\")`, première ligne de `Service::handle` (`service.rs`).",
      ],
      [
        "405",
        "ce n'est pas une mesure : `Response::error(405, …)`, le dernier bras de `Service::handle` (`service.rs`).",
      ],
      [
        "413",
        "ce n'est pas une mesure : `Response::error(413, …)` pour des en-têtes ou un corps trop volumineux — `read_request`, `http.rs`.",
      ],
      [
        "500",
        "ce n'est pas une mesure : `Response::error(500, &message)` quand `list` ou `get` du backend échoue — `service.rs`.",
      ],
      [
        "501",
        "ce n'est pas une mesure : `Response::error(501, \"Transfer-Encoding non pris en charge\")` dans `read_request` (`http.rs`), tenu par `a_chunked_request_is_refused_rather_than_silently_emptied`.",
      ],
      [
        "90",
        "ce n'est pas une mesure : la patience par défaut de l'application — `timeout: Duration = .seconds(90)` dans `AgentClient.waitUntilRunning` et `ConsoleResolver.resolve`, `patience: Duration = .seconds(90)` dans `VMPower.shutDown`.",
      ],
      [
        "9112",
        "ce n'est pas une mesure : le numéro de la RFC de HTTP/1.1 que citent les commentaires de `read_request` (`crates/wisq-agent/src/http.rs`, « RFC 9112 §6.3 »).",
      ],
      [
        "9999",
        "ce n'est pas une mesure : l'année d'expiration du certificat, `rcgen::date_time_ymd(9999, 1, 1)` dans `generate` (`crates/wisq-agent/src/tls.rs`).",
      ],
    ]),
  ],
  [
    "faq.rs",
    provenanceOf([
      [
        "44.6",
        "le compte d'instructions jusqu'à l'invite de connexion, et il est " +
          "**déterministe** : l'horloge de la machine avance avec les " +
          "instructions retirées, pas avec le temps réel. Dix passages — cinq " +
          "par cœur — ont rendu 44,6 M exactement. Imprimé par les deux bancs, " +
          "`swift run -c release wisq-bench` et " +
          "`cargo run --release --bin wisq-bench-rs`, que la CI lance tous les deux.",
      ],
      [
        "44,6",
        "le même compte dans l'autre langue : la page est écrite deux fois, et " +
          "la virgule décimale en fait un jeton distinct.",
      ],
      [
        "0.24",
        "le démarrage le plus rapide observé : 0,239 s, sur la machine où tourne " +
          "la CI, dans l'étape « Ce que les deux bancs ont mesuré » qui republie " +
          "les deux relevés à la fin de chaque exécution de " +
          "`cargo run --release --bin wisq-bench-rs`.",
      ],
      ["0,24", "le même nombre dans l'autre langue."],
      [
        "0.33",
        "le plus lent : 0,326 s, sur cinq passages du même banc dans un " +
          "conteneur de développement modeste. C'est une durée d'hôte, pas une " +
          "propriété de wisq — le compte d'instructions au-dessus est le même " +
          "partout, le temps qu'il prend appartient à la machine.",
      ],
      ["0,33", "le même nombre dans l'autre langue."],
      [
        "137",
        "le débit du plus lent de ces passages, 136,9 MIPS. La page annonçait " +
          "« environ 160 » comme un point ; deux machines suffisent à montrer " +
          "pourquoi un point ne tient pas.",
      ],
      [
        "187",
        "le débit du plus rapide, 186,6 MIPS, relevé par la CI et republié en " +
          "fin de job. La borne haute vient donc d'un journal que n'importe qui " +
          "peut ouvrir, et non d'une mesure faite une fois.",
      ],
      [
        "32",
        "ce n'est pas une mesure : les 32 bits de rv32ima, l'architecture de la " +
          "machine locale.",
      ],
      [
        "64",
        "ce n'est pas une mesure : `LinuxMachine.defaultRAMSize`, ce qu'un noyau " +
          "reçoit quand personne n'a touché au curseur.",
      ],
      [
        "0.2",
        "ce n'est pas une mesure : le `2` de `omarchy-4.0.2.iso`, le nom de " +
          "fichier que la commande d'exemple montre.",
      ],
      [
        "2",
        "ce n'est pas une mesure : deux lectures du même nombre de gibioctets — `LinuxMachine.maximumRAMSize`, plafond d'adressage du rv32 (sa RAM commence à 0x80000000, son processeur adresse en 32 bits), et `KernelMemory.leftToTheDevice = 2 << 30` (`Sources/WisqVM/KernelMemory.swift`), ce que la machine laisse à l'appareil.",
      ],
      [
        "17",
        "ce n'est pas une mesure : la cible de déploiement de l'application — `project.yml`, `deploymentTarget: iOS: \"17.0\"` — et `platforms: [.iOS(.v17), .macOS(.v14)]` dans `Package.swift`.",
      ],
      [
        "4.7",
        "ce n'est pas une mesure : le numéro de la règle des directives de l'App Store dont dépend UTM SE, cité par le tableau de comparaison des deux READMEs (« grey area, rule 4.7 », « dépendante de la règle 4.7 »).",
      ],
      [
        "1998",
        "ce n'est pas une mesure : l'année où Microsoft a publié la clé qui signe les certificats de la sécurité historique de RDP — `Sources/WisqRemote/RDP/RDPSession.swift` et `RDPStandardSecurity.swift` le disent à côté du code, `docs/ROADMAP.md` (lot 3) aussi.",
      ],
      [
        "90",
        "ce n'est pas une mesure : la patience de l'arrêt poli, `patience: Duration = .seconds(90)` dans `VMPower.shutDown` (`Sources/WisqRemote/Agent/VMPower.swift`) ; `MachineListView` l'appelle sans la changer.",
      ],
      [
        "5",
        "ce n'est pas une mesure : `ReconnectPolicy.standard`, `maxAttempts: 5` (`Sources/WisqRemote/ReconnectingSession.swift`) — la politique par défaut de `ReconnectingSession`, que `SessionFactory` emploie pour les trois protocoles.",
      ],
      [
        "1",
        "ce n'est pas une mesure : `initialDelay: .seconds(1)` dans la même `ReconnectPolicy.standard`, doublé à chaque tentative (`multiplier: Double = 2`).",
      ],
      [
        "30",
        "ce n'est pas une mesure : `maxDelay: .seconds(30)`, le plafond du délai entre deux tentatives, même politique.",
      ],
      [
        "10",
        "ce n'est pas une mesure : `minimumUptimeToResetBudget: .seconds(10)`, ce qu'une connexion doit durer avant de remplir à nouveau le budget, même politique.",
      ],
      [
        "50",
        "deux lectures, aucune n'est une mesure : les « 50 ms » sont `InputTiming.pressReleaseGap = Duration.milliseconds(50)` (`Sources/WisqCore/Settings.swift`) ; les « 50 milliards » sont l'ordre de grandeur d'un bureau complet que donne `docs/ROADMAP.md` (lot 8, « de l'ordre de cinquante milliards d'instructions ») et que `wisq-bench` imprime en se qualifiant de « division, pas mesure » (`Sources/wisq-bench/main.swift`). La page le dit aussi.",
      ],
      [
        "16",
        "ce n'est pas une mesure : les deux bouts de `KernelMemory.choices`, `16 << 20` et `16 << 30` (`Sources/WisqVM/KernelMemory.swift`) ; le second est aussi le plafond de la machine PC, `case .x86_64: return 16 << 30` (`GuestArchitecture.swift`) — un choix, pas un fait d'adressage.",
      ],
      [
        "256",
        "ce n'est pas une mesure : `KernelMemory.roomForTheAppItself = 256 << 20`, ce que l'application garde pour elle à côté de la RAM invitée (`Sources/WisqVM/KernelMemory.swift`).",
      ],
      [
        "128",
        "ce n'est pas une mesure : `X86Machine.minimumRAMSize = 128 << 20` (`Sources/WisqVM/X86Machine.swift`), le plancher que `LocalVMModel` impose à une machine PC.",
      ],
      [
        "35",
        "ce n'est pas une mesure de wisq : la taille du noyau x86-64 décompressé que donne le refus de `LocalVMModel` (« son noyau décompressé en fait trente-cinq à lui seul », `Sources/WisqUI/ViewModels/LocalVMModel.swift`), reprise par `docs/ROADMAP.md` et `docs/DEMARRAGE.md`. L'image de référence relevée par `cargo run -p wisq-vm --release --example pointer-census -- <noyau>` fait 35 842 660 octets (DEMARRAGE.md, au 14 septembre 2026).",
      ],
      [
        "4",
        "relevé, et daté : le compte d'instructions jusqu'au shell de secours de l'initramfs d'Alpine, CHANGELOG 0.4.0 (« after 4 billion instructions »), le même que l'accueil porte (`content.rs`). La CI ne le refait pas : elle ne récupère aucun noyau Alpine.",
      ],
      [
        "6.1",
        "ce n'est pas une mesure : la version du noyau rv32 que la CI récupère et démarre, `linux-6.1.14-rv32nommu-cnl-1.zip` dans `.github/workflows/ci.yml`, publié par le projet mini-rv32ima.",
      ],
      [
        "58",
        "historique, et non relançable : le démon d'avant, lié statiquement au runtime Swift, pesait 58 Mo — CHANGELOG, README, CONTRIBUTING. Ce binaire n'existe plus ; la page le publie comme un avant et renvoie, pour le chiffre actuel, à la page du protocole, où `scripts/check-agent-size.sh` le tient.",
      ],
      [
        "1103",
        "daté : le débit d'un module WebAssembly engendré dans un `WKWebView` hébergé par l'application, sur le simulateur d'un coureur Apple — CHANGELOG 0.4.0. La sonde est `Tests/WisqHostedTests/WebKitJITProbeTests.swift`, que le job App iOS lance et dont il republie le relevé. C'est une mesure sur Mac, où macOS ne restreint pas le JIT, et la page le dit dans la même phrase. Écrit sans espace dans les deux langues, donc un seul jeton.",
      ],
      [
        "10.6",
        "daté : le terme de comparaison du CHANGELOG 0.4.0 (« contre 10,6 pour l'interpréteur x86 »), c'est-à-dire le débit du cœur x86-64 en Swift sur la boucle de `swift run -c release wisq-bench`, section « x86-64 », que la CI lance. Publié comme le terme de cette comparaison, pas comme un débit actuel.",
      ],
      [
        "10,6",
        "le même nombre dans l'autre langue.",
      ],
    ]),
  ],
  [
    "docs.rs",
    provenanceOf([
      [
        "3.8",
        "ce n'est pas une mesure : la version de RFB que le client parle — " +
          "`Sources/WisqRemote/VNC/VNCSession.swift` écrit « RFB 003.008 » sur " +
          "le fil, et RFB.swift porte les constantes de la RFC 6143.",
      ],
      [
        "5900",
        "ce n'est pas une mesure : la base des ports VNC, dont l'écran :1 fait " +
          "5901. C'est aussi `RemoteProtocol.defaultPort` pour VNC et pour " +
          "SPICE, et ce dernier a été mesuré plutôt que supposé — libvirt " +
          "alloue depuis 5900 vers le haut, pas depuis 5930.",
      ],
      [
        "5901",
        "ce n'est pas une mesure : 5900 plus l'écran :1, dans la commande " +
          "d'exemple comme dans la phrase qui l'explique.",
      ],
      [
        "7442",
        "ce n'est pas une mesure : le port par défaut du démon — " +
          "`crates/wisq-agent/src/main.rs`, `let mut port: u16 = 7442` — et la " +
          "ligne d'exemple reprend le format que le démon imprime vraiment " +
          "(« wisq-agent en écoute sur le port {bound} »).",
      ],
      [
        "8250",
        "ce n'est pas une mesure : le modèle d'UART de la machine rv32 — " +
          "`RV32DeviceTree.swift` le place à 0x1000_0000 et passe " +
          "`earlycon=uart8250,mmio` au noyau. Le 16550 que la page des versions " +
          "mentionne est l'autre machine, la x86-64.",
      ],
      [
        "512",
        "ce n'est pas une mesure : `DiskStore.sectorSize`, la taille d'un " +
          "secteur — la couche d'écriture tasse les secteurs touchés à " +
          "512 octets chacun.",
      ],
      [
        "1998",
        "ce n'est pas une mesure : l'année où Microsoft a publié la clé qui " +
          "signe les certificats de la sécurité historique de RDP. C'est la " +
          "raison pour laquelle cette sécurité n'authentifie pas le serveur, et " +
          "`RDPSession.swift` le dit au même endroit que le code qui la parle.",
      ],
      [
        "2048",
        "ce n'est pas une mesure : les mégaoctets d'un `qemu-system-x86_64 -m " +
          "2048` d'exemple. La commande est celle du lecteur sur sa machine, " +
          "pas une propriété de wisq.",
      ],
      [
        "0",
        "ce n'est pas une mesure, et trois lectures : l'écran `:0` que `x11vnc -display :0` expose dans la seconde ligne de l'exemple ; le bas de l'échelle de qualité JPEG de Tight, 0…9 (`DisplaySettings.jpegQuality`, `Sources/WisqCore/Settings.swift`) ; et le `0` du canal `com.redhat.spice.0`, celui que `crates/wisq-agent/src/domain.rs` écrit dans le domaine et par lequel spice-vdagent parle.",
      ],
      [
        "1",
        "ce n'est pas une mesure, et trois lectures : l'écran `:1` de la commande d'exemple ; le « 1:1 » de `DisplaySettings.Scaling.native`, dont c'est le `displayName` ; et la première attente de la reconnexion, `initialDelay: .seconds(1)` dans `ReconnectPolicy.standard` (`Sources/WisqRemote/ReconnectingSession.swift`).",
      ],
      [
        "2",
        "ce n'est pas une mesure, et trois lectures : les deux gibioctets de `LinuxMachine.maximumRAMSize`, plafond d'adressage du rv32 ; les deux gibioctets que `KernelMemory.leftToTheDevice` laisse au téléphone ; et l'intervalle de sondage de l'agent, `pollInterval: .seconds(2)` de `ConsoleResolver.resolve` et de `VMPower.shutDown`.",
      ],
      [
        "64",
        "ce n'est pas une mesure, et trois lectures : `LinuxMachine.defaultRAMSize`, ce qu'un noyau reçoit quand personne n'a touché au curseur ; le disque de `wisq-agent bureau`, `let mut disk_gib: u32 = 64` dans `crates/wisq-agent/src/main.rs` ; et la largeur du RISC-V 64 bits, que `GuestArchitecture.core` laisse sans cœur.",
      ],
      [
        "3389",
        "ce n'est pas une mesure : le port enregistré de RDP — `RemoteProtocol.defaultPort` pour `.rdp` (`Sources/WisqCore/RemoteProtocol.swift`), et `RemoteDesktopFile.defaultPort`, appliqué quand un fichier .rdp n'en nomme aucun.",
      ],
      [
        "8",
        "ce n'est pas une mesure : les huit premiers octets du mot de passe que l'authentification VNC historique lit — `VNCAuth.response`, `Array(raw.prefix(8))`, dans `Sources/WisqRemote/VNC/DES.swift`.",
      ],
      [
        "50",
        "ce n'est pas une mesure : `InputTiming.pressReleaseGap`, `Duration.milliseconds(50)` dans `Sources/WisqCore/Settings.swift`, avec la raison écrite à côté — un invité qui échantillonne les entrées sur un timer ne voit rien d'un clic plus court.",
      ],
      [
        "9",
        "ce n'est pas une mesure : le haut de l'échelle de qualité JPEG de Tight — `DisplaySettings.jpegQuality` borné par `min(max($0, 0), 9)` dans `Sources/WisqCore/Settings.swift`, et le curseur de l'éditeur `in: 0...9`.",
      ],
      [
        "5",
        "ce n'est pas une mesure : `ReconnectPolicy.standard`, `maxAttempts: 5`, dans `Sources/WisqRemote/ReconnectingSession.swift`.",
      ],
      [
        "10",
        "ce n'est pas une mesure : `minimumUptimeToResetBudget: .seconds(10)` de la même politique — ce qu'une connexion doit tenir pour regagner tout son crédit de tentatives.",
      ],
      [
        "90",
        "ce n'est pas une mesure : la patience de l'agent — `timeout: .seconds(90)` de `ConsoleResolver.resolve` et d'`AgentClient.waitUntilRunning` au démarrage, `patience: .seconds(90)` de `VMPower.shutDown` à l'arrêt.",
      ],
      [
        "4096",
        "ce n'est pas une mesure : la mémoire par défaut de `wisq-agent bureau`, `let mut memory_mib: u32 = 4096` dans `crates/wisq-agent/src/main.rs`.",
      ],
      [
        "4",
        "deux lectures. Ce n'est pas une mesure pour la première : les processeurs par défaut de `wisq-agent bureau`, `let mut cpus: u32 = 4`. La seconde est mesurée : les « 4 billion » / « 4 milliards » d'instructions au bout desquels l'init d'Alpine atteint son shell de secours, sous wisq comme sous QEMU — CHANGELOG 0.4.0, Fixed, entrée `XADD`/`POP`. Se refait par `WISQ_PC_KERNEL=<vmlinuz-lts> WISQ_PC_INITRD=<initramfs-lts> swift test --filter X86BootAttemptTests`, sauté sans ces variables, que ni la CI ni verify.sh ne fournissent.",
      ],
      [
        "16",
        "ce n'est pas une mesure : les deux bouts de `KernelMemory.choices`, de `16 << 20` à `16 << 30` — le plus petit palier du curseur, et le plafond que `GuestArchitecture.Core.maximumRAMSize` donne à la machine PC (ROADMAP #283).",
      ],
      [
        "128",
        "ce n'est pas une mesure : `X86Machine.minimumRAMSize`, `128 << 20`, que `LocalVMModel` impose en plancher à tout noyau de PC (`max(machineRAM, X86Machine.minimumRAMSize)`), avec la raison écrite à côté — en dessous, le noyau d'Alpine n'a plus la place de se décompresser.",
      ],
      [
        "256",
        "ce n'est pas une mesure : `KernelMemory.roomForTheAppItself`, `256 << 20`, ce que l'application garde pour elle à côté de la RAM de l'invité.",
      ],
      [
        "40",
        "ce n'est pas une mesure : `KernelImageKind.bytesNeeded`, `40 * 1024` — de quoi atteindre le descripteur de volume ISO 9660, au secteur seize.",
      ],
      [
        "17",
        "la place d'une machine RISC-V suspendue arrivée à l'invite de connexion — mesure consignée dans docs/ROADMAP.md, section « L'espace de stockage », sans date ni commande ; l'écran « Stockage » de l'application (`LocalStorage`) compte ce que pèse chaque machine sauvegardée, et c'est là qu'elle se refait. Le même chiffre est écrit dans `LocalVMView.swift`.",
      ],
      [
        "32",
        "ce n'est pas une mesure : les largeurs que nomme `GuestArchitecture` — le RISC-V 32 bits que wisq exécute, et le x86 32 bits qu'il reconnaît sans lui donner de cœur (`core` rend `nil` pour `bits == 32`).",
      ],
    ]),
  ],
  [
    "architecture.rs",
    provenanceOf([
      [
        "2.7",
        "mesuré au travail d'interpréteur de la 0.2.0 et consigné au CHANGELOG " +
          "avec son raisonnement : le fichier de registres sorti du tableau " +
          "Swift, parce que l'optimiseur rechargeait le tampon après chaque " +
          "appel opaque. Ne se refait pas sans défaire le changement ; le " +
          "banc, lui, existe toujours (`swift run -c release wisq-bench`).",
      ],
      ["2,7", "le même nombre dans l'autre langue."],
      [
        "47",
        "« loads et stores font 47 % d'un boot Linux », CHANGELOG 0.2.0, dans " +
          "la même entrée que le +8 % qu'elle justifie.",
      ],
      [
        "33",
        "la borne basse de « construction 33–194 ms », CHANGELOG 0.2.0 : le coût " +
          "d'obtenir la RAM invitée avant qu'elle ne soit mappée au lieu " +
          "d'effacée.",
      ],
      ["194", "la borne haute de la même mesure, même entrée."],
      [
        "0.1",
        "ce que la construction coûte depuis — « moins de 0,1 ms ». Les deux " +
          "bancs l'impriment encore à chaque exécution, ligne « construction », " +
          "et la CI les lance tous les deux.",
      ],
      ["0,1", "le même nombre dans l'autre langue."],
      [
        "9",
        "**mesure orpheline.** Les trois tentatives annulées — opcodes froids " +
          "sortis de la ligne à 9 %, réécriture inconditionnelle des registres " +
          "à 3 %, table de dispatch plus dense sans gain — ont été écrites " +
          "directement sur cette page en #232 et **nulle part ailleurs** : ni " +
          "CHANGELOG, ni journal, ni banc. Elles ne se refont pas sans refaire " +
          "les trois refactorisations. Publiées comme un rapport daté, et c'est " +
          "dit ici plutôt que laissé croire à une mesure relançable.",
      ],
      ["3", "la deuxième des trois tentatives annulées ci-dessus, même statut."],
      [
        "32",
        "ce n'est pas une mesure : les 32 bits par pixel que le client demande " +
          "au serveur RFB — `RFB.swift`, `bitsPerPixel: 32`.",
      ],
      [
        "16",
        "ce n'est pas une mesure : `redShift: 16` dans le même format de pixel.",
      ],
      [
        "0",
        "ce n'est pas une mesure : `blueShift: 0`, la troisième composante du " +
          "même format.",
      ],
      [
        "2 000",
        "les deux mille lignes de console de la mesure quadratique, " +
          "CHANGELOG 0.2.0 : re-dériver le texte visible à chaque arrivée est " +
          "un travail proportionnel à tout l'historique.",
      ],
      [
        "36.7",
        "ce que ces deux mille lignes coûtaient, même entrée. Le montage qui " +
          "l'a produit n'existe plus — c'est le comportement qui a été " +
          "supprimé —, donc le nombre est daté et non relançable.",
      ],
      ["36,7", "le même nombre dans l'autre langue."],
      [
        "0.22",
        "ce que les mêmes deux mille lignes coûtent depuis, même entrée.",
      ],
      ["0,22", "le même nombre dans l'autre langue."],
      [
        "50",
        "ce n'est pas une mesure : `InputTiming.pressReleaseGap`, " +
          "`Duration.milliseconds(50)` dans `Sources/WisqCore/Settings.swift`, " +
          "avec la raison écrite à côté — un invité qui échantillonne les " +
          "entrées sur un timer ne voit rien d'un clic plus court.",
      ],
      [
        "36",
        "compté, pas cité : les `pub extern \"C\" fn` de `crates/`, et le test " +
          "« la page d'architecture annonce le vrai nombre de fonctions du " +
          "C ABI » les recompte à chaque exécution. La page disait **sept**, " +
          "écrit en lettres — ce qui la faisait échapper au balayage des " +
          "chiffres pendant que la couture passait de sept à trente et une. " +
          "Trente et une à trente-trois en #310 : la page zéro du bureau et " +
          "son adresse, que le pilote met dans RSI. Trente-quatre en #312 : " +
          "`wisq_desktop_placement`, qui dit ce que l'application n'a pas le " +
          "droit d'écrire dans la RAM de l'invité. Trente-cinq en #313 : " +
          "`wisq_desktop_declare_initramfs`, sans quoi le noyau du bureau " +
          "meurt dans `prepare_namespace` avec sa racine à côté. Trente-six en " +
          "#314 : `wisq_kernel_loads`, le lecteur ELF que le montage de mesure " +
          "emploie depuis #304 et que rien n'exposait à l'application.",
      ],
      [
        "8",
        "trois lectures dans la même page, et les trois tiennent : le « +8 % » de l'extension de signe sans branchement (CHANGELOG 0.2.0) ; le vert à 8 du format de pixel — `RFB.swift`, `greenShift: 8` ; et « environ 8 % » d'avance du cœur Rust sur un démarrage complet, la raison écrite en tête de `Package.swift` et dans « Building » du README pour en faire le défaut. Les deux bancs que la CI lance — `swift run -c release wisq-bench` et `cargo run --release --bin wisq-bench-rs` — en impriment les deux termes à chaque exécution, et le rapport suit la machine et sa charge.",
      ],
      [
        "0.9",
        "ce n'est pas une mesure : la version de xrdp, le serveur contre lequel toute la pile RDP a été écrite — docs/ROADMAP.md, « Lot 3 — RDP » : « xrdp 0.9 (serveur) et FreeRDP 2.11 … s'installent tous les deux ici ».",
      ],
      [
        "2.11",
        "ce n'est pas une mesure : la version de FreeRDP, client et bibliothèque de référence, même passage de docs/ROADMAP.md ; c'est aussi le juge du codec entrelacé — `Tests/WisqRemoteTests/RDPBitmapTests.swift`, « Le codec entrelacé, jugé par FreeRDP 2.11 ».",
      ],
      [
        "1",
        "ce n'est pas une mesure, et deux lectures : la valeur de `WISQ_SWIFT_CORE=1`, l'échappatoire vers le cœur Swift que `Package.swift` et ci.yml nomment ; et le délai initial de reconnexion, `initialDelay: .seconds(1)` dans `ReconnectPolicy.standard` (`Sources/WisqRemote/ReconnectingSession.swift`).",
      ],
      [
        "5",
        "ce n'est pas une mesure : `maxAttempts: 5` dans `ReconnectPolicy.standard`, `Sources/WisqRemote/ReconnectingSession.swift`.",
      ],
      [
        "30",
        "ce n'est pas une mesure : `maxDelay: .seconds(30)`, le plafond des délais de la même politique, même fichier.",
      ],
      [
        "10",
        "ce n'est pas une mesure : `minimumUptimeToResetBudget: .seconds(10)`, même politique — ce qu'une connexion doit tenir pour recharger le budget, avec la raison écrite à côté.",
      ],
      [
        "15",
        "ce n'est pas une mesure, et deux lectures dans le même réglage : `connectionTimeout: Int = 15` et `keepaliveInterval: Int = 15`, valeurs par défaut de `TransportTuning` (`Sources/WisqNet/TransportTuning.swift`).",
      ],
      [
        "60",
        "ce n'est pas une mesure : `keepaliveIdle: Int = 60`, le silence avant la première sonde, même fichier.",
      ],
      [
        "4",
        "ce n'est pas une mesure : `keepaliveCount: Int = 4`, les sondes sans réponse avant que le lien soit déclaré mort, même fichier.",
      ],
      [
        "120",
        "pas une mesure de wisq : la cadence que docs/ARCHITECTURE.md, « Le modèle tactile », donne au curseur virtuel dessiné dans un `CAShapeLayer` séparé des pixels — « il peut bouger à 120 Hz sans re-rastériser le bureau ».",
      ],
      [
        "16550",
        "ce n'est pas une mesure : le port série de la machine PC — en-tête de `Sources/WisqVM/X86Machine.swift`, « un port série 16550, un couple de 8259 et un 8253 ».",
      ],
      [
        "8259",
        "ce n'est pas une mesure : le contrôleur d'interruptions de la même machine, même en-tête.",
      ],
      [
        "8250",
        "ce n'est pas une mesure : l'UART de la machine rv32 — `Sources/WisqVMRust/RustLinuxMachine.swift` (« an 8250 UART, a CLINT timer and a syscon ») et docs/ARCHITECTURE.md, « Le Linux local ».",
      ],
      [
        "64",
        "ce n'est pas une mesure, et deux lectures : `LinuxMachine.defaultRAMSize`, ce qu'un noyau rv32 reçoit quand personne n'a touché au curseur ; et la largeur en bits des paramètres `base` et `entry` du traducteur de région, que le commentaire de `wisq_x86_emit_region` (`crates/wisq-vm/src/ffi.rs`) désigne comme la seule erreur que la relecture doit attraper.",
      ],
      [
        "256",
        "ce n'est pas une mesure : `X86Machine.defaultRAMSize = 256 << 20`, la RAM par défaut d'une machine PC — `Sources/WisqVM/X86Machine.swift`.",
      ],
      [
        "22",
        "mesuré une fois et consigné dans l'en-tête de `Sources/WisqVM/X86Machine.swift` : après un démarrage complet d'Alpine — trois milliards et demi d'instructions, jusqu'à `kernel_init` —, 14 471 pages sur 65 536 ne sont pas entièrement nulles, soit 22 %. Publié comme un relevé daté : la CI ne fournit aucun noyau PC (`WISQ_PC_KERNEL` n'est posé nulle part dans .github/).",
      ],
      [
        "1998",
        "ce n'est pas une mesure : l'année où Microsoft a publié la clé qui signe les certificats de la sécurité d'origine de RDP — `Sources/WisqRemote/RDP/RDPSession.swift` et `RDPStandardSecurity.swift` le disent au-dessus du code qui la parle, et c'est pourquoi cette sécurité n'authentifie pas le serveur.",
      ],
      [
        "224",
        "ce n'est pas une mesure : le numéro de la recommandation X.224 (classe 0 de l'ISO 8073), l'une des deux enveloppes de toute session RDP — `Sources/WisqRemote/RDP/RDPWire.swift`.",
      ],
      [
        "264",
        "ce n'est pas une mesure : le codec vidéo H.264, que wisq ne décode ni dans les flux SPICE (`SpiceDisplayDecoder.swift`, « Only MJPEG. VP8, VP9, H.264 and H.265 would each need a real video decoder ») ni en RDP (docs/ROADMAP.md, Lot 3, « RemoteFX et H.264 »).",
      ],
      [
        "265",
        "ce n'est pas une mesure : H.265, même phrase de `SpiceDisplayDecoder.swift`, et `case h265 = 5` dans `SpiceDisplayWire.swift`.",
      ],
      [
        "40",
        "ce n'est pas une mesure : `KernelImageKind.bytesNeeded = 40 * 1024`, ce que wisq lit d'un fichier pour en reconnaître la nature — `Sources/WisqVM/KernelImageKind.swift`.",
      ],
      [
        "647 965",
        "mesuré et daté : le différentiel du décodeur x86 contre `objdump` 2.42, « 647 965 accords, zéro désaccord », consigné dans docs/ROADMAP.md, Lot 7, tranche 2. Le dépôt n'en garde que l'extrait distillé (`Tests/Fixtures/x86-corpus.tsv`, refabriqué par `scripts/build-x86-corpus.py`, rejoué par `X86CorpusTests`) : le compte complet dépend des binaires de la machine où on le relance, et la CI ne le refait pas.",
      ],
      [
        "351 822",
        "mesuré avant d'être refusé, et consigné deux fois : CHANGELOG [Unreleased], « Le site est en Yew… », et docs/JOURNAL.md #335 — le module wasm brut quand les pages étaient hydratées entières. Cette forme n'existe plus : nombre daté, non relançable.",
      ],
      [
        "261 252",
        "même relevé, même tableau : le module brut avec deux îlots et tout le mouvement, au moment de la décision. Le module a bougé depuis ; ce qui tient, c'est l'invariant qui en est sorti — `site/tests/build.test.ts`, « le module ne porte la prose d'aucune page ».",
      ],
    ]),
  ],
  // La réserve sur le transport ne porte plus « version 1 » : elle disait le
  // clair comme une fatalité alors que c'est un défaut, et le numéro de
  // version n'ajoutait rien qu'un chiffre à tenir.
  [
    "privacy.rs",
    provenanceOf([
      [
        "32",
        "ce n'est pas une mesure : la longueur du jeton porteur que le démon génère au premier lancement — `crates/wisq-agent/src/main.rs`, « 32 characters from the OS random source », lus dans /dev/urandom par `let mut buffer = [0u8; 32];`.",
      ],
      [
        "7442",
        "ce n'est pas une mesure : le port par défaut du démon — `crates/wisq-agent/src/main.rs`, `let mut port: u16 = 7442` ; `docs/AGENT-PROTOCOL.md`, « port 7442 par défaut » ; et `AgentPairing.Payload`, `port: Int = 7442`, côté application.",
      ],
    ]),
  ],
  ["mod.rs", new Map()],
  ["offline.rs", new Map()],
]);

/// Les pages que rien ne relit. L'entrée porte **la liste exacte** des chiffres
/// qu'elles publient : ça n'affirme rien sur leur vérité, ça interdit seulement
/// qu'un chiffre y bouge sans que quelqu'un le voie.
///
/// **Elle est vide, et c'est une fin plutôt qu'un oubli.** Les quatre pages qui
/// y figuraient — `architecture.ts`, `docs.ts`, `faq.ts`, `privacy.ts` — ont eu
/// chacune sa tranche, et chacune a rendu quelque chose : un démon trois fois
/// plus lourd qu'annoncé, un débit dont l'instrument dormait dans le dépôt, un
/// guide qui comptait deux protocoles sur trois, une couture de sept fonctions
/// devenue trente et une, une réserve de confidentialité qui donnait le clair
/// pour une fatalité. Le mécanisme reste : une page ajoutée entre ici, ou elle
/// est tenue.
const notLookedAt = new Map<string, string[]>([]);

/// Les pages dont les chiffres relèvent d'une autre garde, nommée. Le récit des
/// versions est le seul cas : ce qu'il publie est ce qu'une version **a
/// annoncé**, et rafraîchir ces nombres réécrirait le registre au lieu de le
/// corriger. Ses numéros de version, eux, sont tenus ailleurs — et le test
/// ci-dessous vérifie que l'ailleurs en question lit vraiment ce fichier.
const heldElsewhere = new Map([
  [
    "releases.rs",
    {
      guard: "version-agreement.test.ts",
      why:
        "le registre des versions publiées : ses mesures sont datées par la " +
        "version qui les a annoncées et ne se rafraîchissent pas, ses numéros " +
        "de version sont comparés aux sept fichiers qui les portent.",
    },
  ],
]);

describe("les pages du site publient des nombres, et le périmètre de ce qui les relit est écrit", () => {
  test("toute page de crates/wisq-site/src/pages est tenue, avouée non tenue, ou nommée hors sujet", () => {
    for (const page of pageFiles()) {
      const listed =
        Number(accounted.has(page)) +
        Number(notLookedAt.has(page)) +
        Number(heldElsewhere.has(page));
      expect(
        listed,
        `« ${page} » n'est dans aucune des trois listes — ou dans plusieurs. ` +
          `Une page publiée se tient, s'avoue, ou se délègue à une garde ` +
          `nommée : elle ne passe pas en silence.`,
      ).toBe(1);
    }
  });

  test("rien ne subsiste dans les trois listes pour une page que le site n'a plus", () => {
    const present = new Set(pageFiles());
    for (const page of [
      ...accounted.keys(),
      ...notLookedAt.keys(),
      ...heldElsewhere.keys(),
    ]) {
      expect(present.has(page), `« ${page} » n'existe plus`).toBe(true);
    }
  });

  test("aucun nombre n'apparaît sur une page tenue sans une ligne disant d'où il vient", () => {
    for (const [page, provenance] of accounted) {
      for (const number of figuresOn(page)) {
        expect(
          provenance.has(number),
          `« ${page} » publie « ${number} » et rien ne dit d'où il vient. ` +
            `Ajoute-le avec la commande qui le refait, ou avec la raison pour ` +
            `laquelle ce n'est pas une mesure.`,
        ).toBe(true);
      }
    }
  });

  test("aucun nombre n'a deux provenances dont une serait effacée", () => {
    expect(
      duplicated,
      `ces nombres ont deux justifications dans la même liste, et la seconde ` +
        `efface la première : ${duplicated.join(", ")}. Donne-leur deux clés, ` +
        `ou fusionne les deux raisons dans une seule entrée.`,
    ).toEqual([]);
  });

  test("rien ne subsiste dans une liste de provenance pour un nombre que la page ne porte plus", () => {
    for (const [page, provenance] of accounted) {
      const published = new Set(figuresOn(page));
      for (const number of provenance.keys()) {
        expect(
          published.has(number),
          `« ${number} » n'est plus sur ${page} ; sa justification ne couvre rien.`,
        ).toBe(true);
      }
    }
  });

  test("l'aveu d'une page non tenue est à jour, chiffre par chiffre", () => {
    for (const [page, confessed] of notLookedAt) {
      expect(
        figuresOn(page),
        `les chiffres de « ${page} » ont bougé depuis l'aveu. Mets la liste à ` +
          `jour — ou, mieux, tiens la page et sors-la de cette liste.`,
      ).toEqual(confessed);
    }
  });

  /// **Une provenance qui cite une commande promet qu'elle se relance.** C'est
  /// la moitié la plus fragile d'un chiffre publié : `faq.ts` annonçait un débit
  /// dont l'instrument existait — `wisq-bench-rs`, qui double le banc Swift
  /// « down to the wording » selon son propre en-tête — et que **rien ne
  /// lançait**, ni la CI, ni `verify.sh`, ni un document. Le chiffre était donc
  /// cité de mémoire pendant que sa commande dormait dans le dépôt.
  ///
  /// La commande ne va pas sur la page : `render.test.tsx` interdit `cargo run`
  /// et `cargo build` sur le site, et c'est une décision — le site décrit wisq,
  /// il ne le distribue pas. Elle vit donc ici, dans la provenance, et ce test
  /// dit les deux sens : la provenance la cite, et la CI la lance.
  const citedInstruments = new Map([
    ["swift run -c release wisq-bench", "swift run -c release wisq-bench"],
    ["cargo run --release --bin wisq-bench-rs", "wisq-bench-rs"],
  ]);

  test("un instrument cité par une provenance est lancé par la CI", () => {
    const workflow = readFileSync(
      join(repoRoot, ".github", "workflows", "ci.yml"),
      "utf8",
    );
    const provenance = [...accounted.values()]
      .flatMap((page) => [...page.values()])
      .join("\n");
    for (const [command, needle] of citedInstruments) {
      expect(
        provenance.includes(command),
        `aucune provenance ne cite « ${command} » ; l'entrée ne couvre rien.`,
      ).toBe(true);
      expect(
        workflow.includes(needle),
        `une provenance cite « ${command} » et ci.yml ne nomme pas « ${needle} » : ` +
          `le chiffre serait cité sans que rien ne le refasse.`,
      ).toBe(true);
    }
  });

  test("la garde nommée pour une page hors sujet lit vraiment cette page", () => {
    for (const [page, { guard }] of heldElsewhere) {
      const source = readFileSync(join(import.meta.dir, guard), "utf8");
      expect(
        source.includes(`src/pages/${page}`),
        `« ${page} » est délégué à ${guard}, qui ne nomme pas ce fichier : ` +
          `la délégation ne couvre rien.`,
      ).toBe(true);
    }
  });
});

/// **Le guide dit combien de secrets préparer, et le workflow dit lesquels.**
///
/// `docs/TESTER-UBUNTU.md` annonçait « quatre secrets de dépôt, décrits dans
/// l'en-tête de `.github/workflows/testflight.yml` ». Le workflow en exigeait
/// trois et en connaissait six. Le compte était juste le jour où il a été
/// écrit — quatre secrets nommés, dont trois exigés — et il n'a bougé ni
/// quand le certificat est arrivé (#311), ni quand il est redevenu facultatif
/// (#313), parce qu'un chiffre dans une phrase n'a pas de compilateur.
///
/// Ce qui compte pour quelqu'un qui prépare son compte, c'est **ce sans quoi
/// l'envoi refuse** : les secrets que l'étape « Refuser tôt » déclare
/// manquants. Le reste est facultatif et le workflow le dit lui-même, dans le
/// résumé d'exécution. Le nombre est donc lu là, chez celui qui refuse.
/// **« Vingt et une familles », et l'énumération en déclare vingt.**
///
/// Les deux READMEs, l'accueil, la feuille de route et deux commentaires
/// annonçaient que wisq reconnaît « vingt et une » familles d'architectures.
/// `GuestArchitecture.Family` en déclare vingt — et `docs/ROADMAP.md` les
/// **nomme**, vingt, dans la phrase même qui en annonçait vingt et une. Le
/// compte avait été écrit à la main et recopié, et rien ne le relisait. Trouvé
/// en enrichissant le guide, qui a refusé de recopier un nombre qu'il ne
/// pouvait pas recompter.
///
/// La garde compte les `case` de l'énumération et lit chaque phrase qui
/// publie le compte. Les mots sont ceux du domaine — de dix-neuf à vingt-deux
/// —, pas une table générale : une famille de plus ou de moins doit la faire
/// tomber, et c'est tout ce qu'elle a à savoir.
describe("le nombre de familles d'architectures reconnues est celui de l'énumération", () => {
  const MOTS: Record<number, { en: string; fr: string }> = {
    19: { en: "nineteen", fr: "dix-neuf" },
    20: { en: "twenty", fr: "vingt" },
    21: { en: "twenty-one", fr: "vingt et une" },
    22: { en: "twenty-two", fr: "vingt-deux" },
  };

  function familles(): number {
    const source = readFileSync(join(repoRoot, "Sources/WisqVM/GuestArchitecture.swift"), "utf8");
    const corps = source.slice(source.indexOf("enum Family"));
    const declarations = corps.slice(0, corps.indexOf("public var") > 0 ? corps.indexOf("public var") : undefined);
    const cas = [...declarations.matchAll(/^\s*case ([a-z0-9, ]+)$/gm)].flatMap((m) =>
      m[1]!.split(",").map((nom) => nom.trim()).filter(Boolean),
    );
    return cas.length;
  }

  test("l'énumération se compte", () => {
    // Une lecture qui ne trouverait rien rendrait toutes les phrases fausses
    // pour une raison qui n'est pas la leur.
    expect(familles()).toBeGreaterThan(10);
  });

  test.each([
    ["README.md", /—\s+(\S+(?: et une)?)\s+architecture\s+families\s+recognised/, "en"],
    ["README.fr.md", /:\s+(\S+(?: et une)?)\s+familles\s+d'architectures/, "fr"],
    ["crates/wisq-site/src/content.rs", /core itself: (\S+) architecture families recognised/, "en"],
    ["crates/wisq-site/src/content.rs", /cœur tout seul : (\S+(?: et une)?) familles d'architectures/, "fr"],
    ["docs/ROADMAP.md", /nomme les \*\*(\S+(?: et une)?) familles\*\*/, "fr"],
  ] as const)("%s annonce le vrai compte (%#)", (fichier, motif, langue) => {
    const texte = readFileSync(join(repoRoot, fichier), "utf8").replace(/\s*\n\s*/g, " ");
    const trouve = texte.match(motif);
    expect(trouve, `${fichier} n'annonce plus le nombre de familles`).not.toBeNull();
    const attendu = MOTS[familles()];
    expect(attendu, `aucun mot pour ${familles()} familles`).toBeDefined();
    expect(trouve![1], `${fichier} : l'énumération déclare ${familles()} familles`).toBe(
      attendu![langue],
    );
  });
});

describe("le guide annonce le nombre de secrets que le workflow exige", () => {
  const NUMBERS = [
    "zéro", "un", "deux", "trois", "quatre", "cinq",
    "six", "sept", "huit", "neuf", "dix",
  ];

  /// Les secrets sans lesquels « Refuser tôt » sort en 1, lus chez lui. Un
  /// lecteur qui ne trouve rien renverrait zéro, et zéro se compare très bien
  /// à zéro : il refuse plutôt.
  function required(): string[] {
    const flow = readFileSync(
      join(repoRoot, ".github", "workflows", "testflight.yml"),
      "utf8",
    );
    const found = [...flow.matchAll(/missing="\$missing ([A-Z0-9_]+)"/g)].map(
      (match) => match[1]!,
    );
    if (found.length === 0) {
      throw new Error(
        "testflight.yml ne déclare plus aucun secret manquant dans « Refuser " +
          "tôt » : c'est le motif qui a cessé de correspondre, ou l'étape qui " +
          "a cessé d'exiger quoi que ce soit.",
      );
    }
    return found;
  }

  /// Le nombre que le guide annonce, en toutes lettres, et un refus s'il n'y
  /// en a plus : la phrase peut disparaître d'une réécriture, et une garde qui
  /// ne trouve plus sa phrase ne garde rien.
  function announced(): string {
    const guide = readFileSync(join(repoRoot, "docs", "TESTER-UBUNTU.md"), "utf8");
    const found = guide.replace(/\s+/g, " ").match(/(\p{L}+) secrets de dépôt/u);
    if (!found) {
      throw new Error(
        "docs/TESTER-UBUNTU.md ne dit plus combien de secrets de dépôt " +
          "préparer. Si la phrase a changé de forme, corrigez ce lecteur ; si " +
          "elle a disparu, retirez ce test plutôt que de le laisser vide.",
      );
    }
    return found[1]!;
  }

  test("le compte annoncé est celui que « Refuser tôt » exige", () => {
    const needed = required();
    expect(
      announced(),
      `le guide annonce « ${announced()} secrets de dépôt » alors que ` +
        `« Refuser tôt » en exige ${needed.length} : ${needed.join(", ")}. ` +
        `C'est la liste qu'on prépare avant de lancer un envoi.`,
    ).toBe(NUMBERS[needed.length]);
  });

  /// Les deux lecteurs peuvent tomber, et on le montre.
  test("le lecteur du guide refuse un texte qui n'annonce aucun compte", () => {
    const guide = readFileSync(join(repoRoot, "docs", "TESTER-UBUNTU.md"), "utf8");
    expect(guide).toMatch(/secrets de dépôt/);
    expect(() => {
      const found = "rien de tel ici".match(/(\p{L}+) secrets de dépôt/u);
      if (!found) throw new Error("ne dit plus combien de secrets");
      return found[1];
    }).toThrow(/ne dit plus combien de secrets/);
  });

  test("le lecteur du workflow trouve bien les secrets exigés", () => {
    expect(required().length).toBeGreaterThan(0);
    for (const secret of required()) expect(secret).toMatch(/^[A-Z0-9_]+$/);
  });
});

/// **La feuille de route chiffre une décision, et ses chiffres se rouillent.**
///
/// « Brancher le bureau dans l'application : les trois formes, et leur coût »
/// avance deux nombres sur la suite hébergée — combien de tests elle porte, et
/// combien démarrent un noyau. Ce sont les deux qui décident si le bureau est
/// jugé sous un vrai WebKit, donc les deux sur lesquels la décision s'appuie.
///
/// Ils sont tenus ici pour une raison qui a coûté deux tranches : #322 a écrit
/// « the third and last of this repository's guard scripts » quand c'était
/// vrai, et quatre scripts arrivés ailleurs l'ont rendu faux sans que personne
/// n'y touche ; #323 a trouvé que la phrase d'à côté affirmait plus que sa
/// garde ne vérifiait. **Un relevé qu'aucune garde ne lit dérive**, et un
/// chiffrage qui dérive fait trancher une décision sur un chiffre périmé.
describe("le chiffrage du bureau annonce la vraie suite hébergée", () => {
  const hosted = readFileSync(
    join(repoRoot, "Tests/WisqHostedTests/LocalDesktopTests.swift"),
    "utf8",
  );
  const roadmap = readFileSync(join(repoRoot, "docs/ROADMAP.md"), "utf8");

  /// Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
  const cases = hosted.match(/\bfunc test\w+/g) ?? [];
  const booting = hosted.match(/bootsAKernel: true/g) ?? [];

  test("le nombre de tests hébergés est celui que la feuille de route écrit", () => {
    expect(cases.length, "aucun test hébergé trouvé").toBeGreaterThan(5);
    const said = roadmap.match(/\*\*(\d+)\*\* tests hébergés, dont \*\*(\d+)\*\*/);
    expect(said, "la ligne qui chiffre la suite hébergée a changé de forme").not.toBeNull();
    expect(
      Number(said![1]),
      `la feuille de route dit ${said![1]} tests hébergés, il y en a ${cases.length}`,
    ).toBe(cases.length);
  });

  test("le nombre de ceux qui démarrent un noyau l'est aussi", () => {
    /// Le témoin : si le motif ne trouvait rien, « zéro contre zéro »
    /// satisferait l'égalité sans avoir rien lu.
    expect(booting.length, "aucun test hébergé ne démarre un noyau").toBeGreaterThan(0);
    const said = roadmap.match(/\*\*(\d+)\*\* tests hébergés, dont \*\*(\d+)\*\*/);
    expect(said).not.toBeNull();
    expect(
      Number(said![2]),
      `la feuille de route dit ${said![2]} démarrages, il y en a ${booting.length}`,
    ).toBe(booting.length);
  });
});

describe("le relevé LZ4 : trois phrases et une table pour une seule mesure", () => {
  const fixtures = readFileSync(
    join(repoRoot, "Tests/WisqRemoteTests/SpiceLZ4Fixtures.swift"),
    "utf8",
  );
  const suite = readFileSync(
    join(repoRoot, "Tests/WisqRemoteTests/SpiceLZ4Tests.swift"),
    "utf8",
  );
  const readme = readFileSync(
    join(repoRoot, "scripts/spice-lz4-fixtures/README.md"),
    "utf8",
  );
  const roadmap = readFileSync(join(repoRoot, "docs/ROADMAP.md"), "utf8");

  /// Une seule de ces lectures est exécutée : `sharing`, que
  /// `testDecodingEachBlockOnItsOwnGetsItWrong` confronte au décodage réel en
  /// exigeant, pour chaque gabarit, que se tromper soit exactement
  /// l'appartenance à l'ensemble. Tout le reste est du texte — des
  /// commentaires, une phrase de README, une ligne de feuille de route — et
  /// du texte ne se trompe jamais tout seul. C'est pour ça qu'il dérive.
  const declared = [...fixtures.matchAll(/static let (\w+) = Case\(/g)].map((m) => m[1]);
  const sharing = (
    suite.match(/let sharing = Set\(\[([\s\S]*?)\]\)/)?.[1].match(/"(\w+)"/g) ?? []
  ).map((quoted) => quoted.slice(1, -1));
  /// Le README porte **trois** tables, et deux d'entre elles nomment des
  /// fixtures. Lire « toute ligne qui commence par un nom entre accents
  /// graves » en ramasse seize pour onze — c'est ce que ce test a fait
  /// d'abord. Chaque table est donc prise par son en-tête.
  const tableUnder = (header: RegExp) =>
    readme.match(new RegExp(`^\\|${header.source}$([\\s\\S]*?)\\n\\n`, "m"))?.[1] ?? "";
  const rows = [...tableUnder(/ fixture \|.*shared dictionary.*\|/).matchAll(/^\| `(\w+)` \|(.*)$/gm)];
  const tabled = rows.map((row) => row[1]);
  const required = rows.filter((row) => row[2].includes("**required**")).map((row) => row[1]);
  const reached = [
    ...tableUnder(/ \| blocks \|.*match into an earlier block \|/).matchAll(/^\| `(\w+)` \|/gm),
  ].map((row) => row[1]);

  /// Le relevé est écrit dans les deux langues : les commentaires de la suite
  /// et le README du générateur sont en anglais, la feuille de route est en
  /// français. Ne chercher que l'anglais laisse la cinquième copie dehors —
  /// c'est ce que le premier relevé de cette tranche a fait.
  const words = [
    ["zero", "zéro"], ["one", "un"], ["two", "deux"], ["three", "trois"],
    ["four", "quatre"], ["five", "cinq"], ["six", "six"], ["seven", "sept"],
    ["eight", "huit"], ["nine", "neuf"], ["ten", "dix"], ["eleven", "onze"],
    ["twelve", "douze"],
  ];
  const counted = (word: string) =>
    words.findIndex((pair) => pair.includes(word.toLowerCase()));

  test("la table du générateur nomme les mêmes fixtures que le fichier qui les porte", () => {
    expect(declared.length, "aucune fixture déclarée").toBeGreaterThan(5);
    expect(tabled.length, "aucune ligne de table lue").toBeGreaterThan(5);
    expect([...tabled].sort()).toEqual([...declared].sort());
  });

  test("la colonne « shared dictionary » de la table est l'ensemble que le test mesure", () => {
    expect(sharing.length, "l'ensemble `sharing` n'a pas été lu").toBeGreaterThan(0);
    expect(required.length, "aucune ligne marquée **required**").toBeGreaterThan(0);
    expect([...required].sort()).toEqual([...sharing].sort());
  });

  /// Le relevé est aussi écrit en toutes lettres, et aucune de ces phrases
  /// n'est lue par quoi que ce soit. Elles disaient « sept », et la phrase du
  /// commentaire allait plus loin : elle annonçait « quatre » exceptions puis
  /// en nommait trois. La mesure, elle, en comptait huit et trois.
  test("les trois phrases annoncent le nombre que le test mesure", () => {
    const sentences: Array<[string, RegExpMatchArray | null]> = [
      [
        "SpiceLZ4Fixtures.swift, l'en-tête",
        fixtures.match(/\*\*(\w+) of the (\w+) do not decode correctly/),
      ],
      [
        "SpiceLZ4Fixtures.swift, « those … came out wrong »",
        fixtures.match(/those (\w+) came out wrong/),
      ],
      [
        "SpiceLZ4Tests.swift, le commentaire du test",
        suite.match(/(\w+) of the (\w+) fixtures are wrong that way/),
      ],
      [
        "SpiceLZ4Tests.swift, « testing only against the … »",
        suite.match(/Testing only against the (\w+) would/),
      ],
      ["README du générateur", readme.match(/(\w+) of (\w+) did\./)],
      [
        "docs/ROADMAP.md, la liste des pièges LZ4",
        roadmap.match(/(\w+) des (\w+) gabarits le prouvent/),
      ],
    ];
    for (const [where, said] of sentences) {
      expect(said, `${where} : la phrase a changé de forme`).not.toBeNull();
      expect(
        counted(said![1]),
        `${where} annonce « ${said![1]} », la mesure en compte ${sharing.length}`,
      ).toBe(sharing.length);
    }
  });

  test("là où le total est écrit à côté, c'est le nombre de fixtures", () => {
    const totals: Array<[string, RegExpMatchArray | null]> = [
      [
        "SpiceLZ4Fixtures.swift, l'en-tête",
        fixtures.match(/\*\*\w+ of the (\w+) do not decode correctly/),
      ],
      [
        "SpiceLZ4Tests.swift, le commentaire du test",
        suite.match(/\w+ of the (\w+) fixtures are wrong that way/),
      ],
      ["README du générateur", readme.match(/\w+ of (\w+) did\./)],
      [
        "docs/ROADMAP.md, la liste des pièges LZ4",
        roadmap.match(/\w+ des (\w+) gabarits le prouvent/),
      ],
      [
        "SpiceLZ4Tests.swift, l'en-tête du fichier",
        suite.match(/the whole argument here: (\w+) payloads/),
      ],
    ];
    for (const [where, said] of totals) {
      expect(said, `${where} : la phrase a changé de forme`).not.toBeNull();
      expect(
        counted(said![1]),
        `${where} annonce « ${said![1]} » fixtures, il y en a ${declared.length}`,
      ).toBe(declared.length);
    }
  });

  /// La troisième table du README — ce que la relecture Python compte pour
  /// chaque fixture — n'en relève que six sur onze. La phrase qui l'introduit
  /// disait « what each one reaches », ce que la table en dessous ne fait pas.
  test("la table des chemins atteints dit combien de fixtures elle relève", () => {
    expect(reached.length, "aucune ligne de la table des chemins atteints").toBeGreaterThan(0);
    expect(reached.length, "elle les relèverait toutes").toBeLessThan(declared.length);
    const said = readme.match(/It also counts, for (\w+) of them/);
    expect(said, "la phrase qui introduit la table a changé de forme").not.toBeNull();
    expect(
      counted(said![1]),
      `le README annonce « ${said![1]} » relevés, la table en porte ${reached.length}`,
    ).toBe(reached.length);
  });

  /// Celles qui n'ont pas besoin du dictionnaire partagé sont **nommées** dans
  /// le commentaire plutôt que filtrées par un prédicat, et c'est délibéré :
  /// c'est ce qui empêche de ne tester que celles qui partagent. Une liste
  /// nommée à la main est précisément ce qui se désaccorde en silence.
  test("les exceptions nommées sont exactement celles que la mesure laisse de côté", () => {
    const paragraph = suite.match(
      /are named rather than filtered out by a predicate:([\s\S]*?)Testing only against/,
    )?.[1];
    expect(paragraph, "le commentaire qui nomme les exceptions a changé de forme").toBeDefined();
    const named = [...(paragraph ?? "").matchAll(/`(\w+)`/g)].map((m) => m[1]);
    expect(named.length, "aucune exception nommée").toBeGreaterThan(0);
    const left = declared.filter((name) => !sharing.includes(name));
    expect([...named].sort()).toEqual([...left].sort());

    const said = suite.match(/fixtures are wrong that way\. (\w+) are not/);
    expect(said, "la phrase qui compte les exceptions a changé de forme").not.toBeNull();
    expect(
      counted(said![1]),
      `le commentaire annonce « ${said![1]} » exceptions, il y en a ${left.length}`,
    ).toBe(left.length);
  });
});

describe("la phrase des corpus matériels ne dérive pas là où la garde ne regardait pas", () => {
  /// Le compteur d'inventaire plus haut ne lit que le front — `site/src` à
  /// l'époque, `crates/wisq-site/src` depuis qu'il est en Rust —, `docs` hors
  /// journal, `CHANGELOG.md` et les deux READMEs, et son en-tête affirmait que
  /// les phrases laissées dehors le sont **par leur forme** — qu'elles ne
  /// disent pas « corpus matériels ». **Six le disent** : trois témoins de
  /// `Sources/WisqVM` et leurs trois suites, chacun ouvrant par « Cinq corpus
  /// matériels ont épuisé le jeu d'instructions ». Elles étaient dehors par
  /// leur **place**, pas par leur forme, et un inventaire qui dériverait là y
  /// serait resté invisible — alors que l'en-tête disait le contraire.
  ///
  /// Ce test balaie l'arbre et exige de chaque copie qu'elle soit l'une des
  /// trois : dans le périmètre d'inventaire, un **constat daté**, ou une
  /// mention sans nombre devant. Rien d'autre ne passe.
  ///
  /// **La normalisation n'est pas un détail.** Une des six écrit « Cinq » en
  /// fin de ligne et « corpus matériels » au début de la suivante : un balayage
  /// qui lit ligne par ligne en voit cinq et croit avoir tout vu. C'est ce que
  /// le premier relevé de cette tranche a fait. Les marqueurs de commentaire
  /// sont retirés et les blancs écrasés **avant** de chercher.
  const INVENTORY = [
    "crates/wisq-site/src/",
    "docs/",
    "CHANGELOG.md",
    "README.md",
    "README.fr.md",
  ];
  /// **Une seule exclusion, et elle porte.** `docs/JOURNAL.md` **cite** les
  /// phrases fausses dans le tableau de la tranche qui les a corrigées : une
  /// garde qui le lui refuserait lui interdirait de tenir le registre. Levée,
  /// le balayage voit dix-neuf copies au lieu de sept.
  ///
  /// Ce fichier-ci en avait une deuxième — lui-même, « parce qu'il porte ses
  /// propres motifs ». Levée, **rien ne tombait** : ses occurrences n'annoncent
  /// aucun nombre, donc la branche des mentions les accepte déjà. Une exclusion
  /// qui ne porte rien, avec une raison écrite à côté, est une affirmation
  /// fausse de plus. Elle est retirée, et cette garde se lit elle-même.
  const EXCLUDED = ["docs/JOURNAL.md"];
  const SKIP = new Set([
    ".git", "node_modules", "dist", "target", ".build", ".heroku-bun", "Fixtures",
  ]);
  const DATED = "ont épuisé le jeu d'instructions";

  const NUMBERS = new Set([...FRENCH_NUMBERS, ...ENGLISH_NUMBERS]);

  function sweep(): Array<{ path: string; word: string; tail: string }> {
    const hits: Array<{ path: string; word: string; tail: string }> = [];
    const walk = (dir: string, prefix: string) => {
      for (const entry of readdirSync(dir)) {
        if (SKIP.has(entry)) continue;
        const path = join(dir, entry);
        const shown = prefix ? `${prefix}/${entry}` : entry;
        if (statSync(path).isDirectory()) {
          walk(path, shown);
          continue;
        }
        if (EXCLUDED.includes(shown)) continue;
        let text: string;
        try {
          text = readFileSync(path, "utf8");
        } catch {
          continue;
        }
        if (!/corpus matériels|hardware corpora/i.test(text)) continue;
        const flat = text.replace(/^[ \t]*(\/\/\/?|\*|#)[ \t]?/gm, "").replace(/\s+/g, " ");
        for (const found of flat.matchAll(/(\S+)\s+(corpus matériels|hardware corpora)/giu)) {
          hits.push({
            path: shown,
            word: found[1].replace(/[^\p{L}]/gu, "").toLowerCase(),
            tail: flat.slice(found.index! + found[0].length).trimStart().slice(0, 60),
          });
        }
      }
    };
    walk(repoRoot, "");
    return hits;
  }

  const hits = sweep();
  const inside = hits.filter((hit) => INVENTORY.some((scope) => hit.path.startsWith(scope)));
  const outside = hits.filter((hit) => !INVENTORY.some((scope) => hit.path.startsWith(scope)));

  test("le balayage de l'arbre trouve le même inventaire que le compteur", () => {
    expect(hits.length, "la phrase a disparu de l'arbre").toBeGreaterThan(5);
    /// Deux lecteurs du même fait, et c'est tout l'intérêt : celui-ci part de
    /// la racine, l'autre d'une liste de dossiers. Ils doivent tomber sur le
    /// même compte.
    const counted = inside.filter((hit) => NUMBERS.has(hit.word));
    expect(
      counted.length,
      `le balayage voit ${counted.length} copie(s) chiffrée(s) dans le périmètre ` +
        `d'inventaire (${inside.length} occurrences en tout) : ` +
        `${counted.map((hit) => `${hit.path} « ${hit.word} »`).join(", ")}`,
    ).toBe(7);
  });

  test("chaque copie hors du périmètre est un constat daté, ou n'annonce aucun nombre", () => {
    expect(outside.length, "plus aucune copie hors du périmètre : le test ne garde rien")
      .toBeGreaterThan(0);
    const dated = outside.filter((hit) => hit.tail.startsWith(DATED));
    expect(dated.length, "aucun constat daté trouvé hors du périmètre").toBeGreaterThan(0);
    for (const hit of outside) {
      if (hit.tail.startsWith(DATED)) continue;
      expect(
        NUMBERS.has(hit.word),
        `${hit.path} écrit « ${hit.word} corpus matériels » hors du périmètre ` +
          `d'inventaire sans être un constat daté : soit la phrase annonce un ` +
          `inventaire et le fichier doit entrer dans le périmètre, soit elle date ` +
          `un constat et doit le dire`,
      ).toBe(false);
    }
  });
});
