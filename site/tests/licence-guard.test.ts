/// The guard that forbids claiming a licence, run against trees that claim one.
///
/// `scripts/check-licence-claims.sh` enforces the one rule this project states
/// most plainly: no licence has been chosen, so nothing shipped may announce
/// one. CI runs it on every commit and `verify.sh` runs it before every push —
/// and both run it against **this** repository, where nothing is wrong. In
/// three months it had never refused anything.
///
/// **Measured.** The whole script was replaced by `exit 0` and the entire suite
/// run against it: green. Nothing anywhere held it. A guard that has never
/// refused is not a guard that works, it is a guard nobody has checked — the
/// same shape as a probe that cannot fail.
///
/// So the script now takes a root, and this file gives it trees that do claim a
/// licence, one per place it looks. Each case was verified by removing the
/// matching block from the script and watching exactly its own test go red.
///
/// The controls are the other half, and they are the harder half. Naming
/// Apache-2.0 in `README.md`, in `NOTICE` and in the roadmap is **correct** —
/// it is a fact about UTM, FreeRDP and QEMU, other people's projects, which
/// really are under it. A guard that refused those would be wrong in a way that
/// is invisible from a green build, so a tree full of them has to pass.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const guard = join(import.meta.dir, "..", "..", "scripts", "check-licence-claims.sh");

/// A tree with every file the guard looks at, all of them innocent.
///
/// Built in full rather than left empty on purpose: the guard skips a file it
/// cannot find, so an empty directory passes for the wrong reason and would
/// make the control cases prove nothing.
const innocent: Record<string, string> = {
  "App/Info.plist": [
    "<plist><dict>",
    "<key>NSHumanReadableCopyright</key>",
    "<string>Copyright 2026 Maxime Nathan Lestage. All rights reserved.</string>",
    "</dict></plist>",
  ].join("\n"),
  "Formula/wisq-agent.rb": [
    "class WisqAgent < Formula",
    '  desc "Daemon that lets wisq drive virtual machines on this host"',
    '  homepage "https://wisq.app"',
    "end",
  ].join("\n"),
  "Package.swift": "// swift-tools-version:6.0\nimport PackageDescription\n",
  "site/src/index.html": "<!doctype html><title>wisq</title>\n",
  "Cargo.toml": '[workspace]\nmembers = ["crates/wisq-agent"]\n',
  "crates/wisq-agent/Cargo.toml": '[package]\nname = "wisq-agent"\nversion = "0.1.0"\n',
  "package.json": '{\n  "name": "wisq-site-host",\n  "private": true\n}\n',
  "site/package.json": '{\n  "name": "wisq-site",\n  "private": true\n}\n',
  // The three places where naming somebody else's licence is a fact rather
  // than a claim. They carry every string the guard looks for.
  "README.md": [
    "wisq borrows nothing from UTM, which is Apache-2.0.",
    "FreeRDP is Apache 2.0 and QEMU is GPL-2. See https://www.apache.org/licenses/LICENSE-2.0.",
    "Some of the vendored fixtures come from projects under the MIT License.",
  ].join("\n"),
  NOTICE: "UTM — Apache-2.0\nFreeRDP — Apache-2.0\nQEMU — GPL-2\n",
  "docs/ROADMAP.md": "Le pilote Apache-2.0 d'UTM est la référence, pas la nôtre.\n",
};

