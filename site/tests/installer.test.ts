/// L'installateur, exécuté — celui qu'un inconnu passe à `sh`.
///
/// `scripts/install.sh` est le seul fichier de ce dépôt dont le mode d'emploi
/// est « tuyautez-le dans un shell ». C'est aussi celui que le moins de choses
/// tenaient.
///
/// **Mesuré.** Cinq sabotages séparés, chacun contre la suite entière :
///
///   * l'autotest du binaire téléchargé supprimé — **vert** ;
///   * un argument inconnu accepté au lieu d'être refusé — **vert** ;
///   * le repli sur la construction depuis les sources rendu inatteignable —
///     **vert** ;
///   * `--version` supprimé — rouge, et `--prefix` aussi — mais **pas une
///     détection** : `check-release-matrix.sh` passe ces deux options comme
///     échafaudage pour ne pas résoudre « latest » et pour ne rien installer
///     ailleurs que dans son bac à sable. Les supprimer casse son harnais, pas
///     une affirmation sur ce qu'elles font. Un rouge qui veut dire autre chose
///     n'est pas une détection.
///
/// Donc une seule chose de l'installateur était tenue : la table
/// architecture → asset, et seulement parce qu'un autre garde l'exerce. Le
/// reste — l'analyse des arguments, l'autotest, le repli, le nettoyage — ne
/// l'était pas.
///
/// **Ce que la mesure a trouvé.** `--version` était accepté, documenté, et
/// ignoré sur le chemin des sources : `install_from_source` clonait la branche
/// par défaut quoi qu'on demande. Ce n'est pas un chemin exotique — c'est le
/// chemin de toute machine hors des quatre assets publiés (le NAS ARM, le
/// Raspberry Pi, l'ARM 32 bits, FreeBSD), et le repli de tout téléchargement
/// qui échoue. `--version v0.2.0` y installait master, sans un mot.
///
/// Rien n'est simulé de ce qui décide : un vrai dépôt git avec un vrai tag,
/// un vrai serveur HTTP local avec un vrai tar.gz, le vrai `git`, le vrai
/// `curl`, le vrai `tar`. Seul `cargo` est postiche, parce que compiler Rust
/// n'est pas ce qui est jugé ici — et il l'est honnêtement : il recopie dans
/// `target/release/wisq-agent` un marqueur pris dans le clone, si bien que le
/// binaire installé dit lui-même quel commit a été cloné.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const installer = join(import.meta.dir, "..", "..", "scripts", "install.sh");

function sh(cmd: string[], options: { cwd?: string; env?: Record<string, string> } = {}) {
  const result = Bun.spawnSync({ cmd, cwd: options.cwd, env: options.env ?? process.env });
  return {
    code: result.exitCode,
    output:
      new TextDecoder().decode(result.stdout) + new TextDecoder().decode(result.stderr),
  };
}

/// Asynchrone, et ce n'est pas un détail de style : le serveur de release
/// ci-dessous vit dans ce processus, et `Bun.spawnSync` bloque la boucle
/// d'événements — l'installateur attendrait une réponse que personne ne peut
/// écrire tant qu'il n'a pas rendu la main. Les six tests qui téléchargent
/// expiraient tous à cinq secondes avant que ceci soit await.
async function shAwait(
  cmd: string[],
  env: Record<string, string>,
): Promise<{ code: number; output: string }> {
  const child = Bun.spawn({ cmd, env, stdout: "pipe", stderr: "pipe" });
  const [out, err] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { code: await child.exited, output: out + err };
}

function scratch(prefix: string): string {
  return mkdtempSync(join(tmpdir(), `wisq-install-${prefix}-`));
}

// --- un vrai dépôt, un vrai tag ----------------------------------------------
//
// Deux commits, le tag sur le premier : le contenu du marqueur suffit alors à
// dire lequel des deux a été cloné.

let repo: string;

beforeAll(() => {
  repo = scratch("repo");
  const git = (...args: string[]) => sh(["git", ...args], { cwd: repo });
  git("init", "--quiet", "-b", "master", ".");
  git("config", "user.email", "essai@exemple.invalid");
  git("config", "user.name", "essai");
  writeFileSync(join(repo, "marqueur"), "v0.2.0");
  git("add", "-A");
  git("commit", "--quiet", "-m", "la version taguée");
  git("tag", "v0.2.0");
  writeFileSync(join(repo, "marqueur"), "master");
  git("add", "-A");
  git("commit", "--quiet", "-m", "ce qui vient après");
});

/// Un `cargo` postiche qui écrit un binaire disant ce que le clone contenait,
/// et qui note son propre passage — pour que « les sources n'ont pas été
/// construites » soit vérifiable et pas seulement supposé.
function fakeBin(options: { cargoWitness?: string } = {}): string {
  const bin = scratch("bin");
  writeFileSync(
    join(bin, "cargo"),
    [
      "#!/bin/sh",
      options.cargoWitness ? `echo construit > ${options.cargoWitness}` : "",
      "mkdir -p target/release",
      `printf '#!/bin/sh\\necho %s\\n' "$(cat marqueur)" > target/release/wisq-agent`,
      "chmod +x target/release/wisq-agent",
    ].join("\n"),
  );
  chmodSync(join(bin, "cargo"), 0o755);

  // `uname` épinglé : sinon ces tests diraient quelque chose de différent selon
  // la machine qui les joue, et le chemin du téléchargement dépend de l'asset.
  writeFileSync(
    join(bin, "uname"),
    '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac\n',
  );
  chmodSync(join(bin, "uname"), 0o755);
  return bin;
}

