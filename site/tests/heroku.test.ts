/// Ce que Heroku exécute réellement, exécuté ici.
///
/// Le `Procfile` lance `scripts/heroku-web.sh`, qui lance `site/scripts/serve.ts`.
/// Le serveur est tenu en mémoire par `serve.test.ts` — requête par requête,
/// sans ouvrir de port — mais les deux scripts autour de lui ne l'étaient par
/// rien : `heroku-web.sh` remplacé par `exit 1`, suite entière **verte** ; la
/// garde `dist/index.html` de `heroku-build.sh` neutralisée, **verte** aussi.
/// Le processus que le dyno démarre, avec ses trois branches écrites pour être
/// lues sur un téléphone au milieu d'un déploiement raté, n'avait jamais tourné
/// une seule fois.
///
/// **Et la mesure a d'abord menti.** Les deux premiers essais de sabotage ont
/// rendu onze et quatorze rouges — qui n'étaient pas des détections : la
/// dernière porte de `verify.sh` (#140) reconstruisait `site/dist` avec
/// l'adresse épinglée `wisq.example`, et toute suite lancée ensuite lisait ce
/// dist-là. Un rouge qui veut dire autre chose n'est pas une détection ; il a
/// fallu restaurer le baseline et remesurer pour voir le vert véritable. La
/// mine est corrigée — la construction sentinelle passe en dernier — et l'ordre
/// est tenu ici, parce qu'il a déjà mordu une fois.
///
/// Le vrai Bun sert de témoin de bout en bout : le vrai `heroku-web.sh`, à sa
/// vraie place, sert le vrai `dist` sur un vrai port. Les branches, elles, sont
/// départagées dans des arbres jetables avec des Bun enregistreurs — c'est le
/// choix de branche qui est jugé là, pas le serveur, déjà tenu ailleurs.

import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

function read(path: string): string {
  return readFileSync(join(repoRoot, path), "utf8");
}

