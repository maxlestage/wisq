/// « Everything CI would run, in one command » — la phrase, et ce qui la tient.
///
/// C'est la première ligne de `scripts/verify.sh`. Ce même fichier porte, dans
/// ses propres commentaires, **trois** aveux d'avoir eu tort :
///
///   * « CI lints, and a script that claims to run everything CI runs has to
///     lint too. A trailing blank line reached a pull request and turned it
///     red while this said "everything CI would run". » ;
///   * « CI runs these two and this script did not, so a run could come back
///     green on a branch CI would refuse — which is exactly what happened. » ;
///   * « CI runs this one and this script did not — the third time this file
///     has had exactly that bug. »
///
/// Trois fois la même faute, chaque fois trouvée par une pull request rouge,
/// chaque fois réparée à la main. Rien ne comparait les deux listes.
///
/// **Mesuré**, en comptant les occurrences dans `verify.sh` et les scripts
/// qu'il appelle, contre les deux workflows :
///
/// | ce que la CI lance | verify.sh |
/// |---|---|
/// | `WISQ_SWIFT_CORE=1 swift build` | absent |
/// | `npm run heroku-postbuild`, deux fois | absent |
/// | `swift run -c release wisq-bench` | absent |
/// | l'agent statique musl + `env -i … --help` | absent |
///
/// Quatre, dont la construction qui déploie réellement le site et l'échappatoire
/// que le manifeste conseille à qui n'a pas cargo.
///
/// **Un cinquième n'en était pas un**, et il mérite d'être écrit parce que je
/// l'avais déjà comblé avant de le mesurer. La CI pose `WISQ_LINUX_IMAGE` sur
/// son `swift test` et `verify.sh` ne le posait pas — ce qui ressemblait
/// exactement aux quatre autres. Les deux runs, avant et après, rendent le même
/// unique saut : `LinuxBootTests` et `DifferentialBootTests` lisent la variable
/// *ou* se rabattent sur le chemin bien connu. Équivalence réelle, l'un des
/// quatre verdicts possibles quand un sabotage ne mord pas — et la ligne a été
/// retirée plutôt que gardée pour faire nombre.
///
/// **La forme de la garde.** Comparer deux scripts shell par ressemblance de
/// texte serait fragile dans les deux sens — silencieux quand il faut parler,
/// bruyant quand il ne faut pas. Alors ce fichier tient un **inventaire
/// déclaré** : chaque étape nommée des deux workflows y figure, avec un verdict
/// — soit un motif que `verify.sh` doit contenir, soit une raison de ne pas la
/// lancer localement. Une étape ajoutée à la CI et classée par personne fait
/// rougir ce test. C'est précisément ce qui manquait les trois fois.
///
/// Et l'autre bord : la garde ne doit pas exiger l'impossible. Xcode, un
/// simulateur d'iPhone et Homebrew ne sont pas sur une machine Linux, et
/// réclamer ces étapes-là rendrait `verify.sh` inutilisable là où il sert le
/// plus. D'où la seconde colonne, qui doit porter une vraie raison.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

function read(path: string): string {
  return readFileSync(join(repoRoot, path), "utf8");
}

const WORKFLOWS = [".github/workflows/ci.yml", ".github/workflows/site.yml"];

/// `verify.sh` seul, et non les scripts qu'il appelle.
///
/// La première version cherchait aussi dans `check-*.sh` et `test-rust-core.sh`,
/// pour ne pas compter comme absent ce qui est délégué. Mesuré : aucun motif du
/// tableau n'en a besoin — ce que `verify.sh` délègue, il le délègue par un
/// appel qui est lui-même dans son texte. Élargir le corpus n'ajoutait donc
/// aucune couverture et une seule chose : le risque qu'un motif soit satisfait
/// par un fichier que `verify.sh` n'exécute pas sur ce chemin-là. C'est
/// exactement ce qui a failli arriver à « core › Test », dont le
/// `WISQ_LINUX_IMAGE` se trouvait dans `test-rust-core.sh`.
const LOCAL = read("scripts/verify.sh");

/// Chaque étape nommée qui exécute quelque chose, avec le job qui la porte.
/// Les `uses:` sont exclus : `actions/checkout` et consorts installent le
/// terrain, ils ne jugent rien.
function workflowSteps(path: string): { job: string; name: string }[] {
  const steps: { job: string; name: string }[] = [];
  let job = "";
  let pending: string | undefined;
  for (const line of read(path).split("\n")) {
    const jobLine = /^ {2}([\w-]+):\s*$/.exec(line);
    if (jobLine) job = jobLine[1]!;
    const uses = /^\s*- uses: /.exec(line);
    if (uses) {
      pending = undefined;
      continue;
    }
    const named = /^\s*- name: (.+?)\s*$/.exec(line);
    if (named) {
      pending = named[1];
      continue;
    }
    // `run:` peut suivre le nom après un bloc de commentaires ou un `env:`,
    // d'où le report plutôt qu'une lecture ligne à ligne.
    if (pending !== undefined && /^\s*run: /.test(line)) {
      steps.push({ job, name: pending });
      pending = undefined;
    }
  }
  return steps;
}

