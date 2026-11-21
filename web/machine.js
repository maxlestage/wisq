// La machine de l'émetteur, dans la page de l'application.
//
// **Ce que ce fichier assemble.** La boucle hôte (`host.js`), la carte des
// périphériques (`carte.js`) et l'émetteur compilé en WebAssembly
// (`page-emitter.js` sur `wisq_page.wasm`) : la machine que
// `examples/kernel-entry.rs` fait tourner sous Bun, mais conduite par
// l'application. Tout ce qu'il lui faut, il le va chercher **par `chercher`**
// à `base` — dans l'application, un `WKURLSchemeHandler` sur
// `wisq-machine://machine/` (`EmitterStore`, côté Swift) :
//
// - `plan.json` : la RAM en pages de 64 Kio, le point d'entrée, la page zéro,
//   les morceaux à poser (`segments`, chacun `{ chemin, a, octets }`),
//   l'écran de la carte (`{ largeur, hauteur, base }` ou `null`), le disque
//   (`{ chemin, octets }` ou `null`) et l'heure (`null` pour celle du mur, ou
//   des millisecondes figées) ;
// - `wisq_page.wasm` : le module de l'émetteur et de la carte ;
// - chaque `segments[i].chemin`, ses octets, posés à l'adresse physique `a` ;
// - le disque par plages, sur le contrat d'`arriereParUrl` (`?a=…&n=…`).
//
// **Ce qu'il rend** à qui l'a démarré : de quoi faire tourner la machine
// (`courir`, `arreter`), lui parler (`touches`, `taper`, `toucher`,
// `defiler`) et la regarder (`peindre`, `registre`, `etat`). Ce qu'elle dit,
// il le **poste** : la console série par paquets, l'écran quand son mode
// change, l'arrêt avec sa raison, une panne avec la sienne.
//
// **Rien ici ne suppose une page.** Pas de `window`, pas de `document` : la
// toile est un `peintre` qu'on lui donne, les messages une fonction `poster`.
// C'est ce qui le fait juger sous Bun, de bout en bout, par le même magasin
// Swift que l'application (`EmitterMachineTests`), et la page
// (`machine.html`) n'est qu'un raccord de quelques lignes.
import { machine, SLOTS } from "./host.js";
import { carte, arriereParUrl } from "./carte.js";
import { emetteur } from "./page-emitter.js";

/// **Le XRGB8888 de la carte vers le RGBA d'une `ImageData`**, opaque. Le
/// bleu est l'octet bas d'un pixel de la carte, le rouge celui d'une
/// `ImageData` ; et un alpha laissé à zéro donnerait un écran transparent, qui
/// ressemble à une machine qui n'a pas démarré. Rend le nombre de pixels.
export function versRgba(source, cible) {
  const pixels = Math.min(source.length, cible.length) >> 2;
  for (let i = 0, o = 0; i < pixels; i++, o += 4) {
    cible[o] = source[o + 2];
    cible[o + 1] = source[o + 1];
    cible[o + 2] = source[o];
    cible[o + 3] = 0xff;
  }
  return pixels;
}

/// **Où un doigt touche l'image de l'invité**, en fraction de chaque axe, de 0
/// à 1. `rect` est la boîte de la toile à l'écran (`getBoundingClientRect`) ;
/// l'image y est posée entière, centrée, à son rapport (`object-fit:
/// contain`) : les bandes noires autour n'en font pas partie. `null` hors de
/// l'image, ou pour une image ou une boîte vides.
export function positionSurLEcran(x, y, rect, largeur, hauteur) {
  if (!(largeur > 0 && hauteur > 0 && rect.width > 0 && rect.height > 0)) return null;
  const echelle = Math.min(rect.width / largeur, rect.height / hauteur);
  const montree = { largeur: largeur * echelle, hauteur: hauteur * echelle };
  const gauche = rect.left + (rect.width - montree.largeur) / 2;
  const haut = rect.top + (rect.height - montree.hauteur) / 2;
  const fx = (x - gauche) / montree.largeur;
  const fy = (y - haut) / montree.hauteur;
  if (fx < 0 || fx > 1 || fy < 0 || fy > 1) return null;
  return { x: fx, y: fy };
}

