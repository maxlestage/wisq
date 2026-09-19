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
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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