// --- un vrai serveur, un vrai tar.gz -----------------------------------------

/// Une archive contenant un `wisq-agent` exécutable. `runs: false` fabrique le
/// cas que l'autotest existe pour attraper : un binaire présent, installable,
/// et incapable de démarrer — mauvaise libc, mauvaise architecture, bibliothèque
/// absente. Tous ont l'air d'une installation réussie et échouent à l'usage.
function tarball(options: { runs: boolean }): Blob {
  const dir = scratch("asset");
  writeFileSync(
    join(dir, "wisq-agent"),
    options.runs ? "#!/bin/sh\necho asset publié\n" : "#!/bin/sh\nexit 1\n",
  );
  chmodSync(join(dir, "wisq-agent"), 0o755);
  sh(["tar", "-czf", join(dir, "agent.tar.gz"), "-C", dir, "wisq-agent"]);
  return new Blob([readFileSync(join(dir, "agent.tar.gz"))]);
}

type ServerOptions = { asset?: "runs" | "broken" | "absent"; latest?: string };

let server: ReturnType<typeof Bun.serve> | undefined;
let serverOptions: ServerOptions = {};

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    async fetch(request) {
      const { pathname } = new URL(request.url);
      // `curl -fsSLI .../latest` suit la redirection ; c'est de l'URL finale que
      // l'installateur tire le tag.
      if (pathname.endsWith("/latest")) {
        const tag = serverOptions.latest ?? "v0.3.0";
        return new Response(null, { status: 302, headers: { Location: `/releases/tag/${tag}` } });
      }
      if (pathname.includes("/tag/")) return new Response("", { status: 200 });
      if (pathname.endsWith(".tar.gz")) {
        if ((serverOptions.asset ?? "absent") === "absent") {
          return new Response("introuvable", { status: 404 });
        }
        return new Response(tarball({ runs: serverOptions.asset === "runs" }));
      }
      return new Response("", { status: 404 });
    },
  });
});

afterAll(() => server?.stop(true));

/// L'installateur, lancé comme un inconnu le lance — mais vers ce dépôt-ci et
/// ce serveur-ci. Les variables de proxy sont retirées : `curl` doit joindre
/// 127.0.0.1 directement, et un proxy le lui interdirait.
async function install(
  args: string[],
  options: {
    asset?: ServerOptions["asset"];
    latest?: string;
    tmp?: string;
    path?: string;
    prefix?: string;
  } = {},
) {
  serverOptions = { asset: options.asset, latest: options.latest };
  const prefix = options.prefix ?? scratch("prefix");
  const cargoWitness = join(scratch("temoin"), "cargo-a-tourne");
  const bin = fakeBin({ cargoWitness });

  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(https?_proxy|HTTPS?_PROXY|ALL_PROXY|all_proxy)$/.test(key)) continue;
    if (value !== undefined) env[key] = value;
  }
  env.PATH = `${bin}:${env.PATH}`;
  env.NO_PROXY = "127.0.0.1,localhost";
  env.no_proxy = "127.0.0.1,localhost";
  env.WISQ_REPO = `file://${repo}`;
  env.WISQ_RELEASES = `http://127.0.0.1:${server!.port}/releases`;
  if (options.tmp) env.TMPDIR = options.tmp;
  if (options.path !== undefined) env.PATH = `${bin}:${options.path}`;

  const { code, output } = await shAwait(["sh", installer, "--prefix", prefix, ...args], env);
  const installed = join(prefix, "wisq-agent");
  return {
    code,
    output,
    prefix,
    exists: existsSync(installed),
    /// Ce que le binaire installé dit de lui-même : « v0.2.0 » ou « master »
    /// pour une construction depuis les sources, « asset publié » pour un
    /// téléchargement.
    says: existsSync(installed) ? sh([installed]).output.trim() : "(rien d'installé)",
    builtFromSource: existsSync(cargoWitness),
  };
}

