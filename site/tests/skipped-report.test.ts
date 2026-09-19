/// **Un job vert ne dit pas si les tests ont tourné.**
///
/// `ci.yml` récupère le noyau rv32 de test en « best effort » — `curl … || true`,
/// délibérément, et l'en-tête de l'étape l'assume. Si ce téléchargement échoue,
/// onze tests Swift sautent, dont les quatre différentiels et les deux qui
/// comparent les instantanés des deux cœurs ; les tests Rust `boot.rs` et
/// `snapshot.rs` sautent aussi, le banc sort en `exit 0`, et
/// `scripts/test-rust-core.sh` se contente d'un `::warning::`. **Tout reste
/// vert**, et rien ne distingue cette exécution d'une où tout a tourné.
///
/// Trois issues étaient possibles : laisser ; faire échouer franchement, ce qui
/// met la CI à la merci d'un téléchargement tiers ; ou rendre la dégradation
/// **visible** sans la rendre bloquante. C'est la troisième, et
/// `scripts/report-skipped.sh` la porte.
///
/// **Ce que ce relevé n'est pas.** Ce n'est pas une garde : il ne refuse rien,
/// et c'est voulu — faire rougir un job parce qu'un serveur tiers n'a pas
/// répondu est la décision que cette tranche ne prend pas. Ce qui est tenu
/// ici, c'est qu'il **nomme** ce qui a sauté et pourquoi. Un relevé qui
/// compterait sans nommer laisserait « 11 sautés » se lire aussi bien comme
/// une panne réseau que comme une suite disparue du binaire.

import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

setDefaultTimeout(20_000);

const repoRoot = join(import.meta.dir, "..", "..");
const report = join(repoRoot, "scripts", "report-skipped.sh");

/// Le relevé écrit dans `$GITHUB_STEP_SUMMARY` quand il y en a un, et sur la
/// sortie standard toujours. On lui en donne un, pour juger les deux.
function run(log: string): { out: string; summary: string; code: number } {
  const root = mkdtempSync(join(tmpdir(), "wisq-skipped-"));
  const logFile = join(root, "test.log");
  const summaryFile = join(root, "summary.md");
  writeFileSync(logFile, log);
  writeFileSync(summaryFile, "");
  const done = Bun.spawnSync({
    cmd: [report, logFile],
    env: { ...process.env, GITHUB_STEP_SUMMARY: summaryFile },
  });
  return {
    out: done.stdout.toString() + done.stderr.toString(),
    summary: readFileSync(summaryFile, "utf8"),
    code: done.exitCode ?? -1,
  };
}

/// Ce que `swift test` écrit vraiment quand l'image manque — recopié d'une
/// exécution, pas inventé.
const ABSENT = `Test Suite 'SnapshotAgreementTests' started at 2026-09-19 12:57:45.206
/w/Tests/WisqVMRustTests/DifferentialBootTests.swift:253: SnapshotAgreementTests.testBothCoresWriteTheSameSnapshotBytes : Test skipped - image Linux absente : définir WISQ_LINUX_IMAGE pour ce test
/w/Tests/WisqVMRustTests/DifferentialBootTests.swift:341: SnapshotAgreementTests.testEachCoreResumesFromTheOthersSnapshot : Test skipped - image Linux absente : définir WISQ_LINUX_IMAGE pour ce test
/w/Tests/WisqVMTests/LinuxBootTests.swift:28: LinuxBootTests.testBootsARealKernelToItsBanner : Test skipped - image Linux absente : définir WISQ_LINUX_IMAGE pour ce test
\t Executed 93 tests, with 3 tests skipped and 0 failures (0 unexpected) in 7.804 (7.804) seconds
`;

/// Et ce qu'il écrit quand tout a tourné.
const PRESENT = `Test Case 'SnapshotAgreementTests.testBothCoresWriteTheSameSnapshotBytes' passed (0.556 seconds)
\t Executed 93 tests, with 0 failures (0 unexpected) in 10.24 (10.24) seconds
`;