function everyStep(): { job: string; name: string }[] {
  return WORKFLOWS.flatMap(workflowSteps);
}

/// Le verdict porté sur chaque étape. `verify` est un motif que l'ensemble des
/// scripts locaux doit contenir ; `absent` est une raison de ne pas la lancer,
/// et elle doit être une raison, pas un haussement d'épaules.
type Verdict = { verify: RegExp } | { absent: string };

/// La clé est « job › étape », pas l'étape seule. Trois jobs portent une étape
/// nommée « Test » — `cargo test`, `swift test`, `bun test` — et les confondre
/// en une seule ligne aurait laissé deux portes sur trois sans verdict, dans un
/// fichier écrit exactement contre ça.
function key(step: { job: string; name: string }): string {
  return `${step.job} › ${step.name}`;
}

const GATES: Record<string, Verdict> = {
  // --- ci.yml, job « rust » ---------------------------------------------------
  "rust › Toolchain": { absent: "installe rustup et une cible ; ce n'est pas une porte" },
  "rust › Format": { verify: /cargo fmt --all --check/ },
  "rust › Clippy (strict)": { verify: /cargo clippy --all-targets --all-features -- -D warnings/ },
  "rust › Test": { verify: /cargo test --release/ },
  "rust › Build the agent, statically": {
    verify: /x86_64-unknown-linux-musl/,
  },

  // --- ci.yml, job « core » ---------------------------------------------------
  "core › Fetch Linux test kernel (best effort)": {
    absent: "télécharge l'image de noyau ; le script utilise celle qui est là",
  },
  "core › Make the agent runnable": { absent: "chmod sur un artefact que la CI seule transporte" },
  "core › Rust toolchain, et le cœur qu'elle construit": { verify: /cargo build --release/ },
  // `WISQ_AGENT_BINARY` et pas `WISQ_LINUX_IMAGE`, et c'est mesuré : la CI pose
  // les deux, `verify.sh` la première seulement, et les deux runs rendent le
  // même unique saut. Les cas de démarrage Linux lisent la variable *ou* se
  // rabattent sur le chemin bien connu, donc l'exiger ici aurait eu l'air de
  // combler un trou et n'en aurait comblé aucun. `WISQ_AGENT_BINARY`, lui, n'a
  // pas de repli : sans elle les tests inter-langages sautent.
  "core › Test": { verify: /WISQ_AGENT_BINARY="[^"]*" swift test/ },
  "core › Build (mode langage Swift 6)": { verify: /^swift build$/m },
  "core › Build sans cargo (l'échappatoire WISQ_SWIFT_CORE)": {
    verify: /WISQ_SWIFT_CORE=1 swift build/,
  },
  "core › Benchmark (boot to prompt)": { verify: /wisq-bench/ },
  "core › Les deux cœurs, comparés sur le même noyau": { verify: /test-rust-core\.sh/ },

  // --- ci.yml, job « core-apple » ---------------------------------------------
  "core-apple › Test (mode langage Swift 6)": {
    absent:
      "c'est le même `swift test`, sur macOS, pour le code derrière `canImport` — " +
      "ImageIO et Security n'existent pas sur Linux, donc rien à lancer ici",
  },

  // --- ci.yml, job « lint » ---------------------------------------------------
  "lint › Install SwiftLint": { absent: "installe l'outil ; verify.sh dit comment l'obtenir" },
  "lint › Lint": { verify: /swiftlint lint --strict/ },
  "lint › Check nothing claims a licence": { verify: /check-licence-claims\.sh/ },
  "lint › Check the published architectures match what the installer asks for": {
    verify: /check-release-matrix\.sh/,
  },

  // --- ci.yml, job « app » ----------------------------------------------------
  "app › Install XcodeGen": { absent: "installe l'outil ; verify.sh --app dit comment l'obtenir" },
  "app › Package the VM core as an XCFramework": { absent: "xcodebuild, donc macOS" },
  "app › Fetch the Linux test kernel": { absent: "télécharge l'image de noyau" },
  "app › Boot a real kernel through the Rust core, inside an iPhone": {
    absent: "simulateur iPhone, donc macOS et Xcode",
  },
  "app › Generate project": { verify: /xcodegen generate/ },
  "app › Run the app layer's tests in a simulated iPhone": {
    absent: "simulateur iPhone, donc macOS et Xcode",
  },
  "app › Ce que l'iPhone simulé a mesuré": {
    absent:
      "relit le fichier de mesures que le pas précédent a laissé ; sans " +
      "simulateur iPhone, verify.sh n'a rien à relire",
  },
  "app › Build for simulator": { verify: /xcodebuild build/ },
  "app › Build for simulator on the Swift core": {
    absent:
      "deuxième construction du simulateur, sur le cœur Swift ; verify.sh --app " +
      "n'en fait qu'une, et celle qui manque est déjà couverte sur Linux par " +
      "« Build sans cargo »",
  },
  "app › Build unsigned device app": {
    absent: "construction pour appareil réel, donc macOS et Xcode",
  },

  // --- site.yml ---------------------------------------------------------------
  "build › Install": { verify: /bun install --frozen-lockfile/ },
  "build › Typecheck": { verify: /bun run typecheck/ },
  "build › Build": { verify: /bun run build/ },
  "build › Test": { verify: /bun test/ },
  "build › Heroku build path (address resolved per request)": {
    verify: /npm run heroku-postbuild/,
  },
  "build › Heroku build path (address pinned)": { verify: /SITE_URL=/ },
};

