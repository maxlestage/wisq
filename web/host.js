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
  /// La case de RFLAGS. Elle ne servait à rien ici tant que personne ne lisait
  /// les drapeaux comme une **valeur** ; `pushf` les empile, donc elle sert.
  rflags: 16,
  rip: 17,
  /// Le premier des six sélecteurs de segment — ES, CS, SS, DS, FS, GS, dans
  /// l'ordre de l'énumération du décodeur. Ils partent à zéro, ce qui veut dire
  /// « aucun chargeur n'est passé ici » et non « le segment nul est chargé ».
  segment: 20,
  segmentCount: 6,
  /// Les deux tables de descripteurs, en limite puis base : GDT, puis IDT.
  table: 26,
  tableCount: 4,
  /// Les deux bases que `wrmsr` sait poser en plus de celle de GS : FS, puis
  /// celle que `swapgs` échange avec GS.
  fsBase: 30,
  kernelGs: 31,
  /// Les cinq registres de contrôle que le décodeur lit : CR0, CR2, CR3, CR4,
  /// CR8. Écrire CR0 et CR3 est produit depuis que la traduction existe :
  /// CR0.PG allume la marche, CR3 en donne la racine, CR2 porte l'adresse
  /// fautive.
  control: 32,
  controlCount: 5,
  /// Les trois globales de travail de la traduction — l'adresse invitée, son
  /// numéro de page, la case du tampon — puis le témoin de faute.
  translate: 47,
  translateCount: 3,
  fault: 50,
  globalCount: 51,
  tablePages: 16,
  tableEntry: 16,
  tableSlots: 1 << 16,
  /// **Le tampon de traduction**, juste au-dessus de la correspondance, donc
  /// encore plus haut que la RAM. Le module le déclare dans son minimum : un
  /// hôte qui ne le pose pas ne démarre pas, au lieu de piéger au premier
  /// défaut de tampon — et un piège WebAssembly est sans retour.
  tlbPages: 1,
  tlbEntry: 16,
  tlbSlots: 4096,
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
/// - `translate(address, slot, code)` rend les octets d'un module pour la
///   région qui commence là, `null` si l'émetteur refuse franchement, ou
///   `"encore"` s'il a manqué d'octets. Elle peut rendre une promesse.
///
///   **`code` est la fenêtre, lue ici et envoyée avec la demande**, et c'est
///   le point le plus important de tout ce fichier. La RAM de l'invité vit
///   dans cette vue ; l'application ne l'a pas. Une demande qui ne porterait
///   que l'adresse obligerait l'application à chercher les octets dans l'image
///   qu'elle a chargée — ce qui marche pour le noyau et **ment en silence**
///   dès que l'invité écrit son propre code, un module chargé par exemple.
///   Elle traduirait alors les mauvais octets, ce qui compile en un module
///   valide qui saute n'importe où.
///
///   **L'emplacement fait partie de la demande**, et ce n'est pas un détail :
///   les blocs d'une région se posent dans la table commune à partir de là, et
///   c'est la vue qui sait où il reste de la place. Une région compilée pour
///   un autre emplacement écraserait les blocs de sa voisine, en silence.
/// - `screen`, s'il est donné, décrit le tampon d'affichage que le chargeur a
///   déclaré au noyau : `{ base, width, height }`. Il doit tenir **entièrement
///   dans la RAM de l'invité** — la correspondance vit juste au-dessus, et un
///   cadre qui déborderait dessus peindrait la table des blocs à l'écran tout
///   en la détruisant.
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

/// **« Il m'en faut plus. »** Ni un module ni un refus : l'émetteur s'est
/// arrêté à moins de quinze octets du bord de la fenêtre, donc l'instruction
/// qui l'a bloqué a pu être **coupée** plutôt qu'être inconnue. Une troisième
/// réponse plutôt qu'un `null` déguisé, parce que « refusé » et « redemande »
/// ne se traitent pas pareil : l'un arrête la machine, l'autre coûte un
/// aller-retour.
///
/// Sur le vrai noyau Alpine, 91 régions sur 10 116 tombent là avec une fenêtre
/// de 4 Kio, et **toutes** se traduisent au second essai. Une fenêtre de 16 Kio
/// dès le départ les prendrait aussi, en payant quatre fois les octets sur les
/// 99,1 % qui n'en ont pas besoin.
const MORE = Object.freeze({ manque: "des octets" });

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
  const settled = attempt.then(
    bytes => (bytes === "encore" ? MORE : bytes),
    () => BROKEN,
  );
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

