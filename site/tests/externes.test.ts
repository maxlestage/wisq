/// **Un `instanceof` sur un nom que nous avons inventé ne reconnaît jamais rien.**
///
/// `wasm-bindgen` permet de déclarer un type JavaScript que `web-sys` ne nomme
/// pas — un événement non normalisé, par exemple :
///
/// ```rust
/// #[wasm_bindgen]
/// extern "C" {
///     #[wasm_bindgen(extends = web_sys::Event)]
///     pub type Retenue;
/// }
/// ```
///
/// Et `dyn_into::<Retenue>()` a toute l'apparence de la prudence : un
/// transtypage vérifié, un `Result`, un chemin d'échec propre. **C'est un mur.**
/// Pour un type externe, `wasm-bindgen` engendre un `instanceof` sur un
/// identifiant du **même nom** — mesuré, dans la colle livrée :
///
/// ```js
/// __wbg_instanceof_Retenue_e48387fb2781baa8: function(arg0) {
///     try { result = getObject(arg0) instanceof Retenue; } catch (_) { result = false; }
/// ```
///
/// Aucun navigateur ne définit `Retenue`. Le `try/catch` rend donc `false` à
/// chaque appel, partout, et tout ce qui dépend de la reconnaissance est
/// inatteignable — du code mort déguisé en sûreté. Ça s'est produit ici, sur
/// l'invite d'installation, et seul un test qui appuyait sur le bouton l'a dit.
///
/// **Pourquoi la question est « l'avons-nous inventé ? » et pas « le DOM de test
/// connaît-il ce nom ? ».** La seconde semblait plus simple et elle est fausse,
/// et c'est mesuré : la colle livrée reconnaît **dix-sept** noms, dont
/// `CanvasRenderingContext2D`, que happy-dom ne définit pas et qui est pourtant
/// une vraie classe de navigateur. Interroger l'environnement de test refuserait
/// donc un `instanceof` parfaitement bon. Ce qui distingue le mur, ce n'est pas
/// que le nom manque **ici** : c'est qu'il n'existe **nulle part**, parce que
/// c'est nous qui l'avons écrit.
///
/// **Et nommer la vraie classe ne sauve pas** : `js_name = BeforeInstallPromptEvent`
/// ferait reconnaître une classe que seul Chromium définit, donc un refus
/// silencieux dans tous les autres navigateurs. Les `js_name` d'un bloc externe
/// sont donc comptés comme les noms de types.
///
/// **Ce bloc est vide aujourd'hui** — le front passe par `js_sys::Reflect::get`
/// et transtype vers `js_sys::Function` et `js_sys::Promise`, qui sont de vrais
/// globaux. Cette garde est donc écrite **une tranche en avance**, et c'est
/// précisément pour ça que le second test existe : une garde dont l'entrée est
/// vide n'a encore rien refusé, donc elle doit le faire devant un arbre
/// fabriqué pour être fautif.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

/// Tous les `.rs` sous `crates/`, en profondeur.
function sources(racine: string): string[] {
  const dir = join(racine, "crates");
  const marche = (ou: string): string[] =>
    readdirSync(ou, { withFileTypes: true }).flatMap((e) =>
      e.isDirectory()
        ? marche(join(ou, e.name))
        : e.name.endsWith(".rs")
          ? [join(ou, e.name)]
          : [],
    );
  return statSync(dir).isDirectory() ? marche(dir) : [];
}

