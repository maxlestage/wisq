/// The formatting floor, run against files that break it.
///
/// `scripts/check-whitespace.sh` is the seventh and last of this repository's
/// guard scripts, and like the other six it answers a hole native to all of
/// them. `verify.sh` runs
/// it before every push, always against a tree where nothing is wrong, so none
/// of its rules had ever reported anything — five at the time, eight now.
///
/// It is the mildest of them, and that is worth saying plainly: its rules are
/// SwiftLint's own, and CI runs `swiftlint --strict` over the same scope, so a
/// broken version here does not let a defect through — it costs a round trip.
/// That trip is the entire reason the script exists, on a Linux box where
/// SwiftLint's Homebrew formula is not available. A lost trip, not a lost
/// defect.
///
/// **What is not true is that CI never runs it.** The last test in this file
/// puts the guard in front of this repository and requires exit 0, and that
/// test runs in the `Build site` job — so a stray blank line turns CI red
/// through `bun test` as well, not only through SwiftLint.
///
/// Three of the seven guard scripts are named in no workflow, and a site test
/// runs each of those three against the real tree — `guard-scripts.test.ts`
/// does it itself, in the `Build site` job, rather than asserting that someone
/// else does.
///
/// **What the measurement found is not mild.** The scope was three pathspecs —
/// `Sources/**/*.swift`, `Tests/**/*.swift`, `App/**/*.swift` — and the third
/// matched **nothing at all**: `**/` requires at least one directory level, and
/// `App/` holds exactly one Swift file, at its top. So `App/WisqApp.swift`, the
/// application's entry point, was the one file this floor never looked at,
/// while `.swiftlint.yml` lists `App` and CI checks it every time. 235 files
/// covered out of 236, invisibly, because that file happens to be clean.

import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

/// **Vingt secondes par contrôle, et non les cinq par défaut.**
///
/// Chaque test de ce fichier lance des sous-processus — un `git init`, la
/// garde en bash, un parcours de fichiers — et le délai par défaut de Bun est
/// de cinq secondes. Un contrôle qui échoue parce qu'il est lent n'apprend
/// rien à personne : il dit « rouge » sur un comportement correct, et le
/// contributeur va chercher le défaut dans ce qu'il vient d'écrire.
///
/// Ce n'est pas une précaution théorique. Une suite complète a rendu quatre
/// rouges en soixante-trois secondes là où elle en met neuf, puis un seul en
/// trente-huit, jamais les mêmes : à chaque fois un test de garde arrêté à
/// 5 005 ou 5 720 millisecondes, sur une machine occupée à construire autre
/// chose à côté. Un budget qui dépend de la charge est un chronomètre, pas
/// une garde.
setDefaultTimeout(20_000);

const repoRoot = join(import.meta.dir, "..", "..");
const guard = join(repoRoot, "scripts", "check-whitespace.sh");

/// A clean Swift file: one trailing newline, no trailing spaces, no lone
/// brace, no double blank line.
const CLEAN = "import Foundation\n\nstruct A {\n    let b = 1\n}\n";

/// A throwaway git work tree, because the guard lists its files with
/// `git ls-files` — untracked ones included, which is the point: the file
/// about to be pushed is the one not yet committed.
function tree(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-whitespace-"));
  Bun.spawnSync({ cmd: ["git", "init", "--quiet"], cwd: root });
  for (const [path, contents] of Object.entries(files)) {
    const file = join(root, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, contents);
  }
  return root;
}

function run(root: string): { code: number; output: string } {
  const result = Bun.spawnSync({ cmd: ["bash", guard, root] });
  return {
    code: result.exitCode,
    output: new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr),
  };
}

