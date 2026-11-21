// La carte de la machine PC, dans la page.
//
// **Ce qu'elle apporte.** La boucle hôte (`web/host.js`) modélise deux 8259,
// un 8254 et un 16550 ; sans la carte, tout autre port y rend `0xff`,
// personne. Un noyau n'y trouve alors ni clavier, ni souris, ni horloge
// murale, ni disque : « i8042: Can't read CTR », et une date de 1970.
// `machine({ carte: (ram) => carte(module, { ram, disque }) })` la branche :
// ses ports après ceux des puces, ses lignes recopiées dans les deux 8259 à
// chaque tour, `reveil()` compté dans l'attente d'un `hlt`, et un `hlt` qui
// attend le disque cède le fil (`disque.attendre()`) le temps que l'arrière
// réponde. Les périphériques qui manquent sont écrits en
// Rust (`crates/wisq-page/src/carte/`), portés depuis le cœur Swift avec sa
// carte exacte — l'i8042 aux ports `0x60`/`0x64` sur les lignes 1 et 12,
// l'horloge CMOS aux ports `0x70`/`0x71`, le pont PCI aux ports
// `0xCF8`/`0xCFC` avec le disque virtio de forme ancienne en 00:03.0 sur la
// ligne 5 —, et compilés dans le même module que l'émetteur,
// `wisq_page.wasm`. Ce fichier les charge et les sert.
//
// **Ce qu'il expose à `host.js`**, et rien de plus :
//
// - `ports.in(port, largeur)` et `ports.out(port, valeur, largeur)`, de la
//   forme exacte d'`env.in` et `env.out` : `in` rend la valeur en `BigInt`, ou
//   `null` quand le port n'est pas à la carte ; `out` rend `true` quand la
//   carte l'a pris. Les ports des puces de `host.js` ne sont jamais à la
//   carte : l'aiguillage les lui passe en dernier.
// - `lignes()` : `{ maitre, esclave, tenuesMaitre, tenuesEsclave }`, huit bits
//   chacun. À niveau : les bits `tenues` que `maitre`/`esclave` ne lèvent pas
//   doivent être effacés des registres de requête, chaque tour.
// - `battre(tics)` : le temps, en tics du 8254 depuis le départ ; c'est ce qui
//   pose les frappes au rythme d'une main.
// - `reveil()` et `remise()` : une ligne peut encore monter sans l'invité (ce
//   que `wakeable` doit compter) ; l'invité a demandé un redémarrage.
// - et ce que l'application envoie : `touche`, `taper`, `taperTexte`,
//   `souris`, et, avec un écran, `toucher` et `defiler` (la tablette).
// - `memoire.lire(adresse, largeur)` et `memoire.ecrire(adresse, valeur,
//   largeur)` : un accès de l'invité **hors de sa RAM**, à une adresse
//   physique — la mémoire vidéo de l'écran, ses registres, ceux de la
//   tablette. `lire` rend un `BigInt`, ou `null` quand l'adresse n'est à
//   personne ; `ecrire` rend `true` quand la carte l'a pris.
// - `livrer(tics)` : ce que le doigt a fait, posé dans les tampons du pilote
//   de la tablette, à chaque tour avant `lignes()`.
//
// **L'écran** (`ecran: { largeur, hauteur }` à la fabrication) : la carte
// graphique de Bochs en 00:02.0, sa mémoire vidéo de seize mébioctets à
// `0xE000_0000`, et la tablette virtio en 00:07.0. La mémoire vidéo vit dans
// la mémoire de **ce** module, pas dans la RAM de l'invité : `ecran.image()`
// la lit d'un bloc, le rectangle montré, et `ecran.revision()` dit si elle a
// bougé depuis la dernière image — une vue qui repeint trente fois par
// seconde une image identique se paie en batterie.
//
// **La RAM de l'invité**, que la file du disque lit et écrit, est donnée par
// `ram` : `{ lire(adresse, vers), ecrire(adresse, depuis) }`, adresses
// physiques, une plage entière ou `false`. `host.js` en donne une à la
// fabrique de sa carte, dont les écritures se disent à `ecrit` (le code
// traduit d'une page que le disque réécrit est oublié). `ramDeMemoire` en
// fait une nue d'une `WebAssembly.Memory`, pour qui conduit la carte sans
// boucle hôte. Le module la demande par deux imports, `carte.ram_lire` et
// `carte.ram_ecrire`, que ce fichier remplit.
//
// **Le disque est servi plus tard.** Ses octets ne sont pas dans la page (une
// ISO de 1,4 Gio ne tient pas à côté de 1 Gio de RAM). `disque` est un
// arrière : `{ octets, lire(décalage, longueur) → promesse d'octets,
// ecrire(décalage, octets) → promesse de booléen }`. Quand le pilote notifie,
// l'`out` rend tout de suite ; la requête part vers l'arrière, et quand la
// promesse se résout, les octets sont copiés dans la RAM, l'anneau des
// servies écrit, la ligne 5 levée — à la boucle hôte de la recopier au tour
// suivant, comme les autres. `arriereParUrl` en fait un d'une URL qui sert
// des plages (`?a=décalage&n=longueur`), le contrat du magasin de la page.
//
// **Une instance à elle.** La carte est instanciée à part de l'émetteur, sur
// le même `WebAssembly.Module` (déjà compilé : une instanciation, pas une
// compilation). L'émetteur jette son instance après une trappe
// (`web/page-emitter.js`) ; le clavier et l'horloge ne doivent pas partir avec
// elle. **Une trappe de la carte, elle, n'est pas rattrapée** : un
// périphérique qui trappe a pu s'arrêter au milieu d'un registre, et une
// carte neuve oublierait tout ce que le noyau a programmé. L'erreur remonte à
// la boucle, qui s'arrête en la nommant.
//
// **L'heure est posée avant chaque accès à l'horloge**, et seulement là :
// `Date.now()` par défaut, ou la fonction `heure` donnée (les tests figent le
// moment). L'heure n'est pas un import : le module ne la lit jamais lui-même.
//
// **Ce qui est jugé, et où** : les périphériques en natif, cas par cas
// (`cargo test -p wisq-carte`) ; ce fichier et le module wasm32 sous Bun
// (`crates/wisq-page/tests/carte.rs`), dont un disque lu par plages dans un
// fichier creux de 1,4 Gio servi par `Bun.serve`.

