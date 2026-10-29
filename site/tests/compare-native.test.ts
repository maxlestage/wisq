/// **La comparaison croisée refuse ce qui la ferait mentir.**
///
/// `scripts/compare-native.sh` existe parce qu'une comparaison en temps natif
/// entre deux copies du dépôt avait annoncé 7 et 8 % de gain pour des
/// changements qui n'en valaient pas 1 : la copie mesurait autant que la
/// branche (voir `docs/JOURNAL.md`, 29 octobre). Ce qu'il mesure ne se juge
/// qu'avec un noyau et plusieurs minutes de compilation — pas ici.
///
/// Ce qui se juge ici, c'est qu'il ne part pas de travers : sans ses deux
/// commits, sans le noyau qu'il démarre, ou devant un commit qui n'existe pas,
/// il le dit et s'arrête **avant** de créer la moindre copie. Un script de
/// mesure qui tournerait quand même rendrait des chiffres sur un noyau absent,
/// et un chiffre faux est précisément ce qu'il est là pour empêcher.
import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");
const script = join(repoRoot, "scripts", "compare-native.sh");

function run(args: string[], env: Record<string, string>): { code: number; err: string } {
  const result = spawnSync("bash", [script, ...args], {
    cwd: repoRoot,
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...env },
    encoding: "utf8",
  });
  return { code: result.status ?? -1, err: result.stderr };
}

const kernel = { WISQ_PC_KERNEL: "/nulle/part/vmlinuz", WISQ_PC_INITRD: "/nulle/part/initramfs" };

describe("compare-native.sh refuse de mesurer de travers", () => {
  test("sans ses deux commits, il dit son usage", () => {
    const { code, err } = run(["HEAD"], kernel);
    expect(code).toBe(2);
    expect(err).toContain("usage");
  });

  test("sans noyau, il ne démarre rien", () => {
    const { code, err } = run(["HEAD", "HEAD"], {});
    expect(code).toBe(2);
    expect(err).toContain("WISQ_PC_KERNEL");
  });

  test("devant un commit inconnu, il le nomme", () => {
    const { code, err } = run(["HEAD", "pas-un-commit-0000"], kernel);
    expect(code).toBe(2);
    expect(err).toContain("commit inconnu : pas-un-commit-0000");
  });
});
