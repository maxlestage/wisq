/// **Nommer ce qui a tourné ne dit pas ce qui aurait dû tourner.**
///
/// #278 a posé la règle « nommer, pas compter » : « 11 sautés » se lit aussi
/// bien comme une panne réseau **que comme une suite disparue du binaire**.
/// Le relevé de l'iPhone simulé nomme bien ses suites depuis, et pourtant il
/// ne répond toujours pas à la seconde moitié de cette phrase. Une suite
/// retirée de `project.yml`, un fichier sorti de `sources`, une classe
/// renommée : le relevé serait simplement **plus court**, et le job vert.
///
/// Ce qui manquait est la comparaison que ce dépôt fait partout ailleurs —
/// deux listes qui devraient s'accorder. Les suites **déclarées** par
/// `project.yml` d'un côté, celles qui ont rendu un verdict de l'autre.
///
/// **Et ce relevé perdait déjà une suite sur douze, pour une autre raison.**
/// Mesuré sur le journal réel du job « App iOS » 106133490635 (fusion de
/// #416) : `OversizedKernelRefusalTests` y rend son verdict **sans** sa ligne
/// de compte, seule des douze. Elle n'a qu'un test, et XCTest écrit alors
/// `Executed 1 test` — au singulier. Le motif exigeait `tests`. Le script
/// frère `report-skipped.sh` écrivait déjà `tests?` ; celui-ci non.
///
/// **Ce relevé-ci refuse, là où `report-skipped.sh` se contente de montrer.**
/// La différence n'est pas d'humeur : un test qui saute parce qu'un serveur
/// tiers n'a pas répondu n'est pas un défaut du dépôt, tandis qu'une suite
/// déclarée qui ne rend aucun verdict en est un à tous les coups. Il ne
/// refuse toutefois que si `xcodebuild` a réussi — sur une exécution déjà
/// rouge, le journal est partiel et accuser serait mentir.

import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

setDefaultTimeout(20_000);

const repoRoot = join(import.meta.dir, "..", "..");
const releve = join(repoRoot, "scripts", "report-app-suites.sh");

function run(journal: string, code = 0): { out: string; summary: string; exit: number } {
  const root = mkdtempSync(join(tmpdir(), "wisq-app-suites-"));
  const journalFile = join(root, "xcodebuild.log");
  const summaryFile = join(root, "summary.md");
  writeFileSync(journalFile, journal);
  writeFileSync(summaryFile, "");
  const done = Bun.spawnSync({
    cmd: [releve, journalFile, String(code)],
    env: { ...process.env, GITHUB_STEP_SUMMARY: summaryFile, RUNNER_TEMP: root },
  });
  return {
    out: done.stdout.toString() + done.stderr.toString(),
    summary: readFileSync(summaryFile, "utf8"),
    exit: done.exitCode ?? -1,
  };
}

/// Le relevé qu'« App iOS » a publié pour la fusion de #416 (run 35531759964,
/// job 106133490635), recopié tel quel. Chacune de ces lignes est sortie
/// verbatim de `xcodebuild`, donc ce texte est un échantillon honnête de ce
/// que le script lit — et non une reconstitution.
///
/// On y voit le défaut mesuré : `OversizedKernelRefusalTests` passe sans
/// ligne de compte. Le total du bundle, 47, est la somme exacte des neuf
/// classes de `WisqUITests` **y compris** son test unique — il a donc bien
/// tourné, et c'est l'extraction qui l'a perdu.
const POMME = `Test Suite 'ConnectionFileImportTests' passed at 2026-09-20 19:24:04.576.
\t Executed 6 tests, with 0 failures (0 unexpected) in 0.016 (0.030) seconds
Test Suite 'DiskLibraryTests' passed at 2026-09-20 19:24:05.024.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.050 (0.057) seconds
Test Suite 'KernelMemoryNoteTests' passed at 2026-09-20 19:24:06.517.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
Test Suite 'LocalVMModelTests' passed at 2026-09-20 19:25:05.142.
\t Executed 15 tests, with 0 failures (0 unexpected) in 58.510 (58.625) seconds
Test Suite 'MachineLibrarySecretsTests' passed at 2026-09-20 19:26:06.124.
\t Executed 5 tests, with 0 failures (0 unexpected) in 60.979 (60.982) seconds
Test Suite 'OversizedKernelRefusalTests' passed at 2026-09-20 19:26:06.143.
\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'PartialLibraryBannerTests' passed at 2026-09-20 19:26:06.280.
\t Executed 6 tests, with 0 failures (0 unexpected) in 0.015 (0.137) seconds
Test Suite 'RefusalTextTests' passed at 2026-09-20 19:26:06.553.
\t Executed 5 tests, with 0 failures (0 unexpected) in 0.089 (0.272) seconds
Test Suite 'StorageLineTests' passed at 2026-09-20 19:26:06.644.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
\t Executed 47 tests, with 0 failures (0 unexpected) in 119.681 (122.216) seconds
bureau : 4.540898837149143 ms par région traduite, 6.328908324831191 fois une lecture de registre par le pont (0.717485323548317 ms), sur 128 régions
Test Suite 'LocalDesktopTests' passed at 2026-09-20 19:27:34.555.
\t Executed 10 tests, with 0 failures (0 unexpected) in 16.233 (16.238) seconds
Metal compilation : 1254.1170120239258 ms pour un noyau
Metal un fil : 100 MIPS sur 28 M instructions
Metal comparé au Swift natif : 1572 MIPS
Metal lancement : 0.5999553203582764 ms par aller-retour
Test Suite 'MetalCompilerProbeTests' passed at 2026-09-20 19:27:36.382.
\t Executed 3 tests, with 0 failures (0 unexpected) in 1.825 (1.826) seconds
pont : 0.46918511390686035 ms par aller-retour
WebKit : 1538 MIPS sur 160 M instructions
Test Suite 'WebKitJITProbeTests' passed at 2026-09-20 19:27:39.666.
\t Executed 2 tests, with 0 failures (0 unexpected) in 3.281 (3.283) seconds
\t Executed 15 tests, with 0 failures (0 unexpected) in 21.339 (21.350) seconds
`;