/// Le code de `carte_lire` pour un port qui n'est pas à la carte.
const PERSONNE = -1n;
/// Les deux ports de l'horloge, avant lesquels l'heure est posée.
const HORLOGE_INDEX = 0x70;
const HORLOGE_DONNEE = 0x71;

/// La taille d'un secteur du disque, en octets.
const SECTEUR = 512;

/// **La RAM de l'invité dans une `WebAssembly.Memory`**, de `octets` octets
/// à partir de l'adresse linéaire zéro — l'agencement de `host.js`, où
/// l'adresse physique est l'adresse linéaire. Le `buffer` est relu à chaque
/// accès : la mémoire a pu grandir.
export function ramDeMemoire(memoire, octets) {
  const dedans = (adresse, longueur) => adresse >= 0 && adresse + longueur <= octets;
  return {
    lire(adresse, vers) {
      if (!dedans(adresse, vers.length)) return false;
      vers.set(new Uint8Array(memoire.buffer, adresse, vers.length));
      return true;
    },
    ecrire(adresse, depuis) {
      if (!dedans(adresse, depuis.length)) return false;
      new Uint8Array(memoire.buffer, adresse, depuis.length).set(depuis);
      return true;
    },
  };
}

/// **Un disque derrière une URL qui sert des plages** : `GET url?a=…&n=…`
/// rend `n` octets à partir de `a`, `PUT url?a=…` écrit le corps à `a`. Les
/// plages sont dans l'URL plutôt que dans un en-tête `Range` pour rester une
/// requête simple, sans prévol CORS : c'est le contrat que le magasin de la
/// page (un `WKURLSchemeHandler` sur `wisq://`) devra tenir. Une réponse
/// d'une autre longueur que demandée est un échec, jamais des octets à
/// compléter.
export function arriereParUrl(url, octets, { fetch: chercher = (...a) => globalThis.fetch(...a) } = {}) {
  const avec = (requete) => url + (url.includes("?") ? "&" : "?") + requete;
  return {
    octets,
    async lire(decalage, longueur) {
      const reponse = await chercher(avec(`a=${decalage}&n=${longueur}`));
      if (!reponse.ok) throw new Error(`le disque répond ${reponse.status} pour ${longueur} octets à ${decalage}`);
      const lus = new Uint8Array(await reponse.arrayBuffer());
      if (lus.length !== longueur) throw new Error(`le disque rend ${lus.length} octets pour ${longueur}`);
      return lus;
    },
    async ecrire(decalage, depuis) {
      const reponse = await chercher(avec(`a=${decalage}`), { method: "PUT", body: depuis });
      return reponse.ok;
    },
  };
}

