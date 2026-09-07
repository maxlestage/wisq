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
/// - `patience` est le temps, en millisecondes, au-delà duquel une traduction
///   sans réponse est traitée comme une panne. Zéro attend indéfiniment.
///
///   **Pourquoi il en faut une.** `translate` rend une promesse, et rien ne
///   garantit qu'elle soit tenue : l'hôte peut être occupé, avoir planté, ou
///   avoir perdu le message. Sans garde, `await` ne rend jamais la main et
///   l'écran reste tel quel **sans un mot** — le pire mode de panne pour
///   diagnostiquer. Trente secondes est long pour une traduction (elles se
///   comptent en microsecondes) et court pour un humain qui regarde un écran
///   figé.
/// Ce qu'une traduction rend quand elle ne rend rien : l'application n'a pas
/// répondu, ou elle a levé. Deux objets distincts plutôt qu'un `null` partagé
/// avec le refus franc de l'émetteur — les trois se corrigent ailleurs.
const MUTE = Object.freeze({ panne: "sans réponse" });
const BROKEN = Object.freeze({ panne: "en panne" });

/// **Attendre une traduction, mais pas éternellement.**
///
/// Le réveil est **désarmé** dès que la réponse arrive : une machine qui
/// traduit des milliers de régions laisserait sinon des milliers de minuteries
/// derrière elle. Et une réponse qui arrive *après* la patience ne compte pas
/// — la machine a déjà rendu la main, y revenir la ferait repartir d'un état
/// qu'elle a quitté.
async function answered(ask, patience) {
  let attempt;
  try {
    attempt = Promise.resolve(ask());
  } catch (why) {
    return BROKEN;
  }
  const settled = attempt.then(bytes => bytes, () => BROKEN);
  if (!(patience > 0)) return settled;
  let alarm;
  const waited = new Promise(settle => {
    alarm = setTimeout(() => settle(MUTE), patience);
  });
  return Promise.race([settled, waited]).then(outcome => {
    clearTimeout(alarm);
    return outcome;
  });
}

export function machine({ translate, pages, regions = 4096, patience = 30000 }) {
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
    const bytes = await answered(() => translate(address, slot), patience);
    if (bytes === MUTE || bytes === BROKEN) return bytes;
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
          // **Trois pannes, trois noms.** « Ça ne marche pas » n'aide
          // personne à chercher : une région que l'émetteur refuse, une
          // application muette et une application qui lève ne se corrigent
          // pas au même endroit.
          if (region === MUTE) {
            return { stopped: "traduction sans réponse", at: here };
          }
          if (region === BROKEN) {
            return { stopped: "traduction en panne", at: here };
          }
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
