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

/// Les pages tenues. Chaque entrée dit **comment on refait le nombre**, ou
/// pourquoi ce n'est pas une mesure. Une entrée qui ne saurait dire ni l'un ni
/// l'autre n'a rien à faire sur une page qui parle au présent.
const accounted = new Map<string, Map<string, string>>([
  [
    "roadmap.ts",
    new Map([
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
    new Map([
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
  ["index.ts", new Map()],
  ["offline.ts", new Map()],
]);

/// Les pages que rien ne relit. L'entrée porte **la liste exacte** des chiffres
/// qu'elles publient : ça n'affirme rien sur leur vérité, ça interdit seulement
/// qu'un chiffre y bouge sans que quelqu'un le voie. Chacune attend sa tranche.
const notLookedAt = new Map<string, string[]>([
  [
    "architecture.ts",
    ["0", "0,1", "0,22", "0.1", "0.22", "16", "194", "2 000", "2,7", "2.7",
      "3", "32", "33", "36,7", "36.7", "47", "50", "8", "9"],
  ],
  [
    "docs.ts",
    ["0", "1", "2", "2048", "3.8", "512", "5900", "5901", "64", "7442", "8250"],
  ],
  ["faq.ts", ["0.2", "160", "2", "32", "44,6", "44.6", "64"]],
  ["privacy.ts", ["1"]],
]);

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
