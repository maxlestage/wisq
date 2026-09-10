/// La garde qui exige que la CI compare ce qu'elle vient d'engendrer, mise à
/// l'épreuve sur des arbres où elle ne le fait pas.
///
/// `scripts/check-generated-project.sh` tient une règle qui, sans elle, ne se
/// verrait jamais : chaque workflow qui lance `xcodegen generate` doit
/// comparer le résultat aux fichiers commités. Cette comparaison ne sert que
/// le jour d'une dérive — et ce jour-là, si quelqu'un l'a retirée entre-temps,
/// rien ne l'aura dit.
///
/// **Le piège que ce fichier évite**, et qui a déjà coûté à trois gardes de ce
/// dépôt : un script qui ne tourne que contre cet arbre-ci, où tout va bien,
/// n'a jamais rien refusé. On lui donne donc des copies avec une chose
/// changée, et on le regarde refuser — puis on vérifie qu'il refuse **pour la
/// bonne raison**, parce qu'un rouge qui parle d'autre chose n'est pas une
/// détection.
import { expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

setDefaultTimeout(20_000);

const repoRoot = join(import.meta.dir, "..", "..");
const guard = join(repoRoot, "scripts", "check-generated-project.sh");

/// Un arbre avec les workflows donnés, et rien d'autre : la garde ne lit que
/// `.github/workflows`.
function treeWith(flows: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-projet-"));
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  for (const [name, body] of Object.entries(flows)) {
    writeFileSync(join(root, ".github", "workflows", name), body);
  }
  return root;
}

function run(root: string): { code: number; err: string } {
  const result = Bun.spawnSync([guard, root], { stdout: "pipe", stderr: "pipe" });
  return {
    code: result.exitCode ?? -1,
    err: new TextDecoder().decode(result.stderr),
  };
}

/// Le vrai fichier, pour que le cas qui passe passe sur ce que le dépôt porte
/// vraiment — et non sur un workflow écrit pour l'occasion, qui ne testerait
/// que lui-même.
const real = readFileSync(join(repoRoot, ".github", "workflows", "ci.yml"), "utf8");

test("le dépôt tel qu'il est passe", () => {
  const { code } = run(repoRoot);
  expect(code).toBe(0);
});

test("un workflow qui régénère sans comparer est refusé", () => {
  const sans = real.replace(/git diff --exit-code[^\n]*/g, "true");
  const root = treeWith({ "ci.yml": sans });
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("régénère le projet et ne compare pas");
});

test("une comparaison qui oublie un des deux fichiers est refusée", () => {
  const partielle = real.replace(" App/Info.plist", "");
  const root = treeWith({ "ci.yml": partielle });
  const { code, err } = run(root);
  expect(code).toBe(1);
  // **Nommer le fichier oublié, pas seulement se plaindre.** Un message qui
  // dirait « la comparaison est incomplète » laisserait chercher lequel.
  expect(err).toContain("App/Info.plist");
});

test("un arbre où personne ne régénère est refusé, pas approuvé", () => {
  // **Zéro n'est pas un succès.** Une boucle qui ne trouve rien sort par le
  // haut sans avoir rien vérifié : c'est la forme d'une garde qui a déménagé
  // et que personne n'a suivie.
  const root = treeWith({ "ci.yml": "name: rien\n" });
  const { code, err } = run(root);
  expect(code).toBe(1);
  expect(err).toContain("la garde ne garde rien");
});