/// **Les noms que ce dépôt déclare lui-même à wasm-bindgen.**
///
/// Seuls les blocs `extern "C" { … }` comptent, et seulement ceux qu'un
/// `#[wasm_bindgen]` attribue : `pub unsafe extern "C" fn` du C ABI n'ouvre pas
/// de bloc, donc le motif ne le voit pas — vérifié, `crates/wisq-vm/src/ffi.rs`
/// en porte trente-six et aucune n'est comptée.
export function typesInventes(racine: string): string[] {
  const noms = new Set<string>();
  for (const fichier of sources(racine)) {
    const texte = readFileSync(fichier, "utf8");
    for (const ouverture of [...texte.matchAll(/extern\s+"C"\s*\{/g)]) {
      const avant = texte.slice(Math.max(0, ouverture.index - 160), ouverture.index);
      if (!avant.includes("wasm_bindgen")) continue;
      // Le corps du bloc, par comptage d'accolades : un `{` de plus dans une
      // signature ne doit pas faire finir le bloc trop tôt.
      let profondeur = 1;
      let i = ouverture.index + ouverture[0].length;
      for (; i < texte.length && profondeur > 0; i += 1) {
        if (texte[i] === "{") profondeur += 1;
        else if (texte[i] === "}") profondeur -= 1;
      }
      const corps = texte.slice(ouverture.index, i);
      for (const m of corps.matchAll(/\btype\s+([A-Za-z_$][A-Za-z0-9_$]*)/g)) noms.add(m[1]!);
      for (const m of corps.matchAll(/\bjs_name\s*=\s*([A-Za-z_$][A-Za-z0-9_$]*)/g)) noms.add(m[1]!);
    }
  }
  return [...noms].sort();
}

/// Les noms que la colle livrée reconnaît par `instanceof`.
export function nomsReconnus(dist: string): string[] {
  const noms = new Set<string>();
  for (const entree of readdirSync(dist)) {
    if (!entree.endsWith(".js")) continue;
    const texte = readFileSync(join(dist, entree), "utf8");
    for (const m of texte.matchAll(/instanceof\s+([A-Za-z_$][A-Za-z0-9_$]*)/g)) noms.add(m[1]!);
  }
  return [...noms].sort();
}

/// Les murs : un nom à la fois inventé par nous et interrogé par `instanceof`.
export function murs(racine: string, dist: string): string[] {
  const inventes = new Set(typesInventes(racine));
  return nomsReconnus(dist).filter((nom) => inventes.has(nom));
}

describe("la colle ne reconnaît aucun nom que nous aurions inventé", () => {
  test("sur ce dépôt", () => {
    const dist = join(import.meta.dir, "..", "dist");
    // **Et la colle est bien lue.** Sans cette ligne, un `dist` absent ou vide
    // ferait passer l'assertion ci-dessous pour la pire des raisons : zéro nom
    // reconnu, donc zéro mur, donc vert. Mesuré : la colle livrée reconnaît
    // dix-sept noms.
    expect(
      nomsReconnus(dist).length,
      "aucun « instanceof » dans dist : la construction n'a pas tourné (bun run build)",
    ).toBeGreaterThan(0);

    const trouves = murs(repoRoot, dist);
    expect(
      trouves,
      `la colle fait « instanceof » sur un type que ce dépôt déclare lui-même :`
        + ` ${trouves.join(", ")} — aucun navigateur ne définit ce nom, donc la`
        + ` reconnaissance rend toujours faux et tout ce qui en dépend est mort.`
        + ` Passer par js_sys::Reflect::get et transtyper vers un type de js_sys.`,
    ).toEqual([]);
  });

  /// **L'acte, pas son empreinte.** Le bloc est vide sur ce dépôt, donc le test
  /// ci-dessus ne refuserait rien aujourd'hui quoi qu'il arrive. Celui-ci
  /// construit un arbre fautif et exige le refus — c'est la seule façon de
  /// savoir que la garde en est une.
  test("devant un arbre qui porte la faute", () => {
    const racine = mkdtempSync(join(tmpdir(), "wisq-externes-"));
    try {
      mkdirSync(join(racine, "crates", "faux", "src"), { recursive: true });
      writeFileSync(
        join(racine, "crates", "faux", "src", "lib.rs"),
        [
          "#[wasm_bindgen]",
          'extern "C" {',
          "    #[wasm_bindgen(extends = web_sys::Event)]",
          "    pub type Retenue;",
          "    #[wasm_bindgen(method, js_name = prompt)]",
          "    pub fn invite(this: &Retenue) -> js_sys::Promise;",
          "}",
          "",
          "// Et une fonction du C ABI, qui ne doit PAS être comptée.",
          'pub unsafe extern "C" fn faux_vm_new() -> i32 { 0 }',
        ].join("\n"),
      );
      const dist = join(racine, "dist");
      mkdirSync(dist);
      writeFileSync(
        join(dist, "colle.js"),
        "function a(x){ return x instanceof Retenue; }\n"
          + "function b(x){ return x instanceof Element; }\n",
      );

      // Le type est vu, et `js_name = prompt` avec lui — une méthode nommée
      // compte autant qu'un type, parce qu'un `js_name` sur le type lui-même
      // ferait reconnaître une classe qui n'existe que dans un navigateur.
      expect(typesInventes(racine)).toEqual(["Retenue", "prompt"]);
      // La fonction du C ABI n'ouvre pas de bloc, donc elle n'est pas comptée.
      expect(typesInventes(racine)).not.toContain("faux_vm_new");
      // Et `Element`, qui vient de web-sys, n'est pas des nôtres.
      expect(murs(racine, dist)).toEqual(["Retenue"]);
    } finally {
      rmSync(racine, { recursive: true, force: true });
    }
  });
});