describe("le relevé des tests sautés", () => {
  test("nomme les suites sautées, et pas seulement leur nombre", () => {
    const { summary } = run(ABSENT);
    expect(summary).toContain("SnapshotAgreementTests.testBothCoresWriteTheSameSnapshotBytes");
    expect(summary).toContain("LinuxBootTests.testBootsARealKernelToItsBanner");
  });

  test("dit la raison, parce que c'est elle qui nomme la panne", () => {
    expect(run(ABSENT).summary).toContain("image Linux absente");
  });

  test("porte le compte, à côté des noms", () => {
    expect(run(ABSENT).summary).toContain("3");
  });

  /// **Le contre-cas, et c'est celui qui compte.** Un relevé qui dirait
  /// quelque chose sur une exécution complète apprendrait à le lire comme du
  /// bruit, et on cesserait de le lire le jour où il a raison.
  test("dit clairement qu'aucun test n'a sauté quand aucun n'a sauté", () => {
    const { summary } = run(PRESENT);
    expect(summary).toContain("Aucun test sauté");
    expect(summary).not.toContain("image Linux absente");
  });

  /// **Il ne prend pas un nom pour un verdict.** Un test qui s'appellerait
  /// `testSkippedFrames` contient le mot ; ce n'est pas un test sauté.
  test("ne compte pas un test dont le nom contient « skipped »", () => {
    const log = `Test Case 'DisplayTests.testSkippedFramesAreCounted' passed (0.01 seconds)
\t Executed 1 test, with 0 failures (0 unexpected) in 0.01 (0.01) seconds
`;
    expect(run(log).summary).toContain("Aucun test sauté");
  });

  /// **Et il ne fait pas rougir le job.** C'est la décision de cette tranche,
  /// écrite plutôt que sous-entendue : rendre visible, pas bloquant.
  test("sort avec zéro même quand des tests ont sauté", () => {
    expect(run(ABSENT).code).toBe(0);
  });
});

/// **Et l'asymétrie que ce relevé s'est lui-même créée.**
///
/// #278 a branché le relevé sur « Cœur (Linux) », le job qui lance la suite. Il
/// n'est pas le seul à la lancer. Mesuré sur le run 35459310059 — la fusion de
/// #278 elle-même, donc la première exécution de l'instrument :
///
/// | job | exécutés | sautés | le job le dit ? |
/// |---|---|---|---|
/// | `core` — Cœur (Linux) | 2063 | 14 | oui |
/// | `core-apple` — Cœur (Apple) | 1965 | **36** | **non** |
///
/// Trente-six, et le commentaire au-dessus de ce `swift test` en annonçait
/// « around fifteen ». Personne ne les a jamais nommés : ni le ROADMAP, ni le
/// JOURNAL, ni le résumé du job. Le troisième endroit qui lance la suite est
/// `release.yml`, juste avant de publier — celui où l'on aimerait le moins
/// l'ignorer.
///
/// Un instrument branché sur un seul des endroits qu'il concerne laisse les
/// autres exactement là où ils étaient, **et donne en prime l'impression que la
/// question est réglée**. C'est la faute de #276 dans un autre costume : une
/// garde qui lit un des endroits où vit son sujet n'en est pas une.
///
/// D'où une garde sur la règle et non sur la liste : **tout job qui lance
/// `swift test` lance `report-skipped.sh`**. Écrite ainsi elle couvre le
/// workflow qu'on ajoutera demain, ce qu'une entrée par job ne ferait pas.

/// Les commentaires retirés d'abord, et ce n'est pas un détail : `ci.yml`
/// contient cinq fois « swift test » dont **quatre en commentaire**, et deux
/// d'entre elles sont dans `core-apple` — le job que cette garde doit accuser.
/// Une recherche sur le texte brut l'aurait déclaré couvert.
function withoutComments(body: string): string {
  return body
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");
}

/// Le texte de chaque job, séparé. **La séparation est le cœur de la garde** :
/// un lecteur qui rendrait le fichier entier comme un seul job le déclarerait
/// couvert dès qu'un seul de ses jobs porte le relevé — très exactement l'état
/// que cette garde existe pour refuser. Le test de prémisse plus bas l'exige.
function jobsOf(path: string): { name: string; body: string }[] {
  const jobs: { name: string; body: string[] }[] = [];
  let inJobs = false;
  for (const line of readFileSync(join(repoRoot, path), "utf8").split("\n")) {
    if (/^jobs:\s*$/.test(line)) {
      inJobs = true;
      continue;
    }
    if (!inJobs) continue;
    // Une clé revenue à la colonne zéro referme le bloc des jobs.
    if (/^\S/.test(line)) {
      inJobs = false;
      continue;
    }
    const head = /^ {2}([\w-]+):\s*$/.exec(line);
    if (head) {
      jobs.push({ name: head[1]!, body: [] });
      continue;
    }
    jobs.at(-1)?.body.push(line);
  }
  return jobs.map(({ name, body }) => ({ name, body: withoutComments(body.join("\n")) }));
}

/// Le répertoire, pas une liste écrite à la main. Une liste aurait encodé la
/// disposition d'aujourd'hui, et le workflow ajouté demain serait passé à
/// travers sans un mot.
const WORKFLOWS = readdirSync(join(repoRoot, ".github", "workflows"))
  .filter((name) => /\.ya?ml$/.test(name))
  .sort()
  .map((name) => `.github/workflows/${name}`);