/// **Instancier la carte.** `source` : le module de `wisq_page.wasm`, compilé
/// (`WebAssembly.Module`) ou en octets. `heure` : l'heure UTC de l'hôte, en
/// millisecondes depuis 1970. `ram` : la RAM de l'invité (voir plus haut),
/// sans laquelle le disque ne lit aucune file. `disque` : l'arrière du disque,
/// sans lequel aucun disque n'est branché. `surReponse` : appelée après
/// chaque réponse du disque rendue, quand la ligne vient de monter — de quoi
/// réveiller une boucle qui dort.
export function carte(
  source,
  { heure = Date.now, ram = null, disque = null, surReponse = null, ecran = null } = {},
) {
  const module = source instanceof WebAssembly.Module ? source : new WebAssembly.Module(source);
  // Les deux imports de la RAM. Une adresse est un `BigInt` (un `u64` du
  // côté Rust) ; au-delà de 2⁵³ elle n'est dans aucune RAM. Les pointeurs
  // du module sont des `i32` : ramenés en non signés.
  const plage = (adresse, ou, longueur) => {
    const a = BigInt.asUintN(64, adresse);
    if (ram === null || a > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    return [Number(a), new Uint8Array(porte.memory.buffer, ou >>> 0, longueur >>> 0)];
  };
  const imports = {
    carte: {
      ram_lire(adresse, vers, longueur) {
        const p = plage(adresse, vers, longueur);
        return p !== null && ram.lire(p[0], p[1]) ? 1 : 0;
      },
      ram_ecrire(adresse, depuis, longueur) {
        const p = plage(adresse, depuis, longueur);
        return p !== null && ram.ecrire(p[0], p[1]) ? 1 : 0;
      },
    },
  };
  const porte = new WebAssembly.Instance(module, imports).exports;
  const texte = new TextEncoder();
  if (disque !== null) porte.carte_disque(BigInt(Math.floor(disque.octets / SECTEUR)));
  // **L'écran, avant le démarrage** : c'est le chargeur qui annonce son cadre
  // au noyau. Un cadre qui ne tient pas dans la mémoire vidéo est refusé ici,
  // plutôt qu'une machine sans écran qui démarrerait quand même.
  if (ecran !== null && porte.carte_ecran(ecran.largeur >>> 0, ecran.hauteur >>> 0) !== 1) {
    throw new Error(`un écran de ${ecran.largeur}×${ecran.hauteur} ne tient pas dans la mémoire vidéo`);
  }

  const horloge = (port) => {
    if (port === HORLOGE_INDEX || port === HORLOGE_DONNEE) porte.carte_heure(heure());
  };

  const ports = {
    /// `port` et `largeur` tels qu'`env.in` les reçoit (des `BigInt`), ou
    /// des nombres.
    in(port, largeur) {
      const at = Number(port);
      horloge(at);
      const valeur = porte.carte_lire(at, Number(largeur));
      return valeur === PERSONNE ? null : valeur;
    },
    /// La valeur ramenée sur 32 bits : un port n'en porte pas plus, et
    /// l'export la reçoit en `i32`.
    ///
    /// Un `out` qui a notifié le disque fait partir ses requêtes ici même :
    /// l'`out` rend tout de suite, et l'arrière répond plus tard.
    out(port, valeur, largeur) {
      const at = Number(port);
      horloge(at);
      const pris = porte.carte_ecrire(at, Number(largeur), Number(BigInt.asUintN(32, BigInt(valeur)))) === 1;
      if (pris && disque !== null && porte.carte_requetes() !== 0) servir();
      return pris;
    },
  };

  /// **La prochaine requête du disque**, prise : `{ id, sens, decalage,
  /// longueur, octets }` — `octets`, copiés, pour une écriture seulement —
  /// ou `null`. `servir` la prend lui-même quand un arrière est donné.
  function requeteDisque() {
    if (porte.carte_requete() !== 1) return null;
    const ecriture = porte.carte_requete_sens() === 1;
    const longueur = porte.carte_requete_longueur() >>> 0;
    return {
      id: porte.carte_requete_id() >>> 0,
      sens: ecriture ? "ecrire" : "lire",
      decalage: Number(BigInt.asUintN(64, porte.carte_requete_decalage())),
      longueur,
      // Copiés : la place ne vaut que jusqu'à la prochaine requête prise.
      octets: ecriture ? new Uint8Array(porte.memory.buffer, porte.carte_requete_octets() >>> 0, longueur).slice() : null,
    };
  }

  /// **Les octets d'une lecture sont revenus** : copiés dans la RAM, la
  /// requête rendue, la ligne levée. `false` si `id` ne nomme plus aucune
  /// requête (une remise à zéro est passée entre-temps).
  function disqueLu(id, octets) {
    const vue = octets instanceof Uint8Array ? octets : new Uint8Array(octets);
    const place = porte.carte_disque_place(vue.length) >>> 0;
    new Uint8Array(porte.memory.buffer, place, vue.length).set(vue);
    return porte.carte_disque_lu(id, vue.length) === 1;
  }

  /// **Une requête finie sans octets** : une écriture faite, ou un échec.
  function disqueFini(id, reussi) {
    return porte.carte_disque_fini(id, reussi ? 1 : 0) === 1;
  }

  let enVol = 0;
  /// Ceux qui attendent la prochaine réponse rendue (`attendre`).
  let attentes = [];
  /// **Attendre la prochaine réponse du disque** : une promesse résolue quand
  /// une réponse a été rendue — octets copiés, ligne levée —, ou tout de suite
  /// s'il n'y a rien en vol. C'est ce que la boucle hôte attend sur un `hlt`
  /// : sans céder le fil, la réponse ne viendrait jamais. Résolue aussi quand
  /// la carte trappe en rendant la réponse : la boucle doit reprendre, et la
  /// trappe se signale à part.
  function attendre() {
    if (enVol === 0) return Promise.resolve();
    return new Promise((resoudre) => attentes.push(resoudre));
  }
  /// **Confier à l'arrière tout ce qui est parti.** Rend le nombre de
  /// requêtes confiées. Un échec de l'arrière (une promesse rejetée, une
  /// écriture qu'il ne sait pas faire ou qu'il dit ratée) est rendu au pilote
  /// en erreur d'entrée-sortie ; une erreur de la carte elle-même, en rendant
  /// la réponse, n'est pas rattrapée — elle reste une promesse rejetée, que le
  /// moteur signale.
  ///
  /// **Une réponse peut faire partir d'autres requêtes** : la carte ne tient
  /// que 64 Mio à la fois pour l'arrière, et ce qui ne tenait pas attendait
  /// dans la file que de la place se libère. Elles sont confiées dès la
  /// réponse rendue, avant que `enVol` ne descende : il ne passe jamais par
  /// zéro tant qu'une requête reste à servir.
  function servir() {
    let confiees = 0;
    for (let r = requeteDisque(); r !== null; r = requeteDisque()) {
      const { id } = r;
      const demande =
        r.sens === "lire"
          ? Promise.resolve().then(() => disque.lire(r.decalage, r.longueur))
          : Promise.resolve().then(() => (disque.ecrire ? disque.ecrire(r.decalage, r.octets) : false));
      enVol += 1;
      demande
        .then(
          (rendu) => (r.sens === "lire" ? disqueLu(id, rendu) : disqueFini(id, rendu === true)),
          () => disqueFini(id, false),
        )
        .then(() => {
          if (porte.carte_requetes() !== 0) servir();
        })
        .finally(() => {
          enVol -= 1;
          const reveilles = attentes;
          attentes = [];
          for (const resoudre of reveilles) resoudre();
        })
        .then(() => surReponse?.());
      confiees += 1;
    }
    return confiees;
  }

  /// Les lignes, coupées entre les deux 8259.
  function lignes() {
    const levees = porte.carte_lignes();
    const tenues = porte.carte_tenues();
    return {
      maitre: levees & 0xff,
      esclave: (levees >> 8) & 0xff,
      tenuesMaitre: tenues & 0xff,
      tenuesEsclave: (tenues >> 8) & 0xff,
    };
  }

  /// Le temps, en tics du 8254. Un `BigInt` (l'export est un `i64`) : ceux de
  /// `host.js` le sont déjà.
  function battre(tics) {
    porte.carte_battre(BigInt.asUintN(64, BigInt(tics)));
  }

  /// Un texte, au rythme d'une main, sur un clavier américain. Rend le nombre
  /// de frappes mises en file : un caractère y entre entier ou pas du tout,
  /// et le texte s'arrête au premier qui ne tient plus sous la borne.
  function taperTexte(chaine) {
    const octets = texte.encode(chaine);
    const place = porte.carte_texte_place(octets.length);
    // L'adresse est relue juste avant la copie : la mémoire a pu grandir.
    new Uint8Array(porte.memory.buffer, place, octets.length).set(octets);
    const rendu = porte.carte_texte(octets.length);
    if (rendu < 0) throw new Error("la carte refuse le texte à taper");
    return rendu;
  }

  /// **La mémoire des périphériques**, hors de la RAM. L'adresse est un
  /// `BigInt` (un `u64`) ; la largeur, de un à huit octets.
  const memoire = {
    lire(adresse, largeur) {
      if (porte.carte_mem_lire(BigInt.asUintN(64, BigInt(adresse)), Number(largeur)) !== 1) return null;
      return BigInt.asUintN(64, porte.carte_mem_valeur());
    },
    /// La sonnette de la tablette lit sa file dans la RAM pendant l'appel,
    /// par les deux imports.
    ecrire(adresse, valeur, largeur) {
      return (
        porte.carte_mem_ecrire(
          BigInt.asUintN(64, BigInt(adresse)),
          Number(largeur),
          BigInt.asUintN(64, BigInt(valeur)),
        ) === 1
      );
    },
  };

  /// **L'écran, vu de la page.** La vue de la mémoire vidéo se refait à
  /// chaque appel : la mémoire du module a pu grandir et détacher l'ancienne.
  const vueDeLEcran = {
    /// Le mode montré : `{ largeur, hauteur, octetsParLigne, debut }` (le
    /// premier pixel, en octets depuis le début de la mémoire vidéo), ou
    /// `null` sans écran.
    mode() {
      const mots = new Uint32Array(porte.memory.buffer, porte.carte_ecran_mode() >>> 0, 4);
      if (mots[0] === 0) return null;
      return { largeur: mots[0], hauteur: mots[1], octetsParLigne: mots[2], debut: mots[3] };
    },
    /// Combien de fois l'image a changé, en `BigInt` ; zéro sans écran.
    revision: () => BigInt.asUintN(64, porte.carte_ecran_revision()),
    /// Où l'invité voit la mémoire vidéo (sa BAR0), en `BigInt`.
    base: () => BigInt.asUintN(64, porte.carte_ecran_base()),
    /// La mémoire vidéo entière, en vue (pas en copie) : seize mébioctets.
    pixels() {
      const taille = porte.carte_ecran_taille() >>> 0;
      return new Uint8Array(porte.memory.buffer, porte.carte_ecran_pixels() >>> 0, taille);
    },
    /// **L'image montrée, d'un bloc** : `largeur × hauteur × 4` octets en
    /// XRGB8888, le bleu en bas, sans le remplissage des lignes. Une copie ;
    /// `null` sans écran.
    image() {
      const mode = vueDeLEcran.mode();
      if (mode === null) return null;
      const tout = vueDeLEcran.pixels();
      const ligne = mode.largeur * 4;
      if (mode.octetsParLigne === ligne) {
        return tout.slice(mode.debut, mode.debut + ligne * mode.hauteur);
      }
      const rendu = new Uint8Array(ligne * mode.hauteur);
      for (let y = 0; y < mode.hauteur; y++) {
        const de = mode.debut + y * mode.octetsParLigne;
        rendu.set(tout.subarray(de, de + ligne), y * ligne);
      }
      return rendu;
    },
  };

  return {
    ports,
    lignes,
    battre,
    taperTexte,
    memoire,
    ecran: vueDeLEcran,
    /// **Un toucher**, par la tablette : la position de 0 à 1 sur chaque axe,
    /// les boutons en bits (gauche, droit, milieu). `false` quand l'invité n'a
    /// pas pris la tablette : la souris PS/2 reste alors la seule.
    toucher: (x, y, boutons) => porte.carte_toucher(Number(x), Number(y), boutons >>> 0) === 1,
    /// La molette, en crans, positifs vers le haut.
    defiler: (crans) => porte.carte_defiler(crans | 0) === 1,
    /// Ce que le doigt a fait, rendu au pilote à l'heure `tics` (du 8254).
    livrer: (tics) => porte.carte_livrer(BigInt.asUintN(64, BigInt(tics))),
    /// Une touche posée tout de suite : son code du jeu 1, `E0` ou non.
    touche: (jeu1, etendue, enfoncee) => porte.carte_touche(jeu1, etendue ? 1 : 0, enfoncee ? 1 : 0),
    /// Une frappe posée à son tour : `false` si la file pleine la refuse (le
    /// relâchement d'une touche que la file laisse enfoncée passe toujours).
    taper: (jeu1, etendue, enfoncee) => porte.carte_taper(jeu1, etendue ? 1 : 0, enfoncee ? 1 : 0) === 1,
    /// Un mouvement, Y vers le bas comme à l'écran ; les boutons en bits
    /// (gauche, droit, milieu).
    souris: (dx, dy, boutons) => porte.carte_souris(dx | 0, dy | 0, boutons),
    /// Lever ou baisser une ligne du dehors : `false` si elle est refusée.
    lever: (ligne) => porte.carte_lever(ligne) === 1,
    baisser: (ligne) => porte.carte_baisser(ligne) === 1,
    reveil: () => porte.carte_reveil() === 1,
    remise: () => porte.carte_remise() === 1,
    /// Le disque, pour qui le conduit à la main (les tests) ou veut savoir
    /// combien de réponses il attend.
    disque: {
      requete: requeteDisque,
      lu: disqueLu,
      fini: disqueFini,
      servir,
      attendre,
      enVol: () => enVol,
    },
  };
}
