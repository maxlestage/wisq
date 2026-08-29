/// The guard that keeps the installer and the release workflow in agreement,
/// run against trees where they disagree.
///
/// `scripts/check-release-matrix.sh` exists because the two drifted apart once
/// already: the workflow built `linux-x86_64` and `macos-arm64`, the installer
/// asked for exactly those, and every other machine — an ARM NAS, a Raspberry
/// Pi, an Intel Mac — fell silently through to a source build needing a Rust
/// toolchain. Nobody sees that failure but the person installing.
///
/// **Measured.** Three separate breakages of the guard's own logic were tried,
/// and each one leaves it **green on this tree**:
///
///   * `expect_asset` made never to compare — exit 0;
///   * both `comm` calls neutered — exit 0;
///   * `exit "$failed"` turned into `exit 0` — exit 0.
///
/// So CI would have printed "matrice des architectures cohérente" on every
/// commit while the guard checked nothing. It could only ever be run against
/// this repository, where the two lists agree, and a guard that has never
/// refused is a guard nobody has checked. (A fourth, swapping `comm -13` for
/// `comm -12`, did go red — but for the wrong reason: it reported the four
/// *matching* assets as missing. A red that means something else is not a
/// detection.)
///
/// So the script now takes a root, and this file gives it copies of the two
/// real files with one thing changed in one of them. Real copies rather than
/// invented fixtures on purpose: the mapping half of the guard runs the actual
/// installer under a fake `uname`, so an installer written for a test would be
/// testing the fixture.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const guard = join(repoRoot, "scripts", "check-release-matrix.sh");
const WORKFLOW = ".github/workflows/release.yml";
const INSTALLER = "scripts/install.sh";

