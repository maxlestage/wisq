/// **Le vrai module, dans la vraie page construite.**
///
/// Les deux fichiers qui exercent le front — `hydration.test.ts` pour les îlots
/// et les comportements, `mouvement.test.ts` pour le mouvement — ont besoin des
/// mêmes gestes : poser une page de `dist` dans un DOM, adapter les deux
/// reconnaissances que happy-dom ne fait pas, et démarrer **une instance
/// neuve** du module. Ils vivent ici, une fois.
///
/// **Une instance neuve par page, et c'est la requête qui la donne.** Le
/// module s'initialise une fois par instance : `start` tourne, hydrate les
/// îlots de la page, et ne rejoue rien ensuite. `bun test` charge tous les
/// fichiers dans un même processus ; sans une adresse propre à chaque page, la
/// seconde importation rendrait la première instance, déjà démarrée sur un
/// autre document.

import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

export const dist = join(import.meta.dir, "..", "dist");

/// Les deux fichiers du front, trouvés sur l'artefact : leurs noms portent une
/// empreinte de contenu, donc personne ne peut les écrire.
export function front(): { glue: string; wasm: string } {
  const noms = readdirSync(dist).filter((n) => n.startsWith("wisq-"));
  const glue = noms.filter((n) => n.endsWith(".js"));
  const wasm = noms.filter((n) => n.endsWith(".wasm"));
  if (glue.length !== 1 || wasm.length !== 1) {
    throw new Error(`front : ${glue.length} colle(s) et ${wasm.length} wasm, il en faut un de chaque`);
  }
  return { glue: join(dist, glue[0]!), wasm: join(dist, wasm[0]!) };
}

/// **Le seul endroit où les tests adaptent l'environnement, et pourquoi.**
///
/// `web_sys::window()` n'est pas « lire `globalThis.window` » : wasm-bindgen
/// l'implémente par `js_sys::global().dyn_into::<Window>()`, c'est-à-dire un
/// `instanceof` sur l'objet global lui-même. Dans un navigateur c'est la même
/// chose, `globalThis === window`. Sous Bun, happy-dom pose ses propriétés
/// **sur** le global de Bun : `window` et `document` existent, mais
/// `globalThis instanceof Window` est faux — et `document instanceof Document`
/// aussi, alors que `documentElement instanceof Element` est vrai. Relevé
/// constructeur par constructeur, en #332.
///
/// L'adaptation porte exactement sur ces deux reconnaissances, et sur rien
/// d'autre : aucun comportement n'est simulé, aucun appel n'est intercepté.
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

export interface Ouverture {
  /// Ce que le lecteur a déjà mémorisé en arrivant.
  stockage?: Record<string, string>;
  /// `prefers-reduced-motion: reduce`.
  calme?: boolean;
  /// Ce qui doit être en place avant que le module ne démarre : un
  /// observateur maîtrisé, une langue de navigateur, une hauteur de page.
  avant?: () => void;
}

let instance = 0;

/// Pose une page construite dans un DOM neuf, et démarre le module dessus.
///
/// Les `<script>` et la feuille de style sont retirés : le module est importé
/// par le test plutôt que cherché par le document, et un DOM qui tente une
/// requête réseau enterre le résultat sous des erreurs DNS sur un coureur sans
/// route. Aucune assertion ne dépend d'un style calculé.
export async function ouvrir(fichier: string, options: Ouverture = {}) {
  if (GlobalRegistrator.isRegistered) await GlobalRegistrator.unregister();
  GlobalRegistrator.register({
    url: `https://example.test/${fichier.replace(/index\.html$/, "")}`,
    settings: { device: { prefersReducedMotion: options.calme ? "reduce" : "no-preference" } },
  } as Parameters<typeof GlobalRegistrator.register>[0]);
  adapterLeGlobal();
  localStorage.clear();
  sessionStorage.clear();
  for (const [cle, valeur] of Object.entries(options.stockage ?? {})) {
    localStorage.setItem(cle, valeur);
  }

  const html = readFileSync(join(dist, fichier), "utf8")
    .replace(/<script[\s\S]*?<\/script>/g, "")
    .replace(/<link[^>]+rel="(?:stylesheet|modulepreload|preload)"[^>]*>/g, "");
  document.documentElement.innerHTML = html
    .replace(/[\s\S]*<html[^>]*>/, "")
    .replace(/<\/html>[\s\S]*/, "");

  options.avant?.();

  const { glue, wasm } = front();
  instance += 1;
  const module = await import(`${glue}?instance=${instance}`);
  await module.default({ module_or_path: readFileSync(wasm) });
}

export async function fermer() {
  if (GlobalRegistrator.isRegistered) await GlobalRegistrator.unregister();
}

/// Laisse tourner les tâches en attente. L'hydratation de Yew et ses effets ne
/// sont pas synchrones.
const souffler = () => new Promise((r) => setTimeout(r, 0));

/// **Attendre une condition, pas un délai.** La première version de
/// `hydration.test.ts` soufflait deux tours de boucle et elle est passée, puis
/// elle est tombée sur des sources identiques : c'était une course, gagnée une
/// fois. On attend que la chose soit observable, avec une borne, et le
/// dépassement **nomme** ce qu'on attendait.
export async function jusqua(condition: () => boolean, quoi: string, tours = 400) {
  for (let tour = 0; tour < tours; tour += 1) {
    if (condition()) return;
    await souffler();
  }
  throw new Error(`délai dépassé en attendant : ${quoi}`);
}

/// **Un vrai `MouseEvent`, et non `element.click()`.** Le gestionnaire du
/// composant reçoit un `MouseEvent` : c'est ce que Yew transtype avant de
/// l'appeler, et un transtypage qui échoue dans un module compilé avec
/// `panic = "abort"` n'échoue pas à moitié — il emporte le module.
export function cliquer(element: Element) {
  element.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
}