/// Des octets en base64, par tranches : passer des dizaines de kibioctets à
/// `String.fromCharCode` en une fois dépasse la pile d'arguments.
export function enBase64(octets) {
  let binaire = "";
  for (let at = 0; at < octets.length; at += 4096) {
    binaire += String.fromCharCode.apply(null, octets.subarray(at, at + 4096));
  }
  return btoa(binaire);
}

/// **Ce que la console garde au plus entre deux envois**, et ce qui part d'un
/// coup quand elle déborde : un invité qui parle sans fin est le cas normal,
/// et ce qui est jeté est compté (`perdus`), jamais tu.
const CONSOLE_GARDE = 1 << 16;
/// Un paquet de console part au plus tous les cent millisecondes, ou dès
/// qu'il dépasse quatre kibioctets : un `postMessage` par octet ferait des
/// dizaines de milliers de sérialisations pour un démarrage.
const CONSOLE_PERIODE = 100;
const CONSOLE_PAQUET = 4096;
/// Une image au plus toutes les trente-trois millisecondes : trente par
/// seconde, et rien quand la révision n'a pas bougé.
const ECRAN_PERIODE = 33;

/// Lire une réponse en octets, de la longueur attendue ou pas du tout.
async function octetsDe(chercher, url, attendus = null) {
  const reponse = await chercher(url);
  if (!reponse.ok) throw new Error(`${url} répond ${reponse.status}`);
  const octets = new Uint8Array(await reponse.arrayBuffer());
  if (attendus !== null && octets.length !== attendus) {
    throw new Error(`${url} rend ${octets.length} octets pour ${attendus}`);
  }
  return octets;
}