describe("l'installateur tient ce que son aide annonce", () => {
  /// Le défaut. `--version` était accepté ici et ignoré : la branche par défaut
  /// était clonée quoi qu'on demande.
  test("--from-source --version installe cette version-là, pas la branche par défaut", async () => {
    const run = await install(["--from-source", "--version", "v0.2.0"]);
    expect(run.code, run.output).toBe(0);
    expect(run.says, `la version demandée a été ignorée :\n${run.output}`).toBe("v0.2.0");
  });

  /// Et sur le chemin par lequel on y arrive vraiment : le téléchargement
  /// échoue, le repli construit — et doit construire la version demandée.
  test("le repli après un téléchargement manquant construit la version demandée", async () => {
    const run = await install(["--version", "v0.2.0"], { asset: "absent" });
    expect(run.code, run.output).toBe(0);
    expect(run.builtFromSource, `le repli n'a pas eu lieu :\n${run.output}`).toBe(true);
    expect(run.says, run.output).toBe("v0.2.0");
  });

  /// Un binaire présent et incapable de démarrer ressemble à une installation
  /// réussie et échoue à la première utilisation. L'autotest existe pour ça, et
  /// rien ne le tenait.
  test("un binaire téléchargé qui ne démarre pas est refusé, et les sources prennent le relais", async () => {
    const run = await install(["--version", "v0.2.0"], { asset: "broken" });
    expect(run.code, run.output).toBe(0);
    expect(run.builtFromSource, `le binaire cassé a été installé tel quel :\n${run.output}`).toBe(
      true,
    );
    expect(run.says, run.output).toBe("v0.2.0");
  });

  test("un asset absent bascule sur la construction depuis les sources", async () => {
    const run = await install(["--version", "v0.2.0"], { asset: "absent" });
    expect(run.output).toContain("repli sur la construction depuis les sources");
    expect(run.exists, run.output).toBe(true);
  });

  test("un argument inconnu est refusé, et rien n'est installé", async () => {
    const run = await install(["--tout-casser"]);
    expect(run.code, run.output).toBe(2);
    expect(run.output).toContain("argument inconnu");
    expect(run.exists, run.output).toBe(false);
  });

  /// L'aide s'arrête avant le code. La plage était `2,14p` et la ligne 14 est
  /// `set -eu` : l'aide imprimait une ligne de programme.
  test("--help imprime les options et s'arrête avant le code", async () => {
    const run = await shAwait(["sh", installer, "--help"], process.env as Record<string, string>);
    expect(run.code).toBe(0);
    expect(run.output).toContain("--from-source");
    expect(run.output).toContain("(Linux) service");
    expect(run.output, "l'aide déborde sur le programme").not.toContain("set -eu");
  });

  /// Deux répertoires temporaires sur le chemin du repli, et un seul `trap` :
  /// le second remplaçait le premier, qui restait dans /tmp pour de bon.
  test("le repli ne laisse aucun répertoire temporaire derrière lui", async () => {
    const tmp = scratch("bac");
    const run = await install(["--version", "v0.2.0"], { asset: "broken", tmp });
    expect(run.exists, run.output).toBe(true);
    expect(
      readdirSync(tmp),
      `des répertoires temporaires ont survécu à l'installation :\n${run.output}`,
    ).toEqual([]);
  });
});

describe("… et n'exige rien de plus", () => {
  /// L'autre bord de la règle. Le défaut se « corrigeait » aussi en exigeant
  /// toujours un tag — ce qui aurait cassé le cas courant pour réparer le rare.
  /// Sans `--version`, la branche par défaut, et rien d'autre.
  test("sans --version, c'est la branche par défaut qui est construite", async () => {
    const run = await install(["--from-source"]);
    expect(run.code, run.output).toBe(0);
    expect(run.says, run.output).toBe("master");
  });

  /// « latest » n'est pas un tag : il se résout par la redirection du serveur,
  /// et c'est le tag résolu qui doit apparaître dans l'URL de l'asset.
  test("« latest » se résout par la redirection et donne l'URL de ce tag", async () => {
    const run = await install([], { asset: "runs", latest: "v0.9.9" });
    expect(run.code, run.output).toBe(0);
    expect(run.output).toContain("wisq-agent-v0.9.9-linux-x86_64.tar.gz");
    expect(run.says, run.output).toBe("asset publié");
  });

  /// Un binaire publié qui marche s'installe, et les sources ne sont pas
  /// construites : un repli qui se déclencherait quand même ferait payer un
  /// toolchain Rust à des machines qui n'en ont pas besoin.
  test("un binaire publié qui démarre est installé sans construire les sources", async () => {
    const run = await install(["--version", "v0.2.0"], { asset: "runs" });
    expect(run.code, run.output).toBe(0);
    expect(run.says, run.output).toBe("asset publié");
    expect(run.builtFromSource, `les sources ont été construites pour rien :\n${run.output}`).toBe(
      false,
    );
  });

  test("--prefix décide où le binaire atterrit", async () => {
    const run = await install(["--from-source"]);
    expect(run.exists, run.output).toBe(true);
    expect(run.output).toContain(`installé : ${run.prefix}/wisq-agent`);
  });

  /// La note sur le PATH est un service, pas un avertissement : elle ne doit
  /// paraître que lorsqu'elle sert.
  test("un préfixe déjà dans le PATH ne déclenche aucune note", async () => {
    // Le même préfixe dans les deux sens : deux répertoires différents ne
    // compareraient rien.
    const prefix = scratch("prefix");
    const absent = await install(["--from-source"], { prefix, path: "/usr/bin:/bin" });
    expect(absent.output).toContain("ajoutez");
    const present = await install(["--from-source"], { prefix, path: `${prefix}:/usr/bin:/bin` });
    expect(present.output, "une note inutile").not.toContain("ajoutez");
  });
});
