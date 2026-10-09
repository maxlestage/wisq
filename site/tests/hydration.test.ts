/// **Ce que le module WebAssembly fait réellement dans un document.**
///
/// Tous les autres tests du front en Yew mesurent la *construction* : que le
/// module soit émis, qu'il pèse ce qu'il doit, qu'il soit précaché, que la page
/// l'importe, que son balisage pré-rendu soit le bon. Aucun ne disait qu'il
/// **arrive** — et c'est la première leçon de ce dépôt : un test qui vérifie
/// qu'une chose se construit ne dit rien de son arrivée.
///
/// Le trou était réel et il a été publié. En portant la première page, la
/// bascule de thème est passée de `src/main.ts` au module Yew, et `main.ts`
/// s'effaçait alors en bloc sur les pages portées. Résultat : la page `offline`
/// a été publiée avec un thème dont aucun test n'exerçait le clic, et — pire —
/// sans son invite d'installation ni ses révélations, parce que ces trois
/// comportements-là n'étaient pas portés du tout. Trois morts silencieuses.
///
/// Ce fichier charge donc le vrai module, dans le vrai document construit, et
/// appuie sur les boutons.
///
/// **Et il charge aussi `src/main.ts`, parce que c'est la page qui compte, pas
/// le module.** Une page portée est tenue par deux moitiés : ce que Yew possède
/// déjà, et ce que le script possède encore. Mesurer la première seule est
/// exactement l'erreur qui a publié la page `offline` sans son invite
/// d'installation — les tests du module étaient verts, ceux du script
/// regardaient une autre page, et personne ne regardait *celle-ci*. Les quatre
/// comportements sont donc exercés ici **ensemble**, sur la page portée, quel
/// que soit celui des deux qui les porte. Le jour où un comportement passe de
/// l'un à l'autre, ce fichier ne change pas : il tombe si le comportement
/// disparaît, et c'est tout ce qu'on lui demande.
///
/// **Comment le wasm tourne ici.** La colle de wasm-bindgen cherche son `.wasm`
/// par `fetch` relatif à sa propre adresse ; sous Bun, le `fetch` de happy-dom
/// refuse le schéma `file:` — mesuré, « URL scheme "file" is not supported ».
/// L'export par défaut accepte aussi les octets directement, ce qui évite
/// `fetch` entièrement et n'a pas besoin de réseau sur un coureur de CI.
///
/// **Un seul scénario, et c'est contraint.** Le module s'initialise une fois par
/// processus : un second appel rend la main sans rejouer le démarrage. Les
/// assertions sont donc ordonnées comme les gestes d'un lecteur — il arrive avec
/// un choix mémorisé, clique « sombre », puis revient à « automatique » — plutôt
/// que découpées en trois tests dont deux ne pourraient pas hydrater.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const dist = join(import.meta.dir, "..", "dist");

/// Les deux fichiers du front, trouvés sur l'artefact : leurs noms portent une
/// empreinte de contenu, donc personne ne peut les écrire.
function front(): { glue: string; wasm: string } {
  const noms = readdirSync(dist).filter((n) => n.startsWith("wisq-"));
  const glue = noms.filter((n) => n.endsWith(".js"));
  const wasm = noms.filter((n) => n.endsWith(".wasm"));
  if (glue.length !== 1 || wasm.length !== 1) {
    throw new Error(`front : ${glue.length} colle(s) et ${wasm.length} wasm, il en faut un de chaque`);
  }
  return { glue: join(dist, glue[0]!), wasm: join(dist, wasm[0]!) };
}

/// La première page que la construction a hydratée en Yew. Lue sur l'artefact
/// plutôt que nommée ici : `crates/wisq-site/src/pages.rs` décide, et une
/// seconde liste serait une copie.
function premierePageYew(): string {
  const parcours = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
      e.isDirectory() ? parcours(join(dir, e.name)) : e.name.endsWith(".html") ? [join(dir, e.name)] : [],
    );
  const portees = parcours(dist).filter((f) =>
    readFileSync(f, "utf8").includes('data-hydrate="yew"'),
  );
  if (portees.length === 0) throw new Error("aucune page hydratée en Yew dans dist");
  return portees.sort()[0]!;
}

/// Laisse tourner les tâches en attente. L'hydratation de Yew et ses effets ne
/// sont pas synchrones : sans ça, on lirait le balisage pré-rendu et on
/// croirait avoir mesuré le module.
const souffler = () => new Promise((r) => setTimeout(r, 0));

