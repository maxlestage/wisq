// **La boucle hôte du bureau local, celle qui vivra dans la vue.**
//
// La feuille de route l'établit et il faut le relire avant de toucher à ce
// fichier : le bureau local n'est pas « l'application qui pilote un module »,
// c'est **la machine qui vit dans la vue**. La RAM de l'invité *est* la
// mémoire linéaire du module, adresse pour adresse ; cette mémoire vit dans le
// processus de contenu de WebKit, et une application ne la partage pas. Ce qui
// reprend après un retour de main doit la lire — donc ce qui reprend vit ici,
// pas dans l'application.
//
// Ce que l'application fournit : **la traduction**. Elle seule porte
// l'émetteur, en Rust, derrière `wisq_x86_emit_region`. Elle est donc passée
// en paramètre, et elle est **asynchrone** : dans l'application c'est un
// aller-retour par message vers le processus hôte, pas un appel. Écrire la
// boucle avec un traducteur synchrone aurait donné du code à jeter.
//
// Ce fichier est du JavaScript sans dépendance et sans module bundler : il est
// destiné à être évalué tel quel dans un `WKWebView`, et il se teste ici sous
// Bun, qui embarque le même JavaScriptCore.

/// Les emplacements des globales, tels que l'émetteur les numérote. Ils sont
/// **répétés ici** au lieu d'être importés, parce que rien ne traverse la
/// frontière entre Rust et cette vue à part des octets. Le test les compare aux
/// constantes de la bibliothèque, sinon la répétition finirait par mentir.
export const SLOTS = {
  rip: 17,
  globalCount: 29,
  tablePages: 16,
  tableEntry: 16,
  tableSlots: 1 << 16,
  mix: 0x9e3779b97f4a7c15n,
};

/// La case d'une adresse : le même calcul que `table_slot` côté Rust et que
/// celui gravé dans les octets du module. **Les trois doivent tomber d'accord**
/// ou rien n'est jamais trouvé — un défaut muet, qui ne coûte que de la
/// vitesse, et c'est pourquoi un test les compare.
export function tableSlot(address) {
  const bits = 31 - Math.clz32(SLOTS.tableSlots);
  return Number(BigInt.asUintN(64, address * SLOTS.mix) >> BigInt(64 - bits));
}

/// **Construire la machine.**
///
/// - `translate(address, slot)` rend les octets d'un module pour la région qui
///   commence là, ou `null` si l'émetteur refuse. Elle peut rendre une
///   promesse.
///
///   **L'emplacement fait partie de la demande**, et ce n'est pas un détail :
///   les blocs d'une région se posent dans la table commune à partir de là, et
///   c'est la vue qui sait où il reste de la place. Une région compilée pour
///   un autre emplacement écraserait les blocs de sa voisine, en silence.
/// - `pages` est la RAM de l'invité, **en pages de 64 Kio et en puissance de
///   deux** : c'est ce qui permet de replier les adresses invitées et de poser
///   la correspondance au-dessus, hors de portée.
export function machine({ translate, pages, regions = 4096 }) {
  if (!Number.isInteger(pages) || pages <= 0 || (pages & (pages - 1)) !== 0) {
    throw new Error(`la RAM doit être une puissance de deux, pas ${pages}`);
  }
  const memory = new WebAssembly.Memory({ initial: pages + SLOTS.tablePages });
  const blocks = new WebAssembly.Table({ element: "anyfunc", initial: regions });
  const globals = [];
  const env = { mem: memory, blocks };
  for (let slot = 0; slot < SLOTS.globalCount; slot++) {
    globals.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
    env["g" + slot] = globals[slot];
  }
  const imports = { env };
  const base = pages * 65536;
  const known = new Map();
  let next = 0;

  const rip = () => BigInt.asUintN(64, globals[SLOTS.rip].value);

  // **Poser une région, et l'annoncer dans la correspondance.**
  //
  // Seule l'adresse d'**entrée** y est rangée, pas chaque bloc : l'émetteur ne
  // dit pas où commencent ses blocs, et une cible venue d'ailleurs est presque
  // toujours une entrée de fonction. Un saut au milieu d'une autre région rend
  // la main, et l'hôte traduit alors une région qui commence là — deux
  // traductions qui se recouvrent, ce qui est correct et seulement moins
  // économe.
  async function install(address) {
    const slot = next;
    const bytes = await translate(address, slot);
    if (!bytes) return null;
    // **Combien de blocs le module pose, on ne le sait qu'après.** L'émetteur
    // ne l'annonce pas, et l'instanciation est ce qui les met dans la table.
    // L'emplacement suivant se lit donc dans la table elle-même.
    const run = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports.run;
    next = occupied(slot) + 1;
    if (next <= slot) {
      throw new Error(`la région à ${address} n'a posé aucun bloc à l'emplacement ${slot}`);
    }
    const at = base + tableSlot(address) * SLOTS.tableEntry;
    new BigUint64Array(memory.buffer, at, 1)[0] = address;
    new Int32Array(memory.buffer, at + 8, 1)[0] = slot;
    const region = { run, slot };
    known.set(address, region);
    return region;
  }

  // Jusqu'où la table est occupée à partir de `from` : les blocs d'un module
  // s'y posent à l'instanciation, et c'est le seul moyen de savoir combien il
  // en a mis.
  function occupied(from) {
    let last = from - 1;
    for (let index = from; index < blocks.length; index++) {
      if (blocks.get(index) === null) break;
      last = index;
    }
    return last;
  }

  return {
    memory,
    globals,
    blocks,
    known,
    /// **Faire tourner la machine.** Rend pourquoi elle s'est arrêtée, jamais
    /// « rien » : un arrêt sans raison est ce qui rend une panne d'émulateur
    /// impossible à diagnostiquer.
    async run({ budget = 1n << 20n, rounds = 1 << 16 } = {}) {
      for (let round = 0; round < rounds; round++) {
        const here = rip();
        let region = known.get(here);
        if (region === undefined) {
          region = await install(here);
          if (region === null) {
            return { stopped: "refusée", at: here };
          }
        }
        region.run(budget);
        // **RIP inchangé ne veut pas dire bloqué**, et c'est une correction :
        // un anneau dont le budget s'épuise pile sur son point de départ
        // revient à l'adresse d'où il est parti après avoir tourné trois cents
        // fois. Le confondre avec une machine bloquée arrêterait un noyau en
        // pleine boucle.
        //
        // Ce qui distingue les deux est un **bloc de plus** : si un seul bloc
        // ne fait pas bouger RIP, plus rien ne le fera. C'est `ud2`, ou une
        // instruction que l'émetteur ne traduit pas. Le bloc supplémentaire
        // est du vrai travail dans le cas bénin, et il n'est payé que quand
        // RIP retombe sur son point de départ.
        if (rip() === here) {
          region.run(1n);
          if (rip() === here) {
            return { stopped: "sur place", at: here };
          }
        }
      }
      return { stopped: "tours épuisés", at: rip() };
    },
  };
}