/// **Démarrer la machine** décrite par `base + "plan.json"`. Rend son
/// conducteur une fois la RAM posée et les registres d'entrée écrits ; rien ne
/// tourne avant `courir()`.
///
/// - `chercher(url, options)` : un `fetch` ;
/// - `poster(message)` : où vont la console, l'écran, l'arrêt et les pannes ;
/// - `peintre` : `{ image(largeur, hauteur) → { data }, montrer() }`, ou
///   `null` pour une machine qu'on ne regarde pas ;
/// - `maintenant()` : l'horloge des périodes, en millisecondes ;
/// - `ceder()` : rendre la main entre deux tranches (un `setTimeout` nul) ;
/// - `toutes(ms, faire)` : appeler `faire` toutes les `ms` millisecondes, et
///   rendre de quoi cesser (`setInterval`, par défaut).
export async function demarrer({
  base,
  chercher,
  poster,
  peintre = null,
  maintenant = () => performance.now(),
  ceder = () => new Promise((resoudre) => setTimeout(resoudre, 0)),
  toutes = (ms, faire) => {
    const minuterie = setInterval(faire, ms);
    return () => clearInterval(minuterie);
  },
}) {
  const plan = await (await chercher(base + "plan.json")).json();
  if (!Number.isInteger(plan.pages) || plan.pages <= 0) {
    throw new Error(`le plan ne dit pas la RAM : ${JSON.stringify(plan.pages)}`);
  }
  // **Compilé hors du fil**, puis instancié deux fois sur le même module :
  // l'émetteur, que `page-emitter.js` remplace après une trappe, et la carte,
  // qui ne doit pas partir avec lui.
  const module = await WebAssembly.compile(await octetsDe(chercher, base + "wisq_page.wasm"));
  const porte = emetteur(module);

  let traduites = 0;
  let refusees = 0;
  let dernierRefus = null;
  // **Une région se traduit dans le fil de la page**, comme sous
  // `kernel-entry` : une coupe rend `"encore"` (l'hôte relit plus large),
  // une trappe de l'émetteur est un refus sous son nom.
  const translate = (adresse, emplacement, code) => {
    const r = porte.resoudre(code, adresse, emplacement, plan.pages);
    if (r.module !== undefined) {
      traduites += 1;
      return r.module;
    }
    if (r.encore !== undefined) return "encore";
    refusees += 1;
    dernierRefus = { a: "0x" + BigInt.asUintN(64, BigInt(adresse)).toString(16), pourquoi: r.refus ?? `Trappe(${r.trappe})` };
    return null;
  };

  // La console : tamponnée, envoyée par paquets.
  let console_ = [];
  let perdus = 0;
  let dernierEnvoi = maintenant();
  const serial = (octet) => {
    if (console_.length >= CONSOLE_GARDE) {
      const jetes = console_.length >> 1;
      console_ = console_.slice(jetes);
      perdus += jetes;
    }
    console_.push(octet);
  };
  const viderLaConsole = (toutDeSuite) => {
    if (console_.length === 0 && perdus === 0) return;
    if (!toutDeSuite && console_.length < CONSOLE_PAQUET && maintenant() - dernierEnvoi < CONSOLE_PERIODE) return;
    poster({ kind: "console", octets: enBase64(Uint8Array.from(console_)), perdus });
    console_ = [];
    perdus = 0;
    dernierEnvoi = maintenant();
  };

  const heure = plan.heure === null || plan.heure === undefined ? Date.now : () => plan.heure;
  const ecran = plan.ecran ?? null;
  const disque = plan.disque ?? null;
  const vm = machine({
    translate,
    pages: plan.pages,
    serial,
    carte: (ram) =>
      carte(module, {
        ram,
        heure,
        ecran: ecran === null ? null : { largeur: ecran.largeur, hauteur: ecran.hauteur },
        disque: disque === null ? null : arriereParUrl(base + disque.chemin, disque.octets, { fetch: chercher }),
      }),
  });
  // **L'écran doit être là où le chargeur l'a annoncé** (`screen_info` de la
  // page zéro) : sinon le noyau peindrait ailleurs que là où la page lit.
  if (ecran !== null && vm.carte.ecran.base() !== BigInt(ecran.base)) {
    throw new Error(
      `la carte pose sa mémoire vidéo à 0x${vm.carte.ecran.base().toString(16)}, le plan l'annonce à ${ecran.base}`,
    );
  }

  // **La RAM, posée** : le noyau segment par segment, la page zéro,
  // l'archive. Chaque morceau a la longueur que le plan annonce, ou le
  // démarrage s'arrête : un noyau tronqué ne s'annonce pas, il saute dans le
  // vide bien plus tard.
  const ram = plan.pages * 65536;
  for (const morceau of plan.segments) {
    if (!Number.isInteger(morceau.a) || morceau.a < 0 || morceau.a + morceau.octets > ram) {
      throw new Error(`${morceau.chemin} ne tient pas dans la RAM à ${morceau.a}`);
    }
    const octets = await octetsDe(chercher, base + morceau.chemin, morceau.octets);
    new Uint8Array(vm.memory.buffer, morceau.a, octets.length).set(octets);
    vm.ecrit(morceau.a, octets.length);
  }
  // **Ce qu'un chargeur pose en entrant dans `startup_64`** : RIP sur
  // l'entrée, RSI sur la page zéro, CS à `__BOOT_CS` et les données à
  // `__BOOT_DS` (voir `kernel-entry`, où un CS à zéro garait le noyau de Void).
  vm.globals[SLOTS.rip].value = BigInt(plan.entree);
  vm.globals[6].value = BigInt(plan.pageZero);
  vm.globals[SLOTS.segment + 1].value = 0x10n;
  for (const s of [0, 2, 3]) vm.globals[SLOTS.segment + s].value = 0x18n;

  let revisionPeinte = null;
  let modeAnnonce = null;
  let dernierePeinture = -Infinity;
  /// **Peindre maintenant**, si l'image a bougé. Rend le nombre de pixels
  /// peints, zéro quand rien n'a changé ou qu'il n'y a ni écran ni peintre.
  const peindre = () => {
    dernierePeinture = maintenant();
    const e = vm.ecran(revisionPeinte);
    if (e === null) return 0;
    const mode = e.largeur + "x" + e.hauteur;
    if (mode !== modeAnnonce) {
      modeAnnonce = mode;
      poster({ kind: "écran", largeur: e.largeur, hauteur: e.hauteur });
    }
    if (e.image === null || peintre === null) return 0;
    revisionPeinte = e.revision;
    const image = peintre.image(e.largeur, e.hauteur);
    const pixels = versRgba(e.image, image.data);
    peintre.montrer();
    return pixels;
  };

  let enMarche = false;
  let arret = null;
  /// **Faire tourner la machine** jusqu'à ce qu'elle s'arrête d'elle-même ou
  /// qu'on l'arrête. Par tranches, et la boucle hôte respire toutes les huit
  /// millisecondes : c'est là que les touches et les touchers arrivent, et
  /// qu'une minuterie envoie la console et repeint l'écran — **pas** au
  /// retour d'une tranche, qui peut se faire attendre : un invité qui attend
  /// une touche en lisant le clavier fait durer chacune de ses tranches, et
  /// rien n'était peint tant qu'il attendait. Rend `{ stopped, at }`, posté
  /// aussi.
  const courir = async ({ budget = 1n << 22n, tours = 1 << 12 } = {}) => {
    if (enMarche) throw new Error("la machine tourne déjà");
    if (arret !== null) return arret;
    enMarche = true;
    const cesser = toutes(ECRAN_PERIODE, () => {
      viderLaConsole(false);
      if (maintenant() - dernierePeinture >= ECRAN_PERIODE) peindre();
    });
    try {
      for (;;) {
        const why = await vm.run({ budget: BigInt(budget), rounds: tours });
        if (why.stopped !== "tours épuisés") {
          arret = { stopped: why.stopped, at: BigInt.asUintN(64, BigInt(why.at)) };
          break;
        }
        if (!enMarche) {
          arret = { stopped: "arrêtée par l'application", at: BigInt.asUintN(64, vm.globals[SLOTS.rip].value) };
          break;
        }
        await ceder();
      }
    } finally {
      enMarche = false;
      cesser();
    }
    viderLaConsole(true);
    peindre();
    poster({ kind: "arrêt", stopped: arret.stopped, at: arret.at.toString(), refus: dernierRefus });
    return arret;
  };

  poster({ kind: "prête", pages: plan.pages, segments: plan.segments.length });

  return {
    vm,
    courir,
    /// Arrêter à la fin de la tranche en cours.
    arreter() {
      enMarche = false;
    },
    /// **Des touches**, posées tout de suite : `[[jeu1, etendue, enfoncee], …]`
    /// — les codes du jeu 1 d'un clavier PC, `E0` ou non, enfoncée ou
    /// relâchée. Rend combien la file a pris.
    touches(liste) {
      let prises = 0;
      for (const [jeu1, etendue, enfoncee] of liste) {
        if (vm.carte.taper(jeu1 & 0xff, etendue === true, enfoncee === true)) prises += 1;
      }
      return prises;
    },
    /// Un texte, au rythme d'une main, sur un clavier américain.
    taper: (texte) => vm.taper(String(texte)),
    /// Toucher l'écran : la position de 0 à 1, les boutons en bits.
    toucher: (x, y, boutons) => vm.toucher(Number(x), Number(y), boutons >>> 0),
    /// La molette, en crans, positifs vers le haut.
    defiler: (crans) => vm.carte.defiler(crans | 0),
    peindre,
    /// Un registre de l'invité, en texte (un `BigInt` ne traverse pas JSON).
    registre: (numero) => BigInt.asUintN(64, vm.globals[numero].value).toString(),
    /// Ce que la machine a fait jusqu'ici.
    etat: () => ({
      traduites,
      refusees,
      dernierRefus,
      enMarche,
      arret: arret === null ? null : { stopped: arret.stopped, at: arret.at.toString() },
      ecran: modeAnnonce,
      revision: vm.carte !== null && ecran !== null ? vm.carte.ecran.revision().toString() : null,
    }),
  };
}