/// **Attendre une condition, pas un délai — et la première version attendait un
/// délai.**
///
/// Elle soufflait deux fois après le démarrage et une fois après chaque clic, et
/// elle est passée. Puis elle est tombée, sur des sources identiques, parce que
/// Yew rattache ses gestionnaires après l'hydratation et que deux tours de
/// boucle d'événements ne sont pas une garantie : c'était une course, gagnée une
/// fois. Un test qui gagne une course n'a rien mesuré.
///
/// Donc on attend que la chose soit observable, avec une borne, et le
/// dépassement **nomme** ce qu'on attendait plutôt que de rendre un échec
/// d'assertion qui ferait croire à un défaut du module.
/// **Un vrai `MouseEvent`, et non `element.click()`.**
///
/// Le gestionnaire du composant reçoit un `MouseEvent` : c'est ce que Yew
/// transtype avant de l'appeler. `HTMLElement.click()` de happy-dom ne dispatche
/// pas forcément cette classe-là, et un transtypage qui échoue dans un module
/// compilé avec `panic = "abort"` n'échoue pas à moitié — il emporte le module,
/// donc les clics suivants ne font rien non plus. Dispatcher l'événement que le
/// navigateur dispatche enlève la question.
function cliquer(choix: string) {
  const bouton = document.querySelector<HTMLButtonElement>(`[data-theme-choice="${choix}"]`);
  if (!bouton) throw new Error(`aucun bouton de thème « ${choix} »`);
  bouton.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
}

async function jusqua(condition: () => boolean, quoi: string) {
  for (let tour = 0; tour < 200; tour += 1) {
    if (condition()) return;
    await souffler();
  }
  throw new Error(`délai dépassé en attendant : ${quoi}`);
}

/// **Le seul endroit où ce test adapte l'environnement, et pourquoi.**
///
/// `web_sys::window()` n'est pas « lire `globalThis.window` » : wasm-bindgen
/// l'implémente par `js_sys::global().dyn_into::<Window>()`, c'est-à-dire un
/// `instanceof` sur l'objet global lui-même. Dans un navigateur c'est la même
/// chose, `globalThis === window`. Sous Bun, happy-dom pose ses propriétés
/// **sur** le global de Bun : `window` et `document` existent, `#root` est là —
/// mesuré — mais `globalThis instanceof Window` est faux, donc `window()` rend
/// `None` et le module refuse avec « aucun document ». Son refus est juste ; ce
/// qui est faux, c'est l'environnement.
///
/// **Deux reconnaissances manquent, et les deux ont été relevées, pas devinées.**
///
///   - `globalThis instanceof Window` est **faux** : d'où `window()` à `None`.
///   - `document instanceof Document` est **faux** aussi, alors que
///     `documentElement instanceof Element` est vrai — relevé constructeur par
///     constructeur. C'est ce second écart qui faisait que la bascule mémorisait
///     le choix sans poser `data-theme` : `local_storage()` n'a pas besoin de
///     `Document` et marchait, `document_element()` en a besoin et rendait
///     `None`. Le module prenait sa sortie de secours — correctement — et le
///     test lisait un attribut absent.
///
/// L'adaptation porte donc exactement sur ces deux reconnaissances, et sur rien
/// d'autre : aucun comportement n'est simulé, aucun appel n'est intercepté. Tout
/// ce que le test mesure ensuite est le vrai DOM et le vrai module. Et elle ne
/// peut pas masquer un échec : si elle ne suffisait pas, le module refuserait ou
/// se tairait, comme il vient de le faire deux fois.
function adapterLeGlobal() {
  const g = globalThis as Record<string, unknown>;
  const reconnaitre = (nom: string, est: (objet: unknown) => boolean) => {
    const classe = g[nom] as (new () => unknown) | undefined;
    if (!classe) throw new Error(`happy-dom n'a pas posé de constructeur ${nom}`);
    Object.defineProperty(classe, Symbol.hasInstance, { configurable: true, value: est });
  };
  reconnaitre("Window", (o) => o === globalThis || o === g.window);
  reconnaitre("Document", (o) => o === g.document);
}

let page: string;

