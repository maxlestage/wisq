/// Les scripts de garde du dépôt, et ce qui les tient tous.
///
/// Le dépôt a une série de scripts `scripts/check-*.sh` que `verify.sh` et la
/// CI lancent. Chacun refuse quelque chose : une licence annoncée, un projet
/// Xcode qui ne correspond plus à sa spec, un secret de signature, une
/// matrice d'architectures, une mise en forme. Et chacun a le même piège
/// natif, celui qui a coûté trois tranches : **un script qui ne tourne que
/// contre cet arbre-ci, où tout va bien, n'a jamais rien refusé.**
///
/// La série qui a clos ce piège l'a clos pour les **trois** scripts qui
/// existaient alors. Il y en a **sept**. Les quatre arrivés depuis ont chacun
/// leur test, et chacun y est vu refuser — vérifié à la main, tranche #322 —
/// mais rien ne l'exigeait, et un huitième pouvait arriver nu sans que rien ne
/// le dise. C'est exactement la forme du défaut que la série traquait : une
/// absence qu'un arbre propre rend muette.
///
/// Ce fichier tient donc trois choses, toutes mécaniques :
///
/// 1. **Le compte**, là où une phrase l'annonce. L'en-tête de
///    `whitespace-guard.test.ts` dit le rang de son script parmi les gardes et
///    le nombre des autres ; les deux doivent tomber juste, et le script qu'il
///    dit « dernier » doit l'être.
/// 2. **Chaque garde est nommée par un test du site.** Exact : un script que
///    personne ne cite ne peut pas être mis devant un arbre fautif.
/// 3. **Chaque garde prend une racine en argument.** C'est la condition qui
///    rend la mise devant un arbre fautif *possible* — la propriété que la
///    série a établie, en amont de l'existence d'un test. Un script qui ignore
///    `$1` ne peut regarder que ce dépôt-ci, et il est muet par construction.
///
/// Ce que ce fichier **ne** prouve **pas**, et le dire vaut mieux que le
/// laisser croire : il ne prouve pas qu'un refus observé dans un test donné
/// est celui de ce script-là. Les sept le sont, mesuré cette tranche ; mais
/// une assertion sur un *résultat* peut être satisfaite par un autre chemin, et
/// un motif qui irait chercher « un `exitCode` non nul quelque part dans le
/// fichier » serait une empreinte, pas l'acte. Les trois propriétés
/// ci-dessus, elles, se lisent sans interprétation.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