/// **La ligne au singulier, mesurée plutôt que supposée.** Deux classes, l'une
/// d'un test et l'autre de deux, lancées sous la chaîne Swift 6.3 de ce
/// conteneur. C'est la sortie telle quelle : XCTest écrit bien `Executed 1
/// test,` sans `s`, et c'est ce qui manquait au motif.
const SINGULIER = `Test Suite 'DeuxTests' passed at 2026-09-21 03:33:51.618.
\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'UnSeulTests' passed at 2026-09-21 03:33:51.618.
\t Executed 1 test, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
`;

/// **Une mention en commentaire ne vaut ni acquittement.** Écrit après qu'un
/// sabotage a survécu : retirer l'appel de `test-app.sh` ne faisait tomber
/// aucun test, parce que le commentaire qui explique l'appel nomme le script.
/// L'assertion était satisfaite par un autre chemin que celui qu'elle prétend
/// mesurer — la faute que ce dépôt a déjà nommée deux fois. On dépouille donc
/// les lignes de commentaire avant de juger, shell et YAML partageant le `#`.
function sansCommentaires(chemin: string): string {
  return readFileSync(join(repoRoot, chemin), "utf8")
    .split("\n")
    .filter((ligne) => !/^\s*#/.test(ligne))
    .join("\n");
}

/// Les suites qui ont rendu un verdict **dans ce journal-ci**, lues du journal
/// et non d'une liste tenue à côté. Une liste écrite à la main aurait à être
/// mise à jour à chaque suite ajoutée à l'application, et ce qu'elle
/// prétendrait mesurer — que le relevé nomme ce qui a tourné — n'a rien à voir
/// avec ce qui est déclaré aujourd'hui.
function suitesDuJournal(journal: string): string[] {
  return [...journal.matchAll(/Test Suite '([A-Za-z_][A-Za-z0-9_]*)' (?:passed|failed)/g)].map(
    (trouvaille) => trouvaille[1],
  );
}

/// Les suites que le relevé accuse, lues de sa sortie.
function suitesAccusees(sortie: string): string[] {
  return [...sortie.matchAll(/::error::([A-Za-z_][A-Za-z0-9_]*) n'a rendu aucun verdict\./g)].map(
    (trouvaille) => trouvaille[1],
  );
}

function sans(journal: string, suite: string): string {
  return journal
    .split("\n")
    .filter((ligne) => !ligne.includes(`Test Suite '${suite}'`))
    .join("\n");
}

describe("le relevé de l'iPhone simulé", () => {
  test("sur le vrai journal, chaque suite qui a tourné est nommée, et aucune n'est accusée", () => {
    const { out } = run(POMME);
    for (const suite of suitesDuJournal(POMME)) {
      expect(out, `${suite} doit être nommée`).toContain(suite);
      expect(out, `${suite} a rendu son verdict : elle ne doit pas être accusée`).not.toContain(
        `::error::${suite} n'a rendu aucun verdict.`,
      );
    }
    expect(suitesDuJournal(POMME).length, "un journal sans suite ne mesurerait rien").toBe(12);
  });

  /// **Et le journal complété est accepté.** Le test ci-dessus ne peut plus
  /// exiger un code de sortie nul : `POMME` est un journal **daté**, recopié
  /// du job 106133490635, et toute suite déclarée depuis y manque forcément.
  /// Exiger zéro dessus revenait à interdire d'ajouter une suite à
  /// l'application sans rougir — la garde de #282 s'est d'ailleurs déclenchée
  /// sur la première qui est arrivée.
  ///
  /// Ce qu'on tient ici est donc l'aller-retour : on demande au script quelles
  /// suites lui manquent, on leur donne un verdict de la même forme que les
  /// autres, et il doit alors accepter. Les noms viennent de sa propre
  /// sortie ; rien n'est réécrit dans le journal mesuré, et aucune liste n'est
  /// tenue à la main à côté de `project.yml`.
  test("un journal où toutes les suites déclarées ont répondu est accepté", () => {
    const manquantes = suitesAccusees(run(POMME).out);
    const complet =
      POMME +
      manquantes
        .map(
          (suite) =>
            `Test Suite '${suite}' passed at 2026-09-20 19:26:06.644.\n` +
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n",
        )
        .join("");

    const { out, exit } = run(complet);
    expect(out, out).not.toContain("::error::");
    expect(exit).toBe(0);
    expect(out).toContain("ont toutes rendu un verdict");
  });

  /// La garde elle-même. Une suite qui disparaît du bundle ne se voit pas dans
  /// un relevé plus court ; elle doit être **nommée**, et faire rougir.
  test("une suite déclarée qui ne rend aucun verdict est nommée et refusée", () => {
    const { out, exit } = run(sans(POMME, "ConnectionFileImportTests"));
    expect(exit).not.toBe(0);
    expect(out).toContain("::error::");
    expect(out).toContain("ConnectionFileImportTests");
    // Et elle n'accuse pas les innocentes.
    expect(out).not.toMatch(/n'a rendu aucun verdict[\s\S]*DiskLibraryTests/);
  });

  /// La prémisse. Une garde dont la liste attendue arriverait vide passerait
  /// sur n'importe quoi — c'est la forme d'échec que ce dépôt a payée le plus
  /// souvent. Un journal vide doit donc être refusé, pas acquitté.
  test("un journal vide ne s'acquitte pas tout seul", () => {
    const { out, exit } = run("");
    expect(exit).not.toBe(0);
    expect(out).toContain("::error::");
    expect(out).toContain("LocalDesktopTests");
  });

  /// Le nombre de suites déclarées est lu de `project.yml`, pas écrit en dur.
  /// S'il tombait à zéro, la garde ne garderait plus rien et les deux tests
  /// ci-dessus passeraient encore.
  test("les suites attendues sont lues de project.yml, et il y en a", () => {
    const { out } = run(POMME);
    const compte = out.match(/Suites déclarées \((\d+)\)/);
    expect(compte, "le relevé doit dire combien de suites il attend").not.toBeNull();
    expect(Number(compte![1])).toBeGreaterThan(5);
    // Une de chaque bundle : la lecture couvre les deux cibles de la scheme.
    expect(out).toContain("ConnectionFileImportTests"); // WisqUITests
    expect(out).toContain("LocalDesktopTests"); // WisqHostedTests
  });

  /// Le défaut mesuré sur le journal réel : une suite d'un seul test écrit
  /// `Executed 1 test`, au singulier, et le motif exigeait `tests`.
  test("une suite d'un seul test garde sa ligne de compte", () => {
    // Ce journal-ci ne porte aucune des suites déclarées, donc la garde
    // refuse — ce n'est pas ce qu'on mesure ici. Ce qu'on mesure est
    // l'extraction : les deux lignes de compte doivent y être, le singulier
    // comme le pluriel.
    const { out } = run(SINGULIER);
    expect(out).toContain("Executed 1 test,");
    expect(out).toContain("Executed 2 tests,");
  });

  /// Un `xcodebuild` rouge laisse un journal partiel. Accuser les suites qui
  /// n'ont pas eu le temps de tourner ajouterait un faux coupable à un job
  /// déjà rouge — et c'est le job, pas ce relevé, qui porte l'échec.
  test("sur une exécution déjà rouge, le relevé montre sans accuser", () => {
    const { out, exit } = run(sans(POMME, "ConnectionFileImportTests"), 65);
    expect(exit).toBe(0);
    expect(out).not.toContain("::error::");
    expect(out).toContain("partiel");
  });

  /// **La leçon de #279, prise d'avance.** Le relevé des tests sautés avait été
  /// branché sur un des trois endroits qui lancent `swift test`, et le job
  /// Apple a sauté trente-six tests pendant des mois sans que rien ne le dise.
  /// `xcodebuild test` n'a qu'un appelant aujourd'hui — mesuré, pas supposé —,
  /// et c'est maintenant qu'il faut tenir la règle, pas après le deuxième.
  test("tout ce qui lance xcodebuild test lance aussi le relevé", () => {
    const corpus = [
      ...readdirSync(join(repoRoot, ".github", "workflows"))
        .filter((nom) => /\.ya?ml$/.test(nom))
        .map((nom) => join(".github", "workflows", nom)),
      ...readdirSync(join(repoRoot, "scripts"))
        .filter((nom) => nom.endsWith(".sh"))
        .map((nom) => join("scripts", nom)),
    ];
    const lanceurs = corpus.filter((chemin) => sansCommentaires(chemin).includes("xcodebuild test"));
    expect(lanceurs.length, "aucun lanceur trouvé : la règle ne garderait rien").toBeGreaterThan(0);
    for (const chemin of lanceurs) {
      expect(
        sansCommentaires(chemin),
        `${chemin} lance la suite de l'application sans en relever les suites`,
      ).toContain("report-app-suites.sh");
    }
  });
});