describe("the formatting floor refuses each thing it names", () => {
  /// One case per rule, and the assertion names the rule as well as the file:
  /// a script that failed for another reason would exit non-zero too.
  test.each([
    ["pas de saut de ligne final", "import Foundation\n\nstruct A {\n    let b = 1\n}", "trailing_newline"],
    ["plusieurs sauts de ligne finaux", `${CLEAN}\n`, "trailing_newline"],
    ["espaces en fin de ligne", "import Foundation   \n\nstruct A {\n    let b = 1\n}\n", "trailing_whitespace"],
    [
      "accolade ouvrante seule",
      "import Foundation\n\nfunc a()\n{\n    return\n}\n",
      "opening_brace",
    ],
    [
      "deux lignes vides",
      "import Foundation\n\n\nstruct A {\n    let b = 1\n}\n",
      "vertical_whitespace",
    ],
    [
      "une garde de plateforme refermée trop tôt",
      "#if canImport(Glibc)\nimport Foundation\nlet a = 1\n#endif\n\nlet b = 2\n",
      "garde de plateforme",
    ],
  ])("%s is refused", (_name, contents, rule) => {
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `la garde a accepté : ${rule}\n${output}`).not.toBe(0);
    expect(output).toContain(rule);
    expect(output).toContain("Sources/WisqCore/A.swift");
  });

  /// **A `#if` around an import is not a file-wide guard**, and the rule must
  /// not touch it. Six files in this repository have that shape — a platform
  /// module imported conditionally in the middle of an otherwise ordinary file
  /// — and a rule that flagged them would be turned off within the day.
  test("an import guard in the middle of a file is left alone", () => {
    const contents =
      "import Foundation\n\n#if canImport(CryptoKit)\nimport CryptoKit\n#endif\n\nlet c = 3\n";
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `une garde d'import légitime a été refusée :\n${output}`).toBe(0);
  });

  /// And a file-wide guard that does reach the end passes.
  test("a platform guard that covers the whole file is accepted", () => {
    const contents = "// un mot d'abord\n#if canImport(Glibc)\nimport Foundation\n\nlet a = 1\n#endif\n";
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `une garde correcte a été refusée :\n${output}`).toBe(0);
  });

  /// **Un `await` dans l'autoclosure d'une assertion**, et c'est le texte exact
  /// qui a rendu « App iOS » rouge sur la PR de #313.
  ///
  /// `XCTAssertEqual` prend ses arguments en autoclosure, qui accepte `try`
  /// mais pas `await`. Rien sur cette machine ne compile
  /// `Tests/WisqHostedTests` — cette cible n'appartient qu'au projet Xcode, pas
  /// au paquet — donc seule la CI Apple le voyait, quinze minutes plus tard.
  ///
  /// **Et la leçon était déjà écrite en commentaire** dans ce fichier de tests,
  /// ce qui ne l'a pas empêchée de coûter l'aller-retour. Un commentaire n'est
  /// pas une garde.
  test("un await dans une assertion XCTest est refusé", () => {
    const contents = [
      "import XCTest",
      "",
      "final class A: XCTestCase {",
      "    func testA() async throws {",
      "        XCTAssertEqual(",
      "            try await desktop.read(64, at: at), archive,",
      "            \"l'archive est dans la RAM de l'invité\"",
      "        )",
      "    }",
      "}",
      "",
    ].join("\n");
    const { code, output } = run(tree({ "Tests/WisqHostedTests/A.swift": contents }));
    expect(code, `la garde a accepté un await en autoclosure :\n${output}`).not.toBe(0);
    expect(output).toContain("`await` dans l'autoclosure");
    expect(output).toContain("Tests/WisqHostedTests/A.swift");
  });

  /// **Et les `await` qui ne sont pas dedans passent** — c'est ce qui donne son
  /// sens au refus ci-dessus. Trois formes légitimes, toutes présentes dans ce
  /// dépôt : l'appel hissé dans un `let`, une assertion sur plusieurs lignes
  /// suivie d'un `await`, et une assertion dans le `catch` d'un `do` qui en
  /// contient un.
  ///
  /// Le message porte aussi une parenthèse ouvrante : les chaînes littérales
  /// sont retirées avant de compter, sans quoi elle déséquilibrerait la portée
  /// et le contrôle emporterait les vingt lignes suivantes.
  test("les await hors des assertions sont laissés tranquilles", () => {
    const contents = [
      "import XCTest",
      "",
      "final class A: XCTestCase {",
      "    func testA() async throws {",
      "        let relu = try await desktop.read(64, at: at)",
      "        XCTAssertEqual(",
      "            relu,",
      "            archive,",
      "            \"relu (et une parenthèse dans le message\"",
      "        )",
      "        let suite = try await desktop.read(64, at: at)",
      "        XCTAssertTrue(suite.isEmpty)",
      "        do {",
      "            _ = try await desktop.read(1, at: at)",
      "        } catch let failure as LocalDesktop.Failure {",
      "            XCTAssertEqual(failure, .noFrameWasDeclared)",
      "        }",
      "    }",
      "}",
      "",
    ].join("\n");
    const { code, output } = run(tree({ "Tests/WisqHostedTests/A.swift": contents }));
    expect(code, `des await légitimes ont été refusés :\n${output}`).toBe(0);
  });

  /// **Du code après une boucle `while true` qui ne rompt jamais**, et c'est la
  /// forme exacte qui a rendu le dépôt de la page zéro inatteignable pendant
  /// trois tranches — #310 l'a écrit, #311 et #312 l'ont cru posé.
  ///
  /// **Le compilateur Swift est muet là-dessus**, mesuré et non supposé :
  /// `swiftc -typecheck` sur la forme minimale ne rend rien, ni en typage ni
  /// en compilation complète. Un `-warnings-as-errors` ne l'aurait pas
  /// attrapé. Cette règle est la seule chose qui le voit.
  test("du code après un while true sans break est refusé", () => {
    const contents = [
      "import Foundation",
      "",
      "func attend(_ vrai: Bool) throws {",
      "    while true {",
      "        if vrai { return }",
      "        if !vrai { throw CancellationError() }",
      "    }",
      "    print(\"jamais atteint\")",
      "}",
      "",
    ].join("\n");
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `la garde a accepté du code inatteignable :\n${output}`).not.toBe(0);
    expect(output).toContain("code inatteignable");
    expect(output).toContain("Sources/WisqCore/A.swift");
  });

  /// **Et les deux formes correctes passent** — c'est ce qui donne son sens au
  /// refus ci-dessus, et sans quoi la règle pourrait refuser toute boucle
  /// infinie. Une boucle qui rompt laisse ce qui suit atteignable ; une boucle
  /// que rien ne suit est une attente légitime.
  test("un while true qui rompt, ou que rien ne suit, est laissé tranquille", () => {
    const contents = [
      "import Foundation",
      "",
      "func attend(_ vrai: Bool) throws -> String {",
      "    var verdict = \"\"",
      "    while true {",
      "        if vrai { break }",
      "        if !vrai { throw CancellationError() }",
      "    }",
      "    verdict = \"atteint\"",
      "    return verdict",
      "}",
      "",
      "func rien(_ vrai: Bool) -> Never {",
      "    while true {",
      "        _ = vrai",
      "    }",
      "}",
      "",
    ].join("\n");
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `des boucles légitimes ont été refusées :\n${output}`).toBe(0);
  });

  /// The file the old scope missed entirely. `App/` has no subdirectory, so
  /// `App/**/*.swift` matched nothing and this file was never read — while
  /// `.swiftlint.yml` lists `App` and CI checks it on every commit.
  test("a file directly inside App, which the old scope could not match, is refused", () => {
    const { code, output } = run(
      tree({ "App/WisqApp.swift": "import SwiftUI   \n\nstruct W {\n    let x = 1\n}\n" }),
    );
    expect(code, `App/ n'est toujours pas dans la portée :\n${output}`).not.toBe(0);
    expect(output).toContain("App/WisqApp.swift");
  });

  /// And the depth the old scope did reach, kept: a fix that traded one edge
  /// for the other would pass the test above and fail here.
  test("a file several directories deep is still refused", () => {
    const { code, output } = run(
      tree({ "Sources/WisqRemote/SPICE/Deep/A.swift": "import Foundation   \n" }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("Sources/WisqRemote/SPICE/Deep/A.swift");
  });

  /// Every rule at once, on several files, counted. The script prints a total
  /// and nothing was checking that it counted rather than stopped at the first.
  test("several files each report, and the total is the number of files", () => {
    const { code, output } = run(
      tree({
        "Sources/A.swift": "import Foundation   \n",
        "Tests/B.swift": "import XCTest\n\n\nfinal class B {}\n",
        "App/WisqApp.swift": "import SwiftUI\n\nstruct W {}",
      }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("3 fichier(s) à corriger");
  });
});

describe("the formatting floor accepts what it must not refuse", () => {
  test("a clean tree passes", () => {
    const { code, output } = run(
      tree({
        "Sources/WisqCore/A.swift": CLEAN,
        "Tests/WisqCoreTests/ATests.swift": CLEAN,
        "App/WisqApp.swift": CLEAN,
      }),
    );
    expect(code, output).toBe(0);
    expect(output).toContain("rien à signaler");
  });

  /// `Package.swift` sits outside `.swiftlint.yml`'s `included`, so SwiftLint
  /// never sees it. Reporting it here would be a violation CI does not have —
  /// exactly the false alarm that makes a local floor untrustworthy.
  test("Package.swift is outside the scope even when it breaks every rule", () => {
    const { code, output } = run(
      tree({ "Package.swift": "// swift-tools-version:6.0   \n\n\nlet x = 1" }),
    );
    expect(code, output).toBe(0);
  });

  /// A file that is not Swift, inside the scope. The rules are SwiftLint's,
  /// and SwiftLint reads Swift.
  test("a non-Swift file inside the scope is left alone", () => {
    const { code, output } = run(
      tree({ "Sources/WisqCore/notes.md": "du texte   \n\n\net encore" }),
    );
    expect(code, output).toBe(0);
  });

  /// An empty file has no final newline, which is the first rule's exact
  /// wording — and reporting it would be wrong: there is nothing to end.
  test("an empty file is not a missing newline", () => {
    const { code, output } = run(tree({ "Sources/WisqCore/Empty.swift": "" }));
    expect(code, output).toBe(0);
  });

  /// A brace that ends a line, which is every brace in the codebase. A rule
  /// written as "contains `{`" rather than "is only `{`" would refuse the
  /// whole repository.
  /// **Un séparateur de ligne Unicode en fin de ligne n'est pas un espace en
  /// fin de ligne**, et ce cas tient une décision plutôt qu'un hasard.
  ///
  /// La version d'avant posait la question à `grep`, sous la forme
  /// `[[:space:]]`, et `grep` répond selon la locale : sur ce conteneur, un
  /// U+2028 (`e2 80 a8`) collé en fin de ligne était compté comme un espace,
  /// alors qu'un espace insécable U+00A0 ne l'était pas. Le même fichier
  /// pouvait donc être refusé sur une machine et accepté sur une autre, pour
  /// une variable d'environnement.
  ///
  /// La règle est maintenant écrite dans la garde — espace, tabulation, retour
  /// chariot, tabulation verticale, saut de page — et c'est exactement ce que
  /// `trailing_whitespace` regarde chez SwiftLint, dont cette garde est le
  /// plancher. Ce test est là pour que le rétrécissement soit tenu, et non
  /// découvert un jour comme une régression.
  test.each([
    ["un séparateur de ligne U+2028", "\u2028"],
    ["un espace insécable U+00A0", "\u00a0"],
  ])("%s en fin de ligne n'est pas un espace en fin de ligne", (_name, character) => {
    const contents = `import Foundation\n\nlet a = 1${character}\n`;
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `un caractère Unicode a été pris pour un blanc :\n${output}`).toBe(0);
  });

  /// Et le témoin, sans lequel le cas d'au-dessus passerait aussi avec une
  /// garde qui ne regarde plus rien : le blanc ASCII, lui, est toujours refusé
  /// au même endroit.
  test("mais une tabulation en fin de ligne l'est toujours", () => {
    const { code, output } = run(tree({
      "Sources/WisqCore/A.swift": "import Foundation\n\nlet a = 1\t\n",
    }));
    expect(code).not.toBe(0);
    expect(output).toContain("trailing_whitespace");
  });

  test("a brace at the end of a line is not a brace on its own line", () => {
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": CLEAN }));
    expect(code, output).toBe(0);
  });

  /// And this repository, through the default root, with no argument — the
  /// only case that holds the path resolution, since every other test passes
  /// a root explicitly.
  ///
  /// Ce cas-ci lance la garde sur tous les fichiers Swift du dépôt. Il tenait
  /// en trois secondes et demie, une règle de plus l'a porté à quatre et quart,
  /// et il est tombé sur son propre délai : c'est lui qui a fait écrire le
  /// délai large en tête de fichier. La cause en a été retirée depuis — la
  /// garde ne lance plus un cortège de sous-processus par fichier — et le test
  /// d'en dessous tient ce qui a remplacé le chronomètre.
  /// **Ce que coûte la garde ne doit pas dépendre du nombre de fichiers.**
  ///
  /// La version d'avant ouvrait onze sous-processus par fichier — `tail`, `od`,
  /// `tr`, quatre `grep`, deux `awk` — soit plus de quatre mille cinq cents
  /// pour un passage sur le dépôt, et 4,9 s à chaud contre 25,6 s à froid. Le
  /// texte, lui, tient en deux mégaoctets : le coût était en `fork`, pas en
  /// lecture.
  ///
  /// **Et un délai n'est pas une garde.** Le fichier avait dû monter le sien à
  /// vingt secondes parce que la garde s'en approchait sous charge ; assener
  /// « moins de N secondes » à la place aurait remplacé un chronomètre par un
  /// autre, rouge sur une machine occupée et vert sur une machine oisive.
  ///
  /// Ce qui se mesure ici n'est pas une durée mais un **compte**, et il ne
  /// dépend d'aucune charge : le même arbre à deux fichiers et à soixante doit
  /// lancer **exactement** le même nombre de commandes externes. C'est deux
  /// nombres qui doivent s'accorder — la seule forme de mesure qui ait jamais
  /// rien trouvé dans ce dépôt.
  test("le nombre de processus lancés ne dépend pas du nombre de fichiers", () => {
    /// Un leurre par commande que la garde pourrait appeler : il note son nom
    /// puis passe la main au vrai binaire, dont le chemin absolu est résolu
    /// **avant** que le leurre existe — sans quoi il s'appellerait lui-même.
    function counting(): { path: string; count: (root: string) => number } {
      const names = ["git", "perl", "grep", "tail", "od", "tr", "awk", "sed", "cut", "head", "wc", "cat"];
      const bin = mkdtempSync(join(tmpdir(), "wisq-leurres-"));
      const ledger = join(bin, "journal");
      for (const name of names) {
        const real = Bun.which(name);
        if (!real) continue;
        writeFileSync(
          join(bin, name),
          `#!/bin/sh\necho ${name} >> "${ledger}"\nexec ${real} "$@"\n`,
          { mode: 0o755 },
        );
      }
      return {
        path: bin,
        count: (root: string) => {
          writeFileSync(ledger, "");
          Bun.spawnSync({
            cmd: ["bash", guard, root],
            env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
          });
          return readFileSync(ledger, "utf8").split("\n").filter(Boolean).length;
        },
      };
    }

    const forest = (howMany: number) =>
      tree(Object.fromEntries(
        Array.from({ length: howMany }, (_, index) => [`Sources/WisqCore/F${index}.swift`, CLEAN]),
      ));

    const leurres = counting();
    const few = leurres.count(forest(2));
    const many = leurres.count(forest(60));

    /// Le témoin : si les leurres n'attrapaient rien, les deux comptes seraient
    /// nuls et l'égalité serait vraie pour la mauvaise raison.
    expect(few).toBeGreaterThan(0);
    expect(many, `2 fichiers → ${few} commandes, 60 → ${many}`).toBe(few);
  });

  /// **Le plancher ne savait pas combien de refus il porte.**
  ///
  /// Deux phrases, une par fichier, sur la même chose, et écrites dans le
  /// **même** commit (#313) : l'en-tête de la garde annonce ses règles en
  /// lettres, l'en-tête de ce fichier aussi, et les deux mots ne disaient pas
  /// le même nombre — huit là-bas, sept ici. Le compte, lui, se lit : la garde
  /// porte huit `report(`, un par refus qu'elle sait émettre, et c'est bien ce
  /// sens que les deux phrases donnent au mot, puisque toutes deux parlent de
  /// règles qui n'avaient jamais rien **signalé**.
  ///
  /// Et la même phrase de la garde désignait la mauvaise règle par son rang :
  /// le refus de ce rang est celui de l'`await` dans une autoclosure, alors que
  /// la phrase nomme celui du saut de ligne final, qui est le **premier**. Un
  /// lecteur qui suit l'ordinal ouvre une autre règle que celle annoncée.
  ///
  /// **Il y avait une troisième copie, et c'est elle qui explique les deux
  /// autres.** `docs/ROADMAP.md` porte la même phrase avec « six » et « la
  /// sixième » : à la tranche qui a écrit ce relevé, le script portait bien six
  /// refus et celui du saut de ligne final était le dernier d'entre eux —
  /// mesuré, `git show` le donne. #313 a porté le compte à huit et remonté
  /// cette règle en tête, puis a recopié la phrase en corrigeant le nombre et
  /// pas le rang. Le relevé n'est donc pas lu ici, et l'exclusion porte : la
  /// soumettre à ce contrôle interdirait au dépôt de dire ce qui était vrai,
  /// comme pour `docs/JOURNAL.md` en #317.
  ///
  /// Un nombre écrit en lettres dans un commentaire n'a aucune garde : c'est la
  /// leçon de #317, et elle vaut pour les commentaires d'un script autant que
  /// pour les pages du site. Celle-ci la tient en trois temps — compter les
  /// refus, exiger que chaque phrase annonce ce compte, exiger que l'ordinal
  /// tombe sur la règle qu'il nomme.
  test("le plancher annonce le nombre de refus qu'il porte, et son rang désigne la bonne règle", () => {
    const script = readFileSync(guard, "utf8");
    const self = readFileSync(join(import.meta.dir, "whitespace-guard.test.ts"), "utf8");

    /// Un `report(` par refus : c'est ce que la garde sait dire, et le reste du
    /// fichier n'en contient aucun autre — la fonction est définie une fois,
    /// sous le nom `sub report`, que ce motif ne voit pas.
    const refusals = Array.from(script.matchAll(/\breport\("([^"]*)/g), (m) => m[1]);
    /// Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne chose.
    expect(refusals.length, "aucun refus trouvé dans la garde").toBeGreaterThan(5);

    const NOMBRES: Record<string, number> = {
      cinq: 5,
      six: 6,
      sept: 7,
      huit: 8,
      neuf: 9,
      dix: 10,
      onze: 11,
      five: 5,
      seven: 7,
      eight: 8,
      nine: 9,
      ten: 10,
      eleven: 11,
    };

    /// Les trois phrases qui annoncent le compte, chacune dans son fichier. La
    /// forme est tenue autant que le nombre : si l'une est réécrite, le
    /// contrôle le dit au lieu de passer sur une phrase qu'il ne lit plus.
    const annonces: [string, string, RegExp][] = [
      ["scripts/check-whitespace.sh", script, /none of the (\p{L}+) rules below/u],
      ["scripts/check-whitespace.sh", script, /Sept des (\p{L}+) règles sont lignes à lignes/u],
      [
        "site/tests/whitespace-guard.test.ts",
        self,
        /had ever reported anything — five at the time, (\p{L}+) now\./u,
      ],
    ];
    for (const [ou, texte, motif] of annonces) {
      const trouve = texte.match(motif);
      expect(trouve, `${ou} : la phrase qui annonce le compte a changé de forme — ${motif}`)
        .not.toBeNull();
      const dit = NOMBRES[trouve![1].toLowerCase()];
      expect(dit, `${ou} : « ${trouve![1]} » n'est pas un nombre que je sais lire`)
        .not.toBeUndefined();
      expect(dit, `${ou} annonce « ${trouve![1]} » règles, la garde porte ${refusals.length} refus`)
        .toBe(refusals.length);
    }

    /// L'ordinal ne compte rien : il **désigne**. Donc on le suit, et on lit le
    /// refus qui tombe à ce rang.
    const ORDINAUX: Record<string, number> = {
      première: 1,
      deuxième: 2,
      troisième: 3,
      quatrième: 4,
      cinquième: 5,
      sixième: 6,
      septième: 7,
      huitième: 8,
    };
    const designe = script.match(/La (\p{L}+) — exactement un saut de ligne à la fin/u);
    expect(designe, "la phrase qui désigne la règle du saut de ligne final a changé de forme")
      .not.toBeNull();
    const rang = ORDINAUX[designe![1].toLowerCase()];
    expect(rang, `« ${designe![1]} » n'est pas un ordinal que je sais lire`).not.toBeUndefined();
    expect(rang, `l'ordinal « ${designe![1]} » sort des ${refusals.length} refus`)
      .toBeLessThanOrEqual(refusals.length);
    /// **Le nom de la règle SwiftLint ne suffit pas à désigner un refus.**
    /// Deux refus portent `trailing_newline` — le saut de ligne manquant et
    /// les sauts de ligne en trop —, et un seul des deux demande de voir le
    /// dernier octet, qui est ce dont la phrase parle. Exiger le nom laissait
    /// donc passer l'autre rang : un contrôle qui ne voit qu'une partie de ce
    /// qu'il contrôle ne garde pas le reste. Mesuré, pas supposé : le sabotage
    /// qui déplaçait l'ordinal d'un cran a survécu à la première forme.
    const dernierOctet = refusals.findIndex((m) => m.includes("pas de saut de ligne final"));
    expect(dernierOctet, "aucun refus ne parle du saut de ligne final").toBeGreaterThanOrEqual(0);
    expect(
      rang - 1,
      `l'ordinal « ${designe![1]} » désigne le refus n°${rang} (${refusals[rang - 1]}), `
        + `et celui qui demande le dernier octet est le n°${dernierOctet + 1}`,
    ).toBe(dernierOctet);
  });

  test("this repository, with no root given, is clean", () => {
    const result = Bun.spawnSync({ cmd: ["bash", guard] });
    const output =
      new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr);
    expect(result.exitCode, output).toBe(0);
  });
});