async function run(
  cmd: string[],
  options: { cwd?: string; env?: Record<string, string | undefined> } = {},
): Promise<{ code: number; output: string }> {
  const child = Bun.spawn({
    cmd,
    cwd: options.cwd,
    env: { ...process.env, ...options.env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { code: await child.exited, output: out + err };
}

/// Un arbre jetable portant le vrai `heroku-web.sh` (il remonte d'un cran par
/// `dirname`, donc il faut lui donner un cran). Les Bun sont des enregistreurs :
/// chacun écrit qui il est et ce qu'on lui a demandé, puis s'arrête — c'est le
/// choix de branche qui est jugé, pas le serveur.
function webTree(options: { slugBun?: boolean; pathBun?: boolean }): {
  root: string;
  witness: string;
  env: Record<string, string>;
} {
  const root = mkdtempSync(join(tmpdir(), "wisq-heroku-web-"));
  const witness = join(root, "temoin.txt");
  mkdirSync(join(root, "scripts"), { recursive: true });
  writeFileSync(join(root, "scripts", "heroku-web.sh"), read("scripts/heroku-web.sh"));
  chmodSync(join(root, "scripts", "heroku-web.sh"), 0o755);

  const recorder = (who: string) =>
    `#!/bin/sh\necho "${who} $@" > "${witness}"\n`;

  if (options.slugBun) {
    mkdirSync(join(root, ".heroku-bun", "bin"), { recursive: true });
    writeFileSync(join(root, ".heroku-bun", "bin", "bun"), recorder("slug"));
    chmodSync(join(root, ".heroku-bun", "bin", "bun"), 0o755);
  }

  // Un PATH minimal et contrôlé : bash et coreutils, plus — ou non — un bun.
  // Hériter du PATH réel ferait trouver le vrai Bun à la branche de repli, et
  // le test « aucun bun » ne pourrait jamais échouer pour la bonne raison.
  let path = "/usr/bin:/bin";
  if (options.pathBun) {
    const bin = join(root, "chemin-bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "bun"), recorder("chemin"));
    chmodSync(join(bin, "bun"), 0o755);
    path = `${bin}:${path}`;
  }
  return { root, witness, env: { PATH: path } };
}

async function web(options: { slugBun?: boolean; pathBun?: boolean }) {
  const { root, witness, env } = webTree(options);
  const result = await run(["bash", join(root, "scripts", "heroku-web.sh")], { env });
  return {
    ...result,
    ran: existsSync(witness) ? readFileSync(witness, "utf8").trim() : "(aucun bun lancé)",
  };
}

describe("heroku-web.sh choisit son Bun comme il le promet", () => {
  test("le Bun du slug est préféré, et reçoit le serveur à lancer", async () => {
    const result = await web({ slugBun: true, pathBun: true });
    expect(result.code, result.output).toBe(0);
    // Les deux à la fois, et c'est celui du slug qui gagne : celui d'un
    // buildpack vit sous un répertoire de construction que le dyno ne voit
    // pas ; préférer le PATH serait marcher sur de la chance.
    expect(result.ran).toBe("slug site/scripts/serve.ts");
  });

  test("sans slug, le Bun du PATH sert de repli, et le dit", async () => {
    const result = await web({ pathBun: true });
    expect(result.code, result.output).toBe(0);
    expect(result.ran).toBe("chemin site/scripts/serve.ts");
    expect(result.output).toContain(".heroku-bun est absent du slug");
  });

  /// La branche écrite pour être lue sur un téléphone : une ligne qui nomme le
  /// script de construction fautif, au lieu d'une pile de redémarrages.
  test("sans aucun Bun, une explication en une ligne plutôt qu'une boucle de crash", async () => {
    const result = await web({});
    expect(result.code, result.output).toBe(1);
    expect(result.ran).toBe("(aucun bun lancé)");
    expect(result.output).toContain("aucun bun disponible");
    expect(result.output).toContain("scripts/heroku-build.sh");
  });

  /// Le vrai script, à sa vraie place, avec le vrai Bun : il doit servir le
  /// vrai `dist` sur le port que Heroku lui donne. C'est le processus du dyno,
  /// exécuté — pas relu.
  test("le processus du dyno sert réellement le site construit", async () => {
    const probe = Bun.serve({ port: 0, fetch: () => new Response("") });
    const port = probe.port;
    probe.stop(true);

    const child = Bun.spawn({
      cmd: ["bash", join(repoRoot, "scripts", "heroku-web.sh")],
      env: { ...process.env, PORT: String(port) },
      stdout: "ignore",
      stderr: "ignore",
    });
    try {
      let page = "";
      for (let attempt = 0; attempt < 40 && page === ""; attempt += 1) {
        await Bun.sleep(100);
        // curl plutôt que fetch : le fetch de Bun honore les variables de
        // proxy de cet environnement, et 127.0.0.1 doit être joint en direct.
        const got = await run(["curl", "-fsS", `http://127.0.0.1:${port}/`], {
          env: { http_proxy: undefined, https_proxy: undefined, HTTP_PROXY: undefined, HTTPS_PROXY: undefined },
        });
        if (got.code === 0) page = got.output;
      }
      expect(page, "le serveur du dyno n'a jamais répondu").toContain("wisq");
    } finally {
      child.kill();
      await child.exited;
    }
  });
});

/// Un arbre jetable pour `heroku-build.sh` : un `.heroku-bun` pré-rempli pour
/// qu'il ne télécharge rien, et un `site/` minimal. Le Bun postiche est le
/// point du montage : `builds` décide s'il produit un `dist/index.html`, et
/// c'est la garde du script — pas la construction — qui est jugée.
function buildTree(options: { builds: boolean }): string {
  const root = mkdtempSync(join(tmpdir(), "wisq-heroku-build-"));
  mkdirSync(join(root, "scripts"), { recursive: true });
  writeFileSync(join(root, "scripts", "heroku-build.sh"), read("scripts/heroku-build.sh"));
  chmodSync(join(root, "scripts", "heroku-build.sh"), 0o755);
  mkdirSync(join(root, "site"), { recursive: true });
  mkdirSync(join(root, ".heroku-bun", "bin"), { recursive: true });
  writeFileSync(
    join(root, ".heroku-bun", "bin", "bun"),
    [
      "#!/bin/sh",
      'if [ "$1" = "--version" ]; then echo 0.0.0-postiche; exit 0; fi',
      options.builds
        ? 'if [ "$1" = "run" ] && [ "$2" = "build" ]; then mkdir -p dist && echo site > dist/index.html; fi'
        : "",
      "exit 0",
    ].join("\n"),
  );
  chmodSync(join(root, ".heroku-bun", "bin", "bun"), 0o755);
  return root;
}

describe("heroku-build.sh refuse un slug qui aurait l'air de marcher", () => {
  /// Un slug qui expédie un `dist` vide démarre, répond 404 à tout, et
  /// ressemble à un problème de routage. La garde existait ; rien ne l'avait
  /// jamais vue refuser.
  test("une construction qui ne produit pas dist/index.html est refusée", async () => {
    const result = await run(["bash", join(buildTree({ builds: false }), "scripts", "heroku-build.sh")]);
    expect(result.code, result.output).toBe(1);
    expect(result.output).toContain("n'a pas produit dist/index.html");
  });

  test("une construction qui le produit passe", async () => {
    const result = await run(["bash", join(buildTree({ builds: true }), "scripts", "heroku-build.sh")]);
    expect(result.code, result.output).toBe(0);
    expect(result.output).toContain("Site construit");
  });

  /// Le message de configuration a deux bords : dire comment épingler quand
  /// rien ne l'est, et se taire quand c'est fait.
  test("sans SITE_URL le script explique comment l'épingler ; avec, il se tait", async () => {
    const without = await run(
      ["bash", join(buildTree({ builds: true }), "scripts", "heroku-build.sh")],
      { env: { SITE_URL: undefined } },
    );
    expect(without.output).toContain("SITE_URL n'est pas défini");
    const withUrl = await run(
      ["bash", join(buildTree({ builds: true }), "scripts", "heroku-build.sh")],
      { env: { SITE_URL: "https://wisq.example/" } },
    );
    expect(withUrl.code, withUrl.output).toBe(0);
    expect(withUrl.output, "l'explication est du bruit quand l'adresse est épinglée").not.toContain(
      "SITE_URL n'est pas défini",
    );
  });
});

describe("la chaîne du dyno tient d'un bout à l'autre", () => {
  /// Le Procfile promet que « ce que Heroku sert est ce que les tests
  /// tiennent ». Cette phrase repose sur trois liens de texte, et un seul qui
  /// casse la rend fausse en silence.
  test("Procfile → heroku-web.sh → serve.ts, et serve.ts existe", () => {
    expect(read("Procfile")).toContain("web: ./scripts/heroku-web.sh");
    const script = read("scripts/heroku-web.sh");
    expect(script.match(/site\/scripts\/serve\.ts/g)?.length, "les deux exec").toBe(2);
    expect(existsSync(join(repoRoot, "site", "scripts", "serve.ts"))).toBe(true);
  });

  /// L'ordre des deux constructions Heroku dans verify.sh est une mine
  /// mesurée : chacune réécrit `site/dist`, la suite le lit, et finir sur la
  /// construction épinglée laissait l'arbre estampillé wisq.example — onze
  /// rouges au prochain `bun test`, sans rapport avec ce que le contributeur
  /// avait changé. La sentinelle passe en dernier, et ceci l'empêche de
  /// revenir discrètement dans l'autre sens.
  test("verify.sh finit ses constructions Heroku par celle que la suite lit", () => {
    const verify = read("scripts/verify.sh");
    const pinned = verify.indexOf("SITE_URL=https://wisq.example/ npm run heroku-postbuild");
    const sentinel = verify.lastIndexOf("  npm run heroku-postbuild");
    expect(pinned, "la construction épinglée a disparu de verify.sh").toBeGreaterThan(-1);
    expect(sentinel, "la construction sentinelle a disparu de verify.sh").toBeGreaterThan(-1);
    expect(pinned, "l'épinglée doit précéder la sentinelle, pas l'inverse").toBeLessThan(sentinel);
  });
});