describe("verify.sh lance ce que la CI lance", () => {
  /// La garde elle-même. Une étape ajoutée à un workflow et classée par
  /// personne fait rougir ceci — ce qui manquait les trois fois où la phrase
  /// « everything CI would run » s'est révélée fausse.
  test("chaque étape des workflows porte un verdict", () => {
    const unclassified = everyStep()
      .filter((step) => !(key(step) in GATES))
      .map(key);
    expect(
      unclassified,
      "des étapes de la CI que personne n'a classées : soit verify.sh les lance, " +
        "soit dites pourquoi il ne peut pas",
    ).toEqual([]);
  });

  /// Et l'inverse : une entrée qui ne correspond plus à rien laisserait croire
  /// qu'une porte est couverte alors qu'elle a disparu.
  test("aucun verdict ne porte sur une étape qui n'existe plus", () => {
    const names = new Set(everyStep().map(key));
    expect(Object.keys(GATES).filter((name) => !names.has(name))).toEqual([]);
  });

  /// Ce que le tableau affirme de `verify.sh` doit être vrai de `verify.sh`.
  test.each(
    Object.entries(GATES).filter(
      (entry): entry is [string, { verify: RegExp }] => "verify" in entry[1],
    ),
  )("« %s » est bien lancé localement", (name, verdict) => {
    expect(
      verdict.verify.test(LOCAL),
      `le tableau dit que verify.sh lance « ${name} », et ${verdict.verify} ne s'y trouve pas`,
    ).toBe(true);
  });

  /// L'autre bord. Le tableau ne doit pas devenir un moyen de faire passer une
  /// porte sous silence : une case « absent » sans raison en serait un.
  test.each(
    Object.entries(GATES).filter(
      (entry): entry is [string, { absent: string }] => "absent" in entry[1],
    ),
  )("« %s » dit pourquoi elle n'est pas lancée localement", (_name, verdict) => {
    expect(verdict.absent.length).toBeGreaterThan(20);
  });
});

describe("le lecteur peut échouer", () => {
  /// Un lecteur dont le motif cesse de correspondre ne rend rien, et rien
  /// satisfait toutes les assertions ci-dessus : zéro étape non classée, zéro
  /// entrée périmée. Ce fichier existe à cause de gardes qui ne pouvaient pas
  /// échouer, et il ne va pas en devenir une.
  test("les deux workflows rendent des étapes, et en nombre plausible", () => {
    for (const path of WORKFLOWS) {
      expect(workflowSteps(path).length, `${path} ne rend plus aucune étape`).toBeGreaterThan(4);
    }
    expect(everyStep().length).toBe(Object.keys(GATES).length);
  });

  /// Les cinq jobs de ci.yml et le job du site sont tous représentés : un
  /// lecteur qui perdrait un job entier passerait les tests ci-dessus en ne
  /// lisant que les autres.
  test("chaque job des workflows a au moins une étape lue", () => {
    const jobs = new Set(everyStep().map((step) => step.job));
    expect([...jobs].sort()).toEqual(["app", "build", "core", "core-apple", "lint", "rust"]);
  });

  /// Et les scripts locaux sont réellement lus : un chemin faux rendrait une
  /// chaîne vide, et chaque motif ci-dessus échouerait pour la mauvaise raison.
  test("les scripts locaux sont lus, et ne sont pas vides", () => {
    expect(LOCAL.length).toBeGreaterThan(4000);
    expect(LOCAL).toContain("Everything CI would run, in one command");
  });
});
