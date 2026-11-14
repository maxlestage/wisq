// La carte de la machine PC, dans la page.
//
// **Ce qu'elle apporte.** La boucle hôte (`web/host.js`) modélise deux 8259,
// un 8254 et un 16550 ; tout autre port y rend `0xff`, personne. Un noyau n'y
// trouve donc ni clavier, ni souris, ni horloge murale : « i8042: Can't read
// CTR », et une date de 1970. Les périphériques qui manquent sont écrits en
// Rust (`crates/wisq-page/src/carte/`), portés depuis le cœur Swift avec sa
// carte exacte — l'i8042 aux ports `0x60`/`0x64` sur les lignes 1 et 12,
// l'horloge CMOS aux ports `0x70`/`0x71` —, et compilés dans le même module
// que l'émetteur, `wisq_page.wasm`. Ce fichier les charge et les sert.
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
//   `souris`.
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
// moment). Le module n'a aucun import, et n'en lit donc aucune lui-même.
//
// **Ce qui est jugé, et où** : les périphériques en natif, cas par cas
// (`cargo test -p wisq-page --lib`) ; ce fichier et le module wasm32 sous Bun
// (`crates/wisq-page/tests/carte.rs`).

/// Le code de `carte_lire` pour un port qui n'est pas à la carte.
const PERSONNE = -1n;
/// Les deux ports de l'horloge, avant lesquels l'heure est posée.
const HORLOGE_INDEX = 0x70;
const HORLOGE_DONNEE = 0x71;

/// **Instancier la carte.** `source` : le module de `wisq_page.wasm`, compilé
/// (`WebAssembly.Module`) ou en octets. `heure` : l'heure UTC de l'hôte, en
/// millisecondes depuis 1970.
export function carte(source, { heure = Date.now } = {}) {
  const module = source instanceof WebAssembly.Module ? source : new WebAssembly.Module(source);
  const porte = new WebAssembly.Instance(module, {}).exports;
  const texte = new TextEncoder();

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
    out(port, valeur, largeur) {
      const at = Number(port);
      horloge(at);
      return porte.carte_ecrire(at, Number(largeur), Number(BigInt.asUintN(32, BigInt(valeur)))) === 1;
    },
  };

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
  /// de frappes mises en file.
  function taperTexte(chaine) {
    const octets = texte.encode(chaine);
    const place = porte.carte_texte_place(octets.length);
    // L'adresse est relue juste avant la copie : la mémoire a pu grandir.
    new Uint8Array(porte.memory.buffer, place, octets.length).set(octets);
    const rendu = porte.carte_texte(octets.length);
    if (rendu < 0) throw new Error("la carte refuse le texte à taper");
    return rendu;
  }

  return {
    ports,
    lignes,
    battre,
    taperTexte,
    /// Une touche posée tout de suite : son code du jeu 1, `E0` ou non.
    touche: (jeu1, etendue, enfoncee) => porte.carte_touche(jeu1, etendue ? 1 : 0, enfoncee ? 1 : 0),
    /// Une frappe posée à son tour.
    taper: (jeu1, etendue, enfoncee) => porte.carte_taper(jeu1, etendue ? 1 : 0, enfoncee ? 1 : 0),
    /// Un mouvement, Y vers le bas comme à l'écran ; les boutons en bits
    /// (gauche, droit, milieu).
    souris: (dx, dy, boutons) => porte.carte_souris(dx | 0, dy | 0, boutons),
    /// Lever ou baisser une ligne du dehors : `false` si elle est refusée.
    lever: (ligne) => porte.carte_lever(ligne) === 1,
    baisser: (ligne) => porte.carte_baisser(ligne) === 1,
    reveil: () => porte.carte_reveil() === 1,
    remise: () => porte.carte_remise() === 1,
  };
}
