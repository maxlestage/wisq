import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { copy } from "../src/content";

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

function claimedValue(label: RegExp): number {
  const item = copy.en.facts.items.find((entry) => label.test(entry.label));
  if (!item) throw new Error(`aucun chiffre annoncé ne correspond à ${label}`);
  return Number(item.value);
}

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

    const page = readFileSync(
      join(import.meta.dir, "..", "src", "pages", "architecture.ts"),
      "utf8",
    );
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
    for (const item of copy.en.facts.items) {
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
    const published = new Set(copy.en.facts.items.map((item) => item.label));
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
const pagesDirectory = join(import.meta.dir, "..", "src", "pages");

/// Un nombre, éventuellement à espaces ou à virgule, qui n'est pas collé à un
/// mot ni à un trait d'union : « x86-64 » et « rv32ima » ne sont pas des
/// chiffres publiés, « 10 116 » en est un.
const publishedNumber = /(?<![-\w])\d[\d   ]*(?:[.,]\d+)?(?![\w])/g;

function pageFiles(): string[] {
  return readdirSync(pagesDirectory)
    .filter((name) => name.endsWith(".ts"))
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
    "roadmap.ts",
    provenanceOf([
      [
        "10 116",
        "les régions d'entrée atteintes par un `call` du noyau Alpine : " +
          "`cargo run -p wisq-vm --release --example coverage -- <noyau>`. " +
          "Pas tenu par la CI — l'étape récupère l'image en best effort.",
      ],
      [
        "17",
        "les régions compilées portant un octet illisible, même commande, même " +
          "relevé. Elles se comptent dans la même ligne que les 10 116.",
      ],
      [
        "9660",
        "ce n'est pas une mesure : c'est le numéro de la norme ISO des " +
          "systèmes de fichiers de disque optique.",
      ],
    ]),
  ],
  [
    "protocol.ts",
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
        "1.8",
        "tenu, pas seulement mesuré : `scripts/check-agent-size.sh` compare " +
          "cette phrase au binaire que la CI construit déjà dans son job Rust " +
          "(`cargo build --release --target x86_64-unknown-linux-musl " +
          "-p wisq-agent`), avec les quatre autres textes qui annoncent la même " +
          "taille. 1 778 384 octets le 28 septembre 2026, soit 1,8 Mo décimaux.",
      ],
      [
        "1,8",
        "le même nombre dans l'autre langue : la page est écrite deux fois, et " +
          "la virgule décimale en fait un jeton distinct. Tenu par la même " +
          "garde, qui lit les deux phrases séparément.",
      ],
    ]),
  ],
  [
    "faq.ts",
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
        "2",
        "ce n'est pas une mesure : les deux gibioctets de " +
          "`LinuxMachine.maximumRAMSize`, plafond d'adressage du rv32 — sa RAM " +
          "commence à 0x80000000 et son processeur adresse en 32 bits.",
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
    ]),
  ],
  [
    "docs.ts",
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
        "64",
        "ce n'est pas une mesure : `LinuxMachine.defaultRAMSize`, ce qu'un " +
          "noyau reçoit quand personne n'a touché au curseur.",
      ],
      [
        "2",
        "ce n'est pas une mesure : les deux gibioctets de " +
          "`LinuxMachine.maximumRAMSize`, plafond d'adressage du rv32.",
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
        "1",
        "ce n'est pas une mesure : l'écran `:1` de la même commande d'exemple.",
      ],
      [
        "0",
        "ce n'est pas une mesure : l'écran `:0` que `x11vnc -display :0` " +
          "expose, dans la seconde ligne du même exemple.",
      ],
    ]),
  ],
  [
    "architecture.ts",
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
        "8",
        "deux lectures dans la même page, et les deux tiennent : le « +8 % » de " +
          "l'extension de signe sans branchement (CHANGELOG 0.2.0), et le vert " +
          "à 8 du format de pixel — `RFB.swift`, `greenShift: 8`.",
      ],
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
    ]),
  ],
  // La réserve sur le transport ne porte plus « version 1 » : elle disait le
  // clair comme une fatalité alors que c'est un défaut, et le numéro de
  // version n'ajoutait rien qu'un chiffre à tenir.
  ["privacy.ts", new Map()],
  ["index.ts", new Map()],
  ["offline.ts", new Map()],
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
    "releases.ts",
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
  test("toute page de src/pages est tenue, avouée non tenue, ou nommée hors sujet", () => {
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