describe("les scripts de garde du dépôt sont tous tenus", () => {
  /// Un script de garde est un `scripts/check-*.sh`. L'ordre est celui du
  /// système de fichiers, trié : c'est lui qui donne un sens à « dernier ».
  const guards = readdirSync(join(repoRoot, "scripts"))
    .filter((entry) => /^check-.*\.sh$/.test(entry))
    .sort();

  /// Les tests du site, sauf celui-ci : il nomme les gardes par lecture de
  /// répertoire et non par leur nom, mais s'exclure rend l'intention explicite
  /// plutôt que dépendante de la façon dont ce fichier est écrit.
  const siteTests = readdirSync(join(repoRoot, "site", "tests"))
    .filter((entry) => entry.endsWith(".test.ts") && entry !== "guard-scripts.test.ts")
    .map((entry) => ({ name: entry, text: readFileSync(join(repoRoot, "site/tests", entry), "utf8") }));

  test("la phrase qui annonce leur nombre l'annonce juste", () => {
    /// Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
    expect(guards.length, "aucun script de garde trouvé").toBeGreaterThan(3);

    const ORDINAUX: Record<string, number> = {
      first: 1,
      second: 2,
      third: 3,
      fourth: 4,
      fifth: 5,
      sixth: 6,
      seventh: 7,
      eighth: 8,
      ninth: 9,
      tenth: 10,
    };
    const NOMBRES: Record<string, number> = {
      two: 2,
      three: 3,
      four: 4,
      five: 5,
      six: 6,
      seven: 7,
      eight: 8,
      nine: 9,
    };

    const header = readFileSync(join(repoRoot, "site/tests/whitespace-guard.test.ts"), "utf8");

    /// « … is the Nth and last of this repository's guard scripts … »
    const rank = header.match(/is the (\p{L}+) and last of this repository's/u);
    expect(rank, "la phrase qui donne le rang a changé de forme").not.toBeNull();
    const said = ORDINAUX[rank![1].toLowerCase()];
    expect(said, `« ${rank![1]} » n'est pas un ordinal que je sais lire`).not.toBeUndefined();
    expect(said, `la phrase dit « ${rank![1]} », il y a ${guards.length} scripts de garde`)
      .toBe(guards.length);

    /// Et « dernier » est une place, pas un compte : elle se vérifie.
    expect(guards[guards.length - 1], "le script que la phrase dit dernier ne l'est pas")
      .toBe("check-whitespace.sh");

    /// « … the same hole as the other N … » — les autres, donc un de moins.
    const others = header.match(/like the other (\p{L}+) it answers a hole native to all of/u);
    expect(others, "la phrase qui compte les autres a changé de forme").not.toBeNull();
    const counted = NOMBRES[others![1].toLowerCase()];
    expect(counted, `« ${others![1]} » n'est pas un nombre que je sais lire`).not.toBeUndefined();
    expect(counted, `la phrase dit « ${others![1]} » autres pour ${guards.length} gardes`)
      .toBe(guards.length - 1);
  });

  test("la phrase qui compte les gardes absentes des workflows les compte juste", () => {
    expect(guards.length).toBeGreaterThan(3);

    /// Une garde « nommée dans un workflow » est une garde dont le nom de
    /// fichier apparaît dans un `.github/workflows/*.yml`. C'est exact : si son
    /// nom n'y est pas, aucun job ne l'appelle.
    const workflows = readdirSync(join(repoRoot, ".github", "workflows"))
      .filter((entry) => entry.endsWith(".yml"))
      .map((entry) => readFileSync(join(repoRoot, ".github/workflows", entry), "utf8"))
      .join("\n");
    const absent = guards.filter((guard) => !workflows.includes(guard));

    const NOMBRES: Record<string, number> = {
      zero: 0,
      one: 1,
      two: 2,
      three: 3,
      four: 4,
      five: 5,
      six: 6,
      seven: 7,
    };
    const header = readFileSync(join(repoRoot, "site/tests/whitespace-guard.test.ts"), "utf8");
    const said = header.match(
      /(\p{L}+) of the (\p{L}+) guard scripts are named in no workflow/u,
    );
    expect(said, "la phrase qui compte les gardes hors des workflows a changé de forme")
      .not.toBeNull();

    expect(
      NOMBRES[said![1].toLowerCase()],
      `la phrase dit « ${said![1]} » hors des workflows ; il y en a ${absent.length} : `
        + absent.join(", "),
    ).toBe(absent.length);
    expect(
      NOMBRES[said![2].toLowerCase()],
      `la phrase dit « ${said![2]} » gardes en tout, il y en a ${guards.length}`,
    ).toBe(guards.length);
  });

  test("chaque garde est mise devant un autre arbre par un test du site", () => {
    expect(guards.length).toBeGreaterThan(3);
    for (const guard of guards) {
      /// **Nommer ne suffit pas, et c'est mesuré.** La première forme de ce
      /// contrôle demandait seulement qu'un test du site cite la garde. Le
      /// sabotage qui retirait la citation du test dédié a **survécu** :
      /// `claims.test.ts` cite les sept scripts pour une raison qui n'a rien à
      /// voir — il vérifie des chiffres annoncés —, et `verify-covers-ci.test.ts`
      /// en cite trois pour comparer `verify.sh` à la CI. La propriété était
      /// donc satisfaite par un autre chemin que celui qui compte.
      ///
      /// Ce qui compte est qu'un test **construise un autre arbre** : c'est la
      /// signature de l'acte, puisqu'un arbre propre ne fait rien dire à une
      /// garde. Aucun des deux citeurs de passage n'appelle `mkdtempSync`.
      const driving = siteTests
        .filter((file) => file.text.includes(guard) && file.text.includes("mkdtempSync"))
        .map((file) => file.name);
      expect(
        driving.length,
        `${guard} : aucun test du site ne le nomme en construisant un arbre temporaire, `
          + `donc personne ne le met devant un arbre fautif — et un arbre propre `
          + `ne lui fait rien dire`,
      ).toBeGreaterThan(0);
    }
  });

  /// **La propriété que #322 a cru tenir, et ne tenait pas.**
  ///
  /// #322 comptait les gardes absentes des workflows — trois — et l'en-tête de
  /// `whitespace-guard.test.ts` ajoutait que celle de la mise en forme était
  /// « la seule des trois qu'un test du site lance néanmoins sur l'arbre
  /// réel ». C'était **faux** : `project-sources.test.ts` et
  /// `generated-project.test.ts` portent chacun un test « le dépôt tel qu'il
  /// est passe » qui lance sa garde sur `repoRoot` et exige zéro. Les trois
  /// étaient couvertes. J'avais conclu d'une absence — aucun workflow ne les
  /// nomme — sans chercher la même présence là où je savais qu'elle était, ce
  /// qui est la règle de #261 appliquée contre moi pour la troisième fois.
  ///
  /// La leçon porte sur la garde, pas sur la phrase : **une affirmation en
  /// prose plus forte que ce que la garde vérifie est exactement ce que la
  /// garde existe pour empêcher.** #322 comptait ; il n'établissait pas la
  /// couverture, et la prose, elle, la proclamait.
  ///
  /// Donc ce contrôle ne cherche pas un motif dans un fichier de test : il
  /// **fait l'acte**. Chaque garde qu'aucun workflow ne nomme est lancée ici,
  /// sur ce dépôt, et doit rendre zéro — et comme ce fichier tourne sous
  /// `bun test`, donc dans le job `Build site`, la propriété est **tenue** par
  /// la CI au lieu d'être affirmée. Mesuré : `check-project-sources.sh` 56 ms,
  /// `check-generated-project.sh` 29 ms, aucune ne demande XcodeGen.
  test("les gardes qu'aucun workflow ne nomme sont lancées sur ce dépôt, ici", () => {
    const workflows = readdirSync(join(repoRoot, ".github", "workflows"))
      .filter((entry) => entry.endsWith(".yml"))
      .map((entry) => readFileSync(join(repoRoot, ".github/workflows", entry), "utf8"))
      .join("\n");
    const absent = guards.filter((guard) => !workflows.includes(guard));

    /// Un contrôle qui ne lance rien ressemble à un contrôle qui passe.
    expect(absent.length, "aucune garde hors des workflows : ce contrôle ne lancerait rien")
      .toBeGreaterThan(0);

    /// Et la phrase de l'en-tête annonce ce même compte : si une garde entre
    /// dans un workflow ou en sort, les deux doivent bouger ensemble.
    const NOMBRES: Record<string, number> = {
      one: 1,
      two: 2,
      three: 3,
      four: 4,
      five: 5,
      six: 6,
      seven: 7,
    };
    const header = readFileSync(join(repoRoot, "site/tests/whitespace-guard.test.ts"), "utf8");
    const claim = header.match(/runs each of those (\p{L}+) against the real tree/u);
    expect(claim, "la phrase qui annonce la couverture a changé de forme").not.toBeNull();
    expect(
      NOMBRES[claim![1].toLowerCase()],
      `la phrase dit « ${claim![1]} » gardes couvertes ici, il y en a ${absent.length}`,
    ).toBe(absent.length);

    for (const guard of absent) {
      const run = Bun.spawnSync([join(repoRoot, "scripts", guard), repoRoot], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const said = new TextDecoder().decode(run.stdout) + new TextDecoder().decode(run.stderr);
      expect(
        run.exitCode,
        `${guard} refuse ce dépôt, et aucun workflow ne le lance :\n${said}`,
      ).toBe(0);
    }
  });

  test("chaque garde prend une racine en argument", () => {
    expect(guards.length).toBeGreaterThan(3);
    for (const guard of guards) {
      const text = readFileSync(join(repoRoot, "scripts", guard), "utf8");
      expect(
        text,
        `${guard} n'utilise pas \${1} : il ne peut regarder que ce dépôt-ci, `
          + `où rien n'est fautif, donc il est muet par construction`,
      ).toContain("${1:-");
    }
  });
});
