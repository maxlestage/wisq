/// **L'index des bureaux prêts déjà publié, lu sans le perdre.**
///
/// `.github/workflows/bureaux.yml` publie un `bureaux.json` neuf qui garde les
/// entrées de l'ancien d'un autre niveau de machine : une application d'avant
/// y retrouve le bureau qu'elle sait reprendre. L'étape lisait l'ancien par
/// `if curl -f …; then garder; fi`, et le code 22 de `curl -f` est le même pour
/// un 404, un 500 après les essais ou un 403 de limite de débit — une panne
/// DNS tombait dans la même branche. Toute panne devenait « rien de publié »,
/// le job rendait 0, et l'index publié perdait le bureau du niveau d'avant.
///
/// `scripts/bureaux-ancien-index.sh` ne prend pour « absent » qu'un 404
/// constaté. Ce fichier le met devant un serveur qui répond chacun des cas, et
/// vérifie que le workflow passe bien par lui.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Un essai de plus après une panne passagère attend une seconde ; une machine
// chargée en met davantage.
setDefaultTimeout(20_000);

const repoRoot = join(import.meta.dir, "..", "..");
const script = join(repoRoot, "scripts", "bureaux-ancien-index.sh");
const index = '{"format": 1, "desktops": []}';

let server: ReturnType<typeof Bun.serve> | undefined;
let passager = 0;

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const { pathname } = new URL(request.url);
      switch (pathname) {
        case "/ok":
          return new Response(index);
        case "/redirige":
          return new Response(null, { status: 302, headers: { Location: "/ok" } });
        case "/absent":
          return new Response("Not Found", { status: 404 });
        case "/redirige-absent":
          return new Response(null, { status: 302, headers: { Location: "/absent" } });
        case "/panne":
          return new Response("erreur", { status: 500 });
        case "/limite":
          return new Response("API rate limit exceeded", { status: 403 });
        case "/passager":
          passager += 1;
          return passager === 1 ? new Response("occupé", { status: 503 }) : new Response(index);
        default:
          return new Response("?", { status: 418 });
      }
    },
  });
});

afterAll(() => server?.stop(true));

/// Le script, lancé tel quel (il doit être exécutable : le workflow l'appelle
/// sans `bash`), sans proxy : `curl` doit joindre 127.0.0.1 directement.
async function lire(url: string, out: string): Promise<{ code: number; output: string }> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(https?_proxy|HTTPS?_PROXY|ALL_PROXY|all_proxy)$/.test(key)) continue;
    if (value !== undefined) env[key] = value;
  }
  env.NO_PROXY = "127.0.0.1,localhost";
  env.no_proxy = "127.0.0.1,localhost";
  env.BUREAUX_ESSAIS = "1";
  const child = Bun.spawn({ cmd: [script, url, out], env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { code: await child.exited, output: stdout + stderr };
}

/// Un dossier neuf, et un fichier de sortie qui existe déjà : celui d'un
/// essai d'avant ne doit jamais passer pour la réponse de celui-ci.
function sortie(): string {
  const out = join(mkdtempSync(join(tmpdir(), "wisq-ancien-index-")), "ancien.json");
  writeFileSync(out, "un vieux fichier");
  return out;
}

const base = () => `http://127.0.0.1:${server!.port}`;

describe("l'ancien index des bureaux prêts", () => {
  test("un 200 l'écrit, redirection suivie", async () => {
    for (const chemin of ["/ok", "/redirige"]) {
      const out = sortie();
      const run = await lire(base() + chemin, out);
      expect(run.code, run.output).toBe(0);
      expect(readFileSync(out, "utf8")).toBe(index);
      expect(existsSync(`${out}.part`)).toBe(false);
    }
  });

  test("seul un 404 veut dire « rien de publié » : code 0, aucun fichier", async () => {
    for (const chemin of ["/absent", "/redirige-absent"]) {
      const out = sortie();
      const run = await lire(base() + chemin, out);
      expect(run.code, run.output).toBe(0);
      expect(existsSync(out), "la page 404 n'est pas un index").toBe(false);
      expect(run.output).toContain("404");
    }
  });

  test("un 500, un 403, une autre réponse : le job tombe, aucun fichier", async () => {
    for (const chemin of ["/panne", "/limite", "/autre"]) {
      const out = sortie();
      const run = await lire(base() + chemin, out);
      expect(run.code, `${chemin} : ${run.output}`).toBe(1);
      expect(existsSync(out), `${chemin} : rien à garder`).toBe(false);
      expect(existsSync(`${out}.part`)).toBe(false);
      expect(run.output).toContain("::error::");
    }
  });

  test("un serveur injoignable : le job tombe, aucun fichier", async () => {
    const mort = Bun.serve({ port: 0, fetch: () => new Response("") });
    const port = mort.port;
    mort.stop(true);
    const out = sortie();
    const run = await lire(`http://127.0.0.1:${port}/bureaux.json`, out);
    expect(run.code, run.output).toBe(1);
    expect(existsSync(out)).toBe(false);
    expect(run.output).toContain("HTTP 000");
  });

  test("une panne passagère est réessayée", async () => {
    passager = 0;
    const out = sortie();
    const run = await lire(`${base()}/passager`, out);
    expect(run.code, run.output).toBe(0);
    expect(passager).toBe(2);
    expect(readFileSync(out, "utf8")).toBe(index);
  });

  /// Le workflow passe par le script, dans une étape qui tombe à la première
  /// commande en échec, et ne garde l'ancien que s'il a été écrit.
  test("bureaux.yml lit l'ancien index par ce script", () => {
    const workflow = readFileSync(join(repoRoot, ".github", "workflows", "bureaux.yml"), "utf8")
      .split("\n")
      .filter((line) => !/^\s*#/.test(line))
      .join("\n");
    const appel = workflow.indexOf("scripts/bureaux-ancien-index.sh");
    expect(appel, "l'ancien index n'est plus lu par le script").toBeGreaterThan(0);
    expect(workflow).not.toMatch(/if\s+curl/);
    expect(workflow).not.toMatch(/curl[^\n]*(\\\n[^\n]*)*bureaux\.json/);
    const etape = workflow.slice(workflow.lastIndexOf("run: |", appel), appel);
    expect(etape).toContain("set -euo pipefail");
    // La commande seule sur sa ligne, rien autour : un `|| true`, un `if` ou
    // un `!` avaleraient l'échec, et le job publierait l'index amputé.
    expect(workflow).toMatch(
      /\n {10}scripts\/bureaux-ancien-index\.sh \\\n {12}"https:\/\/github\.com\/\$GITHUB_REPOSITORY\/releases\/download\/bureaux-1\/bureaux\.json" bureau\/ancien\.json\n/,
    );
    expect(workflow).toContain("if [ -f bureau/ancien.json ]; then\n            garder=(--garder bureau/ancien.json)");
  });
});