/// **Le port série, et le strict nécessaire d'un 16550.**
///
/// C'est par là qu'un noyau Linux parle avant d'avoir le moindre pilote : le
/// tout premier `printk` sort en `0x3f8`, un octet à la fois. Rien d'autre du
/// composant n'est implémenté, et c'est délibéré — mais deux registres ne
/// peuvent pas manquer, parce qu'un noyau *attend* sur eux :
///
/// - `0x3f8` en écriture est le registre d'émission. L'octet part.
/// - `0x3fd` en lecture est le registre d'état de ligne. Le noyau y tourne en
///   boucle jusqu'à voir « l'émetteur est libre » avant chaque caractère. Un
///   zéro rendu là ne perdrait pas un octet : il pendrait la machine pour
///   toujours, sur une boucle correcte.
const SERIAL = 0x3f8;
const SERIAL_STATUS = SERIAL + 5;
/// Émetteur vide **et** registre d'émission vide : les deux bits que la boucle
/// d'attente d'un noyau consulte.
const TRANSMITTER_IDLE = 0x60;
/// **Ce que rend un port où il n'y a personne.** Un vrai PC laisse le bus
/// flotter, et le lecteur voit tous les bits à un. Rendre zéro ferait croire à
/// un périphérique présent et muet, ce qui est la pire des deux réponses : un
/// noyau qui sonde `0xff` passe son chemin, un noyau qui sonde `0x00` s'installe.
const NOBODY_THERE = 0xff;