/// A copy of the two files that decide, with `edit` applied to each.
function tree(edits: {
  workflow?: (text: string) => string;
  installer?: (text: string) => string;
}): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-matrix-"));
  for (const [path, edit] of [
    [WORKFLOW, edits.workflow],
    [INSTALLER, edits.installer],
  ] as const) {
    const destination = join(root, path);
    mkdirSync(dirname(destination), { recursive: true });
    const original = readFileSync(join(repoRoot, path), "utf8");
    writeFileSync(destination, edit ? edit(original) : original, { mode: 0o755 });
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

/// The line the installer's `case` ends on, and the anchor every mutation
/// below inserts before. Read out of the real file rather than written here,
/// so a rewrite of the installer fails these tests loudly instead of leaving
/// them quietly inserting nothing.
const FALLTHROUGH = '  *) ASSET_SUFFIX="" ;;';

describe("the release-matrix guard refuses a matrix that has drifted", () => {
  test("the anchor these tests edit still exists in the installer", () => {
    expect(readFileSync(join(repoRoot, INSTALLER), "utf8")).toContain(FALLTHROUGH);
    expect(readFileSync(join(repoRoot, WORKFLOW), "utf8")).toContain("          - asset: linux-x86_64");
  });

  /// The direction that matters: a 404 in the middle of an install, on a
  /// machine nobody who works on this has.
  test("an asset the installer asks for and nobody builds is refused", () => {
    const { code, output } = run(
      tree({
        installer: (text) =>
          text.replace(
            FALLTHROUGH,
            `  Linux/ppc64le) ASSET_SUFFIX="linux-ppc64le" ;;\n${FALLTHROUGH}`,
          ),
      }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("linux-ppc64le");
    expect(output).toContain("ne construit pas");
  });

  /// The other direction is not harmless either: an asset built, uploaded and
  /// attached to every release that no installer will ever ask for is a build
  /// minute and a download nobody can use, and it looks like coverage.
  test("an asset built and never asked for is refused", () => {
    const { code, output } = run(
      tree({
        workflow: (text) =>
          text.replace(
            "          - asset: linux-x86_64",
            "          - asset: linux-riscv64\n          - asset: linux-x86_64",
          ),
      }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("linux-riscv64");
    expect(output).toContain("ne demande jamais");
  });

  /// The mistake the set comparison **cannot** see, and the reason the guard
  /// runs the installer at all: every Apple silicon Mac downloading an Intel
  /// binary and vice versa.
  ///
  /// The two mappings are **swapped**, not one of them changed, and that is
  /// the whole point. Changing only `Darwin/arm64` would leave `macos-arm64`
  /// built and never requested, which the set check catches — the test would
  /// pass with the mapping check removed and would be a witness to the wrong
  /// thing. Swapping them keeps both lists exactly as they were. Verified:
  /// with `expect_asset` made never to compare, this goes red.
  test("two real asset names sent to each other's machine are refused", () => {
    const { code, output } = run(
      tree({
        installer: (text) =>
          text
            .replace(
              '  Darwin/arm64) ASSET_SUFFIX="macos-arm64" ;;',
              '  Darwin/arm64) ASSET_SUFFIX="macos-INTEL" ;;',
            )
            .replace(
              '  Darwin/x86_64) ASSET_SUFFIX="macos-x86_64" ;;',
              '  Darwin/x86_64) ASSET_SUFFIX="macos-arm64" ;;',
            )
            .replace('ASSET_SUFFIX="macos-INTEL"', 'ASSET_SUFFIX="macos-x86_64"'),
      }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("envoie Darwin/arm64 vers 'macos-x86_64'");
    expect(output).toContain("envoie Darwin/x86_64 vers 'macos-arm64'");
    // Et la preuve que la comparaison d'ensembles n'a rien vu : elle n'a rien
    // dit. C'est ce silence-là qui rend le test témoin de sa propre garde.
    expect(output).not.toContain("ne construit pas");
    expect(output).not.toContain("ne demande jamais");
  });

  /// The same blindness in the other direction: a machine deliberately left to
  /// the source build, handed a binary that will not run on it. 32-bit ARM
  /// given the 64-bit tarball, and every list still agrees.
  test("a machine that should build from source and is given a binary is refused", () => {
    const { code, output } = run(
      tree({
        installer: (text) =>
          text.replace(
            '  Linux/aarch64|Linux/arm64) ASSET_SUFFIX="linux-aarch64" ;;',
            '  Linux/aarch64|Linux/arm64|Linux/armv7l) ASSET_SUFFIX="linux-aarch64" ;;',
          ),
      }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("Linux/armv7l");
  });

  /// Both empty-list branches. They are the shape a guard fails at silently:
  /// a workflow or an installer rewritten so that the pattern no longer
  /// matches leaves two empty lists, which compare equal — the guard would
  /// announce a coherent matrix having read nothing at all.
  test("a workflow that declares no asset at all is refused", () => {
    const { code, output } = run(
      tree({ workflow: (text) => text.replaceAll(/^\s*- asset: .*$/gm, "") }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("ne déclare plus aucun asset");
  });

  test("an installer that asks for no asset at all is refused", () => {
    const { code, output } = run(
      tree({ installer: (text) => text.replaceAll(/ASSET_SUFFIX="[A-Za-z0-9_.-]+"/g, 'ASSET_SUFFIX=""') }),
    );
    expect(code, output).not.toBe(0);
    expect(output).toContain("ne demande plus aucun asset");
  });
});

describe("the release-matrix guard accepts what it must not refuse", () => {
  /// The two files as they are. Without this the tests above would all pass
  /// against a guard that refused everything.
  test("the repository as it stands is coherent", () => {
    const { code, output } = run(tree({}));
    expect(code, output).toBe(0);
    expect(output).toContain("matrice des architectures cohérente");
  });

  /// A new architecture, added properly to both sides. A guard that refused
  /// this would make publishing one impossible, which is worse than the drift
  /// it exists to catch.
  test("an architecture added to both sides is accepted", () => {
    const { code, output } = run(
      tree({
        workflow: (text) =>
          text.replace(
            "          - asset: linux-x86_64",
            "          - asset: linux-ppc64le\n          - asset: linux-x86_64",
          ),
        installer: (text) =>
          text.replace(
            FALLTHROUGH,
            `  Linux/ppc64le) ASSET_SUFFIX="linux-ppc64le" ;;\n${FALLTHROUGH}`,
          ),
      }),
    );
    expect(code, output).toBe(0);
    expect(output).toContain("linux-ppc64le");
  });

  /// And the real repository through the default root, with no argument — the
  /// only case that holds the path resolution, since every other test passes a
  /// root explicitly.
  test("this repository, with no root given, is coherent", () => {
    const result = Bun.spawnSync({ cmd: ["bash", guard] });
    const output =
      new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr);
    expect(result.exitCode, output).toBe(0);
  });
});