beforeAll(async () => {
  page = premierePageYew();
  const html = readFileSync(page, "utf8")
    // Le document n'a pas à aller chercher la feuille de style ni les scripts :
    // le module est importé par ce test, et un DOM qui tente une requête réseau
    // enterre le résultat sous des erreurs DNS sur un coureur sans route.
    .replace(/<script[\s\S]*?<\/script>/g, "")
    .replace(/<link[^>]+rel="stylesheet"[^>]*>/g, "");

  GlobalRegistrator.register({ url: "https://example.test/" });
  adapterLeGlobal();
  localStorage.clear();
  // Le lecteur arrive avec un choix déjà mémorisé : c'est le cas que le rendu
  // pré-rendu ne peut pas connaître, et que l'effet doit corriger.
  localStorage.setItem("wisq.theme", "dark");

  document.documentElement.innerHTML = html
    .replace(/[\s\S]*<html[^>]*>/, "")
    .replace(/<\/html>[\s\S]*/, "");

  // **L'ordre de la vraie page.** Le script du site est un module ES que le
  // document charge avant la colle du wasm ; l'inverse ferait courir
  // l'hydratation contre un document que le script n'a pas encore touché, et
  // mesurerait un ordre qui n'existe nulle part.
  //
  // La requête donne à ce fichier **sa propre** évaluation du script.
  // `bun test` charge tous les fichiers de test dans un même processus, et
  // `behaviour.test.ts` importe le même module pour une autre page ; sans elle,
  // le second à passer hériterait du travail que le premier a fait sur un autre
  // document. C'est aussi la seule forme que `tsc` accepte pour un chemin en
  // `.ts` — mesuré : le chemin littéral rend TS5097.
  await import(`../src/main.ts?portee=${encodeURIComponent(page)}`);

  const { glue, wasm } = front();
  const module = await import(glue);
  await module.default({ module_or_path: readFileSync(wasm) });
});

afterAll(async () => {
  await GlobalRegistrator.unregister();
});

test("le module hydraté tient la bascule de thème", async () => {
  // **Les nœuds sont relus à chaque fois, et c'est la correction d'un défaut.**
  //
  // Le premier jet capturait la liste des boutons au début du test, c'est-à-dire
  // avant que l'hydratation n'ait eu lieu, et cliquait ensuite sur ces nœuds-là.
  // L'hydratation de Yew réutilise le balisage quand il correspond et le
  // remplace sinon : une liste prise trop tôt peut donc tenir des nœuds
  // détachés, sur lesquels un clic ne remonte nulle part. Mesuré — le module
  // posait bien `data-theme`, relu `Some("light")` depuis le Rust, pendant que
  // le test lisait `null` sur ses nœuds d'avant.
  const boutons = () => [...document.querySelectorAll("[data-theme-choice]")] as HTMLButtonElement[];
  expect(boutons().length, `${page} : aucun bouton de thème`).toBe(3);

  const presse = () =>
    boutons()
      .filter((b) => b.getAttribute("aria-pressed") === "true")
      .map((b) => b.dataset.themeChoice);

  // **Le choix mémorisé est celui qui apparaît pressé.** Le balisage part avec
  // `auto` — la seule réponse juste avant d'avoir lu le stockage — et l'effet
  // le corrige. Si l'hydratation n'avait pas eu lieu, on lirait encore `auto`,
  // et c'est précisément ce que ce test existe pour distinguer.
  // **La condition attend le changement, pas un état.** Le premier jet attendait
  // « un bouton pressé », ce que le balisage pré-rendu satisfait déjà avec
  // `auto` : l'attente rendait la main avant que l'effet n'ait tourné, et le
  // test lisait le pré-rendu en croyant lire le module. C'est l'attente bornée
  // qui porte l'assertion — si l'effet ne relit jamais le choix, elle dépasse
  // son délai et le dit en nommant ce qu'elle attendait.
  await jusqua(
    () => presse()[0] === "dark",
    "que l'effet du module relise le choix mémorisé et déplace l'état pressé",
  );
  expect(presse(), "le choix mémorisé n'est pas celui qui est pressé").toEqual(["dark"]);

  // Un clic applique, mémorise, et déplace l'état pressé.
  cliquer("light");
  await jusqua(
    () => document.documentElement.hasAttribute("data-theme"),
    "que le clic pose data-theme",
  );
  expect(document.documentElement.getAttribute("data-theme")).toBe("light");
  expect(localStorage.getItem("wisq.theme")).toBe("light");
  expect(presse()).toEqual(["light"]);

  // **`auto` retire la valeur au lieu de stocker « auto ».** Un `auto` stocké
  // n'est pas un choix : c'est l'absence de choix, et les confondre empêcherait
  // de distinguer « suis le système » de « on n'a rien lu encore ».
  cliquer("auto");
  await jusqua(
    () => !document.documentElement.hasAttribute("data-theme"),
    "que le retour à « automatique » retire data-theme",
  );
  expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
  expect(localStorage.getItem("wisq.theme")).toBeNull();
  expect(presse()).toEqual(["auto"]);
});