function jobsRunningTheSuite(): { workflow: string; job: string; body: string }[] {
  return WORKFLOWS.flatMap((workflow) =>
    jobsOf(workflow)
      .filter((job) => job.body.includes("swift test"))
      .map((job) => ({ workflow, job: job.name, body: job.body })),
  );
}

describe("le relevé est branché partout où la suite tourne", () => {
  /// La garde. Un job qui lance la suite sans dire ce qu'elle a sauté est vert
  /// sans avoir répondu à la question.
  test("tout job qui lance « swift test » lance aussi report-skipped.sh", () => {
    const muets = jobsRunningTheSuite()
      .filter(({ body }) => !body.includes("report-skipped.sh"))
      .map(({ workflow, job }) => `${workflow} › ${job}`);
    expect(
      muets,
      "ces jobs lancent la suite et ne disent pas ce qu'elle a sauté : un vert " +
        "n'y distingue pas une suite qui a tourné d'une suite qui a été sautée",
    ).toEqual([]);
  });

  /// **Prémisse, et pas décoration.** Zéro job trouvé satisfait l'assertion
  /// ci-dessus sans rien avoir lu : c'est la façon dont cette garde peut mentir.
  test("le lecteur trouve bien des jobs qui lancent la suite", () => {
    expect(jobsRunningTheSuite().length).toBeGreaterThan(0);
  });

  /// **Et la séparation des jobs, tenue pour elle-même.** Si `jobsOf` rendait
  /// le fichier d'un bloc, `ci.yml` n'aurait qu'un job, il contiendrait à la
  /// fois la suite et le relevé, et la garde passerait au vert en ayant laissé
  /// `core-apple` muet. Deux faits l'interdisent : plusieurs jobs, et au moins
  /// un qui ne lance pas la suite.
  test("les jobs sont lus séparément, pas d'un bloc", () => {
    const jobs = jobsOf(".github/workflows/ci.yml");
    expect(jobs.length, "ci.yml devrait rendre plusieurs jobs").toBeGreaterThan(2);
    const running = jobs.filter((job) => job.body.includes("swift test"));
    expect(running.length, "aucun job de ci.yml ne lance la suite").toBeGreaterThan(0);
    expect(
      running.length,
      "tous les jobs de ci.yml lancent la suite : le lecteur ne les sépare pas",
    ).toBeLessThan(jobs.length);
  });

  /// **Les commentaires ne comptent pas comme du travail.** `core-apple` parle
  /// de `swift test` dans ses commentaires ; si `withoutComments` cessait de
  /// mordre, un job pourrait être accusé — ou disculpé — sur une phrase.
  test("une mention en commentaire ne vaut ni accusation ni acquittement", () => {
    expect(withoutComments("  # swift test\n  run: echo bonjour")).not.toContain("swift test");
    expect(withoutComments("  # report-skipped.sh\n  run: swift test")).not.toContain(
      "report-skipped.sh",
    );
    expect(readFileSync(join(repoRoot, ".github/workflows/ci.yml"), "utf8")).toContain(
      "# l'échec de `swift test`",
    );
  });
});

/// **Le relevé a menti sur le job Apple, et c'est ce PR qui l'y a branché.**
///
/// #279 a câblé `report-skipped.sh` sur « Cœur (Apple) ». Le job est passé vert
/// et le résumé a écrit « Aucun test sauté : les 1965 ont tourné », sur une
/// exécution dont XCTest disait lui-même « with 36 tests skipped ».
///
/// La cause, lue dans le journal brut plutôt que devinée : **il y a deux
/// XCTest, et ils n'écrivent pas la même ligne.**
///
/// | | ce que XCTest écrit |
/// |---|---|
/// | Linux (swift-corelibs) | `LinuxBootTests.testFoo : Test skipped - …` |
/// | Apple | `/chemin/F.swift:26: -[Mod.LinuxBootTests testFoo] : Test skipped - …` |
///
/// Le motif exigeait `NOM.NOM` immédiatement avant « : ». Un `]` n'en est pas
/// un, donc zéro correspondance, donc « aucun test sauté » — **un bouchon
/// complaisant**, pire que le silence qu'il remplaçait : il affirme.
///
/// La leçon vaut plus que la correction. La garde écrite plus haut vérifie que
/// le script est **appelé** partout ; elle ne vérifiait pas qu'il dise vrai
/// là où on l'appelle. Brancher un instrument dans un endroit neuf, c'est
/// aussi le confronter à ce que cet endroit produit vraiment.
///
/// D'où la seconde correction, qui est la méthode du dépôt posée dans l'outil :
/// **XCTest compte lui-même ses sautés**, et le relevé compare son propre
/// compte à celui-là. Tant qu'ils s'accordent, la liste est complète ; quand
/// ils divergent, le relevé le dit au lieu de faire semblant. C'est cette
/// comparaison-là, et pas une relecture, qui aurait attrapé le défaut le jour
/// même.

