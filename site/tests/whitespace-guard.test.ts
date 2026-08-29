/// The formatting floor, run against files that break it.
///
/// `scripts/check-whitespace.sh` is the third and last of this repository's
/// guard scripts, and it had the same hole as the other two: `verify.sh` runs
/// it before every push, always against a tree where nothing is wrong, so none
/// of its five rules had ever reported anything.
///
/// It is the mildest of the three and that is worth saying plainly. CI does not
/// run it — CI runs `swiftlint --strict`, which covers the same rules — so a
/// broken version does not let a defect through, it lets a pull request go red
/// ten minutes later. That round trip is the entire reason the script exists,
/// on a Linux box where SwiftLint's Homebrew formula is not available. A lost
/// trip, not a lost defect.
///
/// **What the measurement found is not mild.** The scope was three pathspecs —
/// `Sources/**/*.swift`, `Tests/**/*.swift`, `App/**/*.swift` — and the third
/// matched **nothing at all**: `**/` requires at least one directory level, and
/// `App/` holds exactly one Swift file, at its top. So `App/WisqApp.swift`, the
/// application's entry point, was the one file this floor never looked at,
/// while `.swiftlint.yml` lists `App` and CI checks it every time. 235 files
/// covered out of 236, invisibly, because that file happens to be clean.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

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
  ])("%s is refused", (_name, contents, rule) => {
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": contents }));
    expect(code, `la garde a accepté : ${rule}\n${output}`).not.toBe(0);
    expect(output).toContain(rule);
    expect(output).toContain("Sources/WisqCore/A.swift");
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
  test("a brace at the end of a line is not a brace on its own line", () => {
    const { code, output } = run(tree({ "Sources/WisqCore/A.swift": CLEAN }));
    expect(code, output).toBe(0);
  });

  /// And this repository, through the default root, with no argument — the
  /// only case that holds the path resolution, since every other test passes
  /// a root explicitly.
  test("this repository, with no root given, is clean", () => {
    const result = Bun.spawnSync({ cmd: ["bash", guard] });
    const output =
      new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr);
    expect(result.exitCode, output).toBe(0);
  });
});