function tree(overrides: Record<string, string> = {}): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-licence-"));
  for (const [path, contents] of Object.entries({ ...innocent, ...overrides })) {
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

describe("the licence guard refuses what it exists to refuse", () => {
  /// One case per place the guard looks. The assertion is on the *named* file
  /// as well as the exit code: a script that failed for some other reason —
  /// an unset variable, a bad path — would exit non-zero too, and would prove
  /// nothing about the thing being guarded.
  test.each([
    ["App/Info.plist", "App/Info.plist", innocent["App/Info.plist"]!.replace(
      "All rights reserved.", "Licensed under the Apache-2.0 licence.")],
    ["Formula/wisq-agent.rb", "Formula/wisq-agent.rb",
      `${innocent["Formula/wisq-agent.rb"]!}\n  license "MIT License"\n`],
    ["Package.swift", "Package.swift",
      "// See https://www.apache.org/licenses/LICENSE-2.0\nimport PackageDescription\n"],
    ["site/src/index.html", "site/src/index.html",
      '<!doctype html><footer>wisq — MIT License</footer>\n'],
    ["crates/wisq-agent/Cargo.toml", "crates/wisq-agent/Cargo.toml",
      `${innocent["crates/wisq-agent/Cargo.toml"]!}license = "MIT"\n`],
    ["package.json", "package.json",
      '{\n  "name": "wisq-site-host",\n  "license": "MIT"\n}\n'],
    ["site/package.json", "site/package.json",
      '{\n  "name": "wisq-site",\n  "license": "Apache-2.0"\n}\n'],
  ])("a licence in %s is refused", (path, named, contents) => {
    const { code, output } = run(tree({ [path]: contents }));
    expect(code, `la garde a accepté une licence dans ${path} :\n${output}`).not.toBe(0);
    expect(output).toContain(named);
  });

  /// A licence file grants rights by existing, so its mere presence is the
  /// claim. All four names the guard knows, because three of them were only
  /// ever a list nobody had exercised.
  test.each([["LICENSE"], ["LICENSE.md"], ["LICENSE.txt"], ["COPYING"]])(
    "a %s file at the root is refused",
    (name) => {
      const { code, output } = run(tree({ [name]: "Apache License, Version 2.0\n" }));
      expect(code, `la garde a accepté ${name} :\n${output}`).not.toBe(0);
      expect(output).toContain(name);
    },
  );

  /// A Cargo manifest anywhere in the tree, not only the ones that exist
  /// today: the guard walks the tree with `find`, and a crate added later must
  /// be covered without anyone remembering to add it.
  test("a licence in a crate nobody has written yet is refused", () => {
    const { code, output } = run(
      tree({ "crates/wisq-futur/Cargo.toml": '[package]\nname = "x"\nlicense = "GPL-3.0"\n' }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("wisq-futur");
  });
});

describe("the licence guard accepts what it must not refuse", () => {
  /// The whole innocent tree, and it is not innocent of the *words*: its
  /// README, its NOTICE and its roadmap name Apache-2.0, Apache 2.0, GPL-2,
  /// the MIT License and the apache.org URL. Every one of them is a statement
  /// about somebody else's project.
  test("naming other people's licences in prose is not a claim", () => {
    const { code, output } = run(tree());
    expect(code, `la garde a refusé un arbre sain :\n${output}`).toBe(0);
    expect(output).toContain("rien n'est annoncé");
  });

  /// A manifest field that is commented out states nothing, in either
  /// language's comment syntax.
  test("a commented-out manifest field is not a claim", () => {
    const { code, output } = run(
      tree({
        "crates/wisq-agent/Cargo.toml": '[package]\nname = "x"\n# license = "MIT"\n',
      }),
    );
    expect(code, output).toBe(0);
  });

  /// A dependency whose *name* begins with the field's name. The guard's
  /// npm pattern requires the quote to close right after `license`, and this
  /// is the case that would break if someone loosened it.
  test("a dependency called license-something is not a claim", () => {
    const { code, output } = run(
      tree({
        "site/package.json":
          '{\n  "name": "wisq-site",\n  "devDependencies": { "license-checker": "^25" }\n}\n',
      }),
    );
    expect(code, output).toBe(0);
  });

  /// And the real repository, checked the way CI checks it — with no argument
  /// at all. This is the only case that holds the default root: a script that
  /// resolved it wrongly would pass every test above, since they all pass a
  /// root explicitly.
  test("this repository, with no root given, is clean", () => {
    const result = Bun.spawnSync({ cmd: ["bash", guard] });
    const output =
      new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr);
    expect(result.exitCode, output).toBe(0);
    expect(output).toContain("rien n'est annoncé");
  });
});