/// Extrait réel du job « Cœur (Apple) » 105947042286, run 35461863660.
const POMME = `/Users/runner/work/wisq/wisq/Tests/WisqVMTests/KernelImageKindTests.swift:26: -[WisqVMTests.KernelImageKindTests testTheRealKernelIsRecognisedAsOne] : Test skipped - image Linux absente : définir WISQ_LINUX_IMAGE pour ce test
Test Case '-[WisqVMTests.KernelImageKindTests testTheRealKernelIsRecognisedAsOne]' skipped (0.001 seconds).
/Users/runner/work/wisq/wisq/Tests/WisqAgentTests/PairingTests.swift:41: -[WisqAgentTests.PairingTests testPairingLinksNeverOfferLoopback] : Test skipped - wisq-agent absent : lancez \`cargo build --release\` d'abord
Test Case '-[WisqAgentTests.PairingTests testPairingLinksNeverOfferLoopback]' skipped (0.002 seconds).
\t Executed 1965 tests, with 2 tests skipped and 0 failures (0 unexpected) in 494.453 (494.805) seconds
`;

describe("le relevé lit les deux XCTest", () => {
  /// La régression elle-même : cette entrée rendait « Aucun test sauté ».
  test("nomme les tests sautés dans la forme Apple", () => {
    const { summary } = run(POMME);
    expect(summary).not.toContain("Aucun test sauté");
    expect(summary).toContain("**2 sauté(s) sur 1965.**");
    expect(summary).toContain("testTheRealKernelIsRecognisedAsOne");
    expect(summary).toContain("testPairingLinksNeverOfferLoopback");
    expect(summary).toContain("image Linux absente");
    expect(summary).toContain("wisq-agent absent");
  });

  /// Et il ne crie pas quand les deux comptes s'accordent : une note de
  /// désaccord qui s'affiche toujours n'est plus une note.
  test("ne signale aucun désaccord quand les comptes s'accordent", () => {
    expect(run(POMME).summary).not.toContain("pas d'accord");
  });

  /// **La garde qui aurait attrapé le défaut du jour.** XCTest annonce des
  /// sautés, le lecteur n'en reconnaît aucun : le relevé doit le dire, pas
  /// écrire « aucun test sauté ».
  test("dit qu'il est aveugle quand XCTest compte plus que lui", () => {
    const inconnu = `Test Case 'Quelque.chose' was SKIPPED for a reason we cannot parse
\t Executed 1965 tests, with 36 tests skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
`;
    const { summary } = run(inconnu);
    expect(summary).not.toContain("Aucun test sauté");
    expect(summary).toContain("**36 sauté(s) sur 1965, et le relevé n'a pu en nommer aucun.**");
    expect(summary).toContain("pas d'accord");
    expect(summary).toContain("**36**");
    expect(summary).toContain("**0**");
  });

  /// **Et la troisième forme, que la note de désaccord a trouvée elle-même.**
  ///
  /// Sur la première exécution de `verify.sh` après la correction ci-dessus,
  /// XCTest annonçait **26** sautés et le relevé en nommait **25**. La note a
  /// parlé, et le manquant était `JPEGTests.testQualityIsClampedIntoTheSpecRange` :
  ///
  ///     : Test skipped: required false value but got true - pas de décodeur JPEG ici
  ///
  /// `XCTSkip("raison")` écrit « skipped - raison » ; `XCTSkipIf(cond, "raison")`
  /// écrit « skipped: <le texte de l'assertion> - raison ». Deux-points, pas
  /// tiret. Ce saut-là n'était compté **ni avant ni après** #278 — c'est la
  /// comparaison des deux comptes qui l'a sorti, pas une relecture, et elle l'a
  /// fait à sa toute première exécution réelle.
  test("nomme aussi un saut venu de XCTSkipIf", () => {
    const log = `/w/Tests/WisqRemoteTests/JPEGTests.swift:34: JPEGTests.testQualityIsClampedIntoTheSpecRange : Test skipped: required false value but got true - pas de décodeur JPEG ici
\t Executed 2063 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
`;
    const { summary } = run(log);
    expect(summary).toContain("**1 sauté(s) sur 2063.**");
    expect(summary).toContain("testQualityIsClampedIntoTheSpecRange");
    expect(summary).toContain("pas de décodeur JPEG ici");
    expect(summary).not.toContain("pas d'accord");
  });

  /// Et même aveugle, il ne casse pas le job qu'il observe.
  test("sort avec zéro même quand il ne comprend pas le journal", () => {
    expect(run(`\t Executed 10 tests, with 3 tests skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds
`).code).toBe(0);
  });
});