export function machine({
  translate,
  pages,
  screen,
  serial,
  regions = 4096,
  patience = 30000,
}) {
  if (!Number.isInteger(pages) || pages <= 0 || (pages & (pages - 1)) !== 0) {
    throw new Error(`la RAM doit être une puissance de deux, pas ${pages}`);
  }
  const memory = new WebAssembly.Memory({
    initial: pages + SLOTS.tablePages + SLOTS.tlbPages,
  });
  const blocks = new WebAssembly.Table({ element: "anyfunc", initial: regions });
  const globals = [];
  const env = { mem: memory, blocks };
  for (let slot = 0; slot < SLOTS.globalCount; slot++) {
    globals.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
    env["g" + slot] = globals[slot];
  }
  // **Le bit 1 de RFLAGS vaut toujours un sur x86.** Ce n'est pas un drapeau,
  // c'est une constante de l'architecture : l'interpréteur Rust le pose
  // (`Flags::read` rend `… | ALWAYS_ONE`) et l'oracle matériel le porte.
  //
  // Ici, tout partait de zéro. Tant que rien ne lisait RFLAGS comme une
  // valeur, la divergence ne se voyait pas ; le premier `pushf` aurait empilé
  // un RFLAGS qu'aucun processeur ne produit — le genre d'écart qu'un invité
  // ne remarque pas tout de suite et qui rend une trace incomparable à une
  // vraie.
  globals[SLOTS.rflags].value = 0x2n;
  // **Les deux fonctions par lesquelles l'invité touche le monde.**
  //
  // Elles sont *importées* plutôt qu'atteintes en sortant de la région : un
  // retour de main coûte environ 190 ns, mesuré, et une console écrit
  // caractère par caractère. Un appel importé en coûte des dizaines. C'est le
  // choix de v86.
  //
  // Les trois arguments arrivent en `i64`, donc en `BigInt` : le port, la
  // valeur, et **la largeur en octets**. La largeur est passée plutôt que
  // devinée — deux octets dont le haut est nul ressemblent à un octet.
  env.out = (port, value, width) => {
    const at = Number(port);
    if (at === SERIAL) {
      // Un `out %ax, %dx` vers l'émetteur écrit deux caractères sur un vrai
      // 16550 seulement avec la FIFO ; ici l'octet bas suffit, et le dire est
      // plus honnête que de faire semblant.
      if (serial) serial(Number(value & 0xffn));
      return;
    }
    // Tout le reste tombe dans le vide, comme sur une carte mère sans la
    // carte : une écriture vers un port absent ne fait rien et ne fait pas
    // planter la machine.
    void width;
  };
  env.in = (port, width) => {
    void width;
    if (Number(port) === SERIAL_STATUS) return BigInt(TRANSMITTER_IDLE);
    return BigInt(NOBODY_THERE);
  };
  const imports = { env };
  const base = pages * 65536;
  const known = new Map();
  let next = 0;

  // **Le cadre doit tenir dans la RAM invitée.** Sinon il chevaucherait la
  // correspondance : l'invité peindrait la table des blocs à l'écran, et la
  // détruirait du même geste. Refuser ici plutôt qu'à la première image.
  if (screen !== undefined) {
    const at = Number(BigInt(screen.base) & BigInt(base - 1));
    const octets = screen.width * screen.height * 4;
    if (!(screen.width > 0) || !(screen.height > 0) || at + octets > base) {
      throw new Error(
        `le cadre ${screen.width}×${screen.height} à ${at} déborde de la RAM invitée`,
      );
    }
  }

  const rip = () => BigInt.asUintN(64, globals[SLOTS.rip].value);

  // **Poser une région, et l'annoncer dans la correspondance.**
  //
  // Seule l'adresse d'**entrée** y est rangée, pas chaque bloc : l'émetteur ne
  // dit pas où commencent ses blocs, et une cible venue d'ailleurs est presque
  // toujours une entrée de fonction. Un saut au milieu d'une autre région rend
  // la main, et l'hôte traduit alors une région qui commence là — deux
  // traductions qui se recouvrent, ce qui est correct et seulement moins
  // économe.
  // **La fenêtre d'octets, et pourquoi ces deux tailles.** Mesuré sur le noyau
  // Alpine, avec 10 116 entrées atteintes par un `call` : 4 Kio traduit 98,2 %
  // des régions et en laisse 91 manquer de place ; 16 Kio en traduit 98,9 % et
  // n'en laisse que 6. Le rendement décroît vite, donc une grande fenêtre
  // paierait quatre fois les octets sur les 99,1 % qui n'en ont pas besoin.
  // Petite d'abord, grande sur demande.
  const WINDOW = 4096;
  const WIDER = 16384;

  /// **Lire la fenêtre dans la mémoire de l'invité**, à l'adresse repliée.
  ///
  /// Deux précautions, et aucune n'est décorative. La longueur est bornée par
  /// `base` — la fin de la RAM invitée — parce que **la correspondance vit
  /// juste au-dessus** : lire plus loin l'enverrait à l'application, qui la
  /// prendrait pour du code.
  ///
  /// Et c'est une **copie**, pas une vue. Une vue sur `memory.buffer` se
  /// détache si la mémoire grandit, et l'invité peut la réécrire pendant
  /// l'aller-retour vers l'application — qui traduirait alors des octets qui
  /// ont bougé sous son nez.
  function read(address, window) {
    const at = Number(address & BigInt(base - 1));
    return new Uint8Array(memory.buffer, at, Math.min(window, base - at)).slice();
  }

  async function install(address) {
    const slot = next;
    let bytes = await answered(
      () => translate(address, slot, read(address, WINDOW)),
      patience,
    );
    // **Un seul second essai, et seulement sur « il m'en faut plus ».** À
    // l'aveugle, il coûterait un aller-retour sur chaque refus franc ; ici il
    // ne coûte que sur les 0,9 % qui le demandent. Et il n'y en a qu'un : une
    // région qui manque encore de place à seize kibioctets ne se traduira pas
    // en redemandant sans fin.
    if (bytes === MORE) {
      bytes = await answered(
        () => translate(address, slot, read(address, WIDER)),
        patience,
      );
      if (bytes === MORE) return null;
    }
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

  /// **Rendre la main à la page.**
  ///
  /// Une machine qui tourne occupe le seul fil de la page. Tant qu'elle ne
  /// cède pas, **rien d'autre ne peut arriver** : ni un
  /// `requestAnimationFrame` — donc aucun repeint —, ni un toucher, ni un
  /// timer. Un `await` ne suffit pas : attendre une promesse déjà tenue ne
  /// cède qu'aux **micro-tâches**, et un timer n'en est pas une.
  ///
  /// **Un timer, et c'est une correction.** Le premier jet passait par un
  /// `MessageChannel`, sur l'argument que la spécification HTML borne un timer
  /// réarmé à quatre millisecondes alors qu'un message n'est pas borné. Le
  /// raisonnement portait sur la *granularité*, pas sur ce qu'on cherche ici.
  /// Mesuré sous le JavaScriptCore de Bun, à un souffle toutes les huit
  /// millisecondes pendant trois cents :
  ///
  /// | forme                 | souffles | tours de page obtenus |
  /// | --------------------- | -------: | --------------------: |
  /// | `setTimeout(…, 0)`    |       32 |                **32** |
  /// | `MessageChannel`      |       37 |                 **0** |
  /// | `Promise.resolve()`   |       37 |                 **0** |
  ///
  /// Un message est livré **sans laisser passer un timer déjà dû** : il cède
  /// aussi peu qu'une micro-tâche. Il aurait donné une boucle qui a l'air de
  /// respirer et une page toujours gelée — la pire des deux issues.
  ///
  /// Ce que le timer coûte, mesuré au même endroit : 2 991 417 tours contre
  /// 3 679 889 sans respirer, soit **dix-neuf pour cent de débit**. C'est le
  /// prix d'une vue qui répond.
  function souffler() {
    return new Promise((settle) => setTimeout(settle, 0));
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
    /// **Peindre l'image de l'invité dans un tampon que le dessinateur accepte.**
    ///
    /// **Ce n'est pas une recopie, c'est une conversion**, et c'est tout
    /// l'intérêt de cette fonction. Le noyau écrit en **XRGB8888** — les octets
    /// en mémoire sont `B, G, R, X` — parce que c'est ce que `simpledrm` prend
    /// sans rien convertir. Une `ImageData` veut `R, G, B, A`. Passer la
    /// mémoire telle quelle donnerait le rouge et le bleu échangés, et surtout
    /// **un alpha à zéro** : un écran entièrement transparent, c'est-à-dire
    /// rien. La pire panne à diagnostiquer, parce qu'elle ressemble à une
    /// machine qui n'a pas démarré.
    ///
    /// L'opacité est donc **forcée**, et les deux composantes échangées, un mot
    /// de trente-deux bits à la fois plutôt qu'octet par octet.
    ///
    /// **Rien ne traverse vers l'application** : le cadre vit dans cette
    /// mémoire-ci, le dessinateur aussi. C'est ce qui rend l'affichage possible
    /// — trois mégaoctets par image ne passeraient jamais un pont de messages.
    paint(into) {
      if (screen === undefined) throw new Error("aucun cadre n'a été déclaré");
      const at = Number(BigInt(screen.base) & BigInt(base - 1));
      const pixels = screen.width * screen.height;
      if (into.length < pixels * 4) {
        throw new Error(`le tampon reçoit ${into.length} octets pour ${pixels * 4}`);
      }
      const source = new Uint32Array(memory.buffer, at, pixels);
      const cible = new Uint32Array(into.buffer, into.byteOffset, pixels);
      for (let index = 0; index < pixels; index++) {
        const pixel = source[index];
        cible[index] =
          0xff000000 | ((pixel & 0xff) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 0xff);
      }
      return pixels;
    },
    /// **Faire tourner la machine.** Rend pourquoi elle s'est arrêtée, jamais
    /// « rien » : un arrêt sans raison est ce qui rend une panne d'émulateur
    /// impossible à diagnostiquer.
    ///
    /// `breath` est la **respiration**, en millisecondes : au-delà de ce
    /// temps passé sans rendre la main, la boucle cède un tour à la page.
    /// C'est le cadran entre débit et réactivité, et il se règle sur le
    /// **temps** et non sur les tours — une région qui rend la main après un
    /// seul bloc ferait autrement payer une tâche par bloc. Huit
    /// millisecondes tiennent dans une image à soixante hertz.
    ///
    /// **Ce que la respiration ne peut pas découper** : un `region.run(budget)`
    /// est indivisible. Le budget est donc le vrai plancher du gel, et à
    /// 2²⁰ blocs il vaut bien plus que huit millisecondes. Ce que coûte
    /// vraiment un gros budget ne se mesure que sur un appareil.
    async run({ budget = 1n << 20n, rounds = 1 << 16, breath = 8 } = {}) {
      let dernier = performance.now();
      for (let round = 0; round < rounds; round++) {
        if (performance.now() - dernier >= breath) {
          await souffler();
          dernier = performance.now();
        }
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