// --- ce que le script possède encore, sur cette même page ---------------------
//
// Les trois qui suivent ne sont pas portés en Yew aujourd'hui : `src/main.ts`
// les tient. Ils sont exercés **ici**, sur la page portée, et non dans
// `behaviour.test.ts` qui regarde l'accueil — parce que c'est exactement cette
// distinction qui a manqué. Le jour où l'un d'eux passera en Yew, rien ici ne
// changera : le test demande que le comportement existe, pas qui le porte.

test("la page portée garde la mémoire du choix de langue", () => {
  const lien = document.querySelector<HTMLAnchorElement>('.lang-switch a[hreflang="fr"]');
  if (!lien) throw new Error(`${page} : aucun lien de langue vers le français`);
  lien.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  expect(localStorage.getItem("wisq.lang")).toBe("fr");
});

test("la page portée garde son invite d'installation", async () => {
  const banniere = document.querySelector<HTMLElement>("[data-install]");
  if (!banniere) throw new Error(`${page} : aucune invite d'installation`);
  expect(banniere.hasAttribute("hidden"), "l'invite se montre sans qu'on la propose").toBe(true);

  // L'événement que Chromium envoie, avec ce que le code en attend : il le
  // retient pour le rejouer sur un geste, donc les deux membres doivent être là.
  const evenement = new Event("beforeinstallprompt") as Event & {
    prompt: () => Promise<void>;
    userChoice: Promise<{ outcome: string }>;
  };
  evenement.prompt = async () => {};
  evenement.userChoice = Promise.resolve({ outcome: "accepted" });
  window.dispatchEvent(evenement);
  await jusqua(
    () => !banniere.hasAttribute("hidden"),
    "que `beforeinstallprompt` révèle l'invite",
  );

  expect(
    document.querySelector('[data-install-variant="prompt"]')!.hasAttribute("hidden"),
    "la formulation de Chromium reste masquée",
  ).toBe(false);
  // Ce lecteur n'est pas sur iOS : lui dire de toucher un bouton Partager qu'il
  // n'a pas serait pire que de se taire.
  expect(
    document.querySelector('[data-install-variant="ios"]')!.hasAttribute("hidden"),
    "la formulation iOS est montrée à qui n'est pas sur iOS",
  ).toBe(true);

  document
    .querySelector<HTMLButtonElement>("[data-install-dismiss]")!
    .dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  await jusqua(
    () => banniere.hasAttribute("hidden"),
    "que le renvoi masque l'invite",
  );
  expect(localStorage.getItem("wisq.install.dismissed")).toBe("1");
});

/// **Le mouvement, et surtout sa règle.** Rien n'est masqué par la feuille de
/// style seule : les règles qui masquent vivent toutes sous `[data-motion]`, que
/// ce comportement est seul à poser. Donc le mesurer, c'est mesurer deux choses
/// d'un coup — que les révélations arrivent, et qu'une page sans elles n'a rien
/// d'invisible.
test("la page portée se révèle au défilement, et le dit sur la racine", () => {
  expect(
    document.documentElement.dataset.motion,
    "sans `data-motion`, les règles qui masquent ne s'appliquent pas — et rien ne se lève",
  ).toBe("on");
  expect(document.documentElement.style.getPropertyValue("--rise")).not.toBe("");

  const blocs = [...document.querySelectorAll(".doc > .wrap > *")];
  expect(blocs.length, `${page} : aucun bloc de document à révéler`).toBeGreaterThan(0);
  for (const bloc of blocs) {
    expect(
      (bloc as HTMLElement).dataset.reveal,
      `un bloc de ${page} n'est pas inscrit auprès de l'observateur`,
    ).toBe("");
  }

  // La barre de progression n'existe que là où quelque chose peut la remplir,
  // c'est-à-dire sur une page écrite — et celle-ci en est une.
  expect(document.querySelector(".reading-progress"), "la barre de lecture manque").not.toBeNull();
});
